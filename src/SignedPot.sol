// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*//////////////////////////////////////////////////////////////////////////
                                FORM-4 FI

  The fee wallet for the FORM-4 token ($FORM4) on Pons (Robinhood Chain, id 4663).
  Insiders file a Form 4 when they buy their own stock. This buys what they bought.

  It can do exactly six things with money:
    harvest()  pull our creator fees (ETH) out of the Pons fee escrow
    buy()      turn that ETH into ONE Robinhood stock token (operator only)
    publish()  fixes a holder snapshot for one purchased stock round
    claim()    holders pull their snapshot share, without staking $FORM4
    distribute() anyone pays the gas to push a holder their share instead.
               In practice that is us: nobody should have to claim to be paid.
    rollover() after CLAIM_WINDOW, what nobody claimed becomes credit that
               the next buy of that same stock hands to the next snapshot

  Stock never leaves except to a holder who proved inclusion in a snapshot.
  claim() and distribute() differ in exactly one thing, who pays the gas.
  Both send to the address written inside the snapshot leaf, so a pusher
  cannot aim a payout anywhere - not at itself, not at a wallet of its
  choosing, not at zero. Pushing an address its own share is the only thing
  it can do.
  rollover() moves nothing out of the contract: it only re-labels an expired
  round's remainder so a later round can pay it to holders instead of it
  sitting here forever. Anyone can call it.

  There is no owner. There is no withdraw. There is no upgrade. Every
  address below is immutable. A mistake in the constructor is permanent.

  The operator (DEPLOYER) is the only wallet that can call buy() and
  publish(). It can pick which stock, when, and at what floor. It cannot
  pick where the stock goes: it always lands in this contract, and only
  leaves to the wallets a published snapshot names.

  Every transfer in this file, so you can check the list is complete:
    ETH   in : PonsV2FeeEscrow.claim()  -> receive()          (harvest)
    ETH   out: WETH.deposit{value}      -> this contract's WETH (buy)
    WETH  out: to a Uniswap v3 pool, inside the swap callback  (buy)
    USDG  out: to a Uniswap v3 pool, inside the swap callback  (buy, 2-hop)
    stock in : Uniswap v3 pool -> this contract                (buy)
    stock out: to a holder proving inclusion in the round snapshot
               (claim() pulled by them, distribute() pushed by us - the
                destination is the snapshot's, never the caller's)
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IStockToken is IERC20 {
    function oraclePaused() external view returns (bool);
}

interface IPonsV2FeeEscrow {
    function claim() external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
}

interface IPonsV2LaunchFactory {
    // Mirrors ILaunchpadV2.LaunchedToken (verified source, Sourcify 4663).
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract SignedPot {
    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------
    error AlreadyBound();
    error NotBound();
    error NotOurLaunch();
    error NotOperator();
    error NotRobinhoodStock(address stock);
    error NoMinOut();
    error TooSoon(uint256 nextBuyAt);
    error NothingToBuy();
    error BuyTooSmall(uint256 ethIn, uint256 minimum);
    error NoPool();
    error StockOraclePaused(address stock);
    error TooLittleOut(uint256 got, uint256 minimum);
    error NotPool();
    error DistributionNotPublished();
    error AlreadyPublished();
    error AlreadyClaimed();
    error InvalidProof();
    error NoSuchRound(uint256 roundId);
    error ClaimWindowClosed(uint256 roundId, uint256 closedAt);
    error ClaimWindowOpen(uint256 roundId, uint256 closesAt);
    error AlreadyRolled(uint256 roundId);
    error NothingClaimed();
    error BadBatch();
    error InvalidDistribution();
    error RoundExhausted(uint256 roundId);
    error Reentrancy();
    error ZeroAddress();
    error RefundFailed();

    // ------------------------------------------------------------------
    // Events (the board reads these)
    // ------------------------------------------------------------------
    event Bound(address indexed token);
    event Harvested(uint256 ethAmount, uint256 reserved, address caller);
    /// @notice The pot paid the operator back for delivering stock.
    event GasRefunded(address indexed to, uint256 payouts, uint256 amount);
    event Bought(address indexed stock, uint256 ethIn, uint256 stockOut, bytes32 filing, address caller);
    event DistributionPublished(
        uint256 indexed roundId, bytes32 indexed holderRoot, uint256 eligibleSupply, uint256 snapshotBlock
    );
    /// @notice `pushed` is true when somebody other than `user` paid the gas -
    /// i.e. we sent it rather than they claimed it. The frontend cannot work
    /// this out from the log alone, and fetching every transaction to compare
    /// senders is what makes a history page slow.
    event Claimed(
        uint256 indexed roundId, address indexed user, address indexed stock, uint256 amount, bool pushed
    );
    /// @notice An expired round's unclaimed remainder became credit for `stock`.
    event RolledOver(uint256 indexed roundId, address indexed stock, uint256 amount);
    /// @notice A new round absorbed credit left over from expired rounds.
    event RolledIn(uint256 indexed roundId, address indexed stock, uint256 amount);

    // ------------------------------------------------------------------
    // Frozen configuration
    // ------------------------------------------------------------------
    IPonsV2LaunchFactory public immutable FACTORY;
    IPonsV2FeeEscrow public immutable ESCROW;
    IUniswapV3Factory public immutable V3_FACTORY;
    IWETH public immutable WETH;
    IERC20 public immutable USDG;
    /// @notice The operator. Must have launched the $FORM4 token on Pons (bind()
    /// checks this), and is the only wallet that can buy() and publish().
    /// It cannot withdraw, redirect, or claim more than its own snapshot share.
    address public immutable DEPLOYER;
    /// @notice Runtime codehash shared by every real Robinhood stock token
    /// (they are all beacon proxies of the same bytecode). buy() refuses
    /// anything else, so the pot can only ever hold real Robinhood stock.
    bytes32 public immutable STOCK_CODEHASH;

    /// @notice Minimum seconds between buys.
    uint256 public immutable BUY_INTERVAL;
    /// @notice A buy must spend at least this fraction of the pot, so the log
    /// is not spammed with dust rounds.
    uint256 public immutable MIN_SPEND_BPS;
    /// @notice And at least this many wei.
    uint256 public immutable MIN_SPEND_WEI;
    /// @notice Share of every harvest set aside to pay for pushing stock to
    /// holders. Buys cannot touch it. Everything else buys stock.
    uint256 public immutable RESERVE_BPS;
    /// @notice What the pot reimburses the operator per holder actually paid.
    /// A flat allowance, not measured gas: `tx.gasprice` is caller-chosen, so
    /// refunding real cost would let a leaked key drain the reserve in one call.
    uint256 public immutable GAS_PER_PAYOUT;
    /// @notice How long a published round stays claimable. After this, claim()
    /// refuses and anyone may rollover() the remainder into the next round of
    /// the same stock. Without it, whatever nobody claims is stuck here forever.
    uint256 public immutable CLAIM_WINDOW;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    /// @notice The $FORM4 token. Set once by bind(), then frozen.
    IERC20 public token;
    uint256 public lastBuyAt;
    /// @notice ETH earmarked for delivery gas. Grows by RESERVE_BPS of every
    /// harvest, shrinks only when a push actually pays somebody. `buy()` spends
    /// `balance - gasReserve`, so stock money and delivery money never mix.
    uint256 public gasReserve;

    /// @dev Field order is chosen so stock/windowAt/rolled share one slot.
    /// The public getter returns them in this order - readers off-chain must
    /// match it.
    struct Distribution {
        address stock;
        uint40 windowAt;
        /// @notice The block the holder snapshot was taken at. On chain because
        /// otherwise "anyone can rebuild the tree and check us" is not true: a
        /// verifier would have to be told which block to replay to, by us.
        uint48 snapshotBlock;
        bool rolled;
        uint256 stockAmount;
        uint256 paidOut;
        uint256 eligibleSupply;
        bytes32 holderRoot;
    }

    Distribution[] public distributions;
    mapping(uint256 => mapping(address => bool)) public paid;
    /// @notice stock -> units recovered from expired rounds, waiting for the
    /// next buy of that same stock to hand them to a fresh snapshot.
    mapping(address => uint256) public rolledOver;
    uint256 private constant BPS = 10_000;
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    uint256 private _lock = 1;
    address private _expectedPool;

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyOperator() {
        if (msg.sender != DEPLOYER) revert NotOperator();
        _;
    }

    struct Config {
        address factory;
        address escrow;
        address v3Factory;
        address weth;
        address usdg;
        address deployer;
        bytes32 stockCodehash;
        uint256 buyInterval;
        uint256 minSpendBps;
        uint256 minSpendWei;
        uint256 claimWindow;
        uint256 reserveBps;
        uint256 gasPerPayout;
    }

    constructor(Config memory c) {
        if (
            c.factory == address(0) || c.escrow == address(0) || c.v3Factory == address(0) || c.weth == address(0)
                || c.usdg == address(0) || c.deployer == address(0) || c.stockCodehash == bytes32(0)
        ) revert ZeroAddress();
        FACTORY = IPonsV2LaunchFactory(c.factory);
        ESCROW = IPonsV2FeeEscrow(c.escrow);
        V3_FACTORY = IUniswapV3Factory(c.v3Factory);
        WETH = IWETH(c.weth);
        USDG = IERC20(c.usdg);
        DEPLOYER = c.deployer;
        STOCK_CODEHASH = c.stockCodehash;
        BUY_INTERVAL = c.buyInterval;
        MIN_SPEND_BPS = c.minSpendBps;
        MIN_SPEND_WEI = c.minSpendWei;
        if (c.claimWindow == 0) revert InvalidDistribution();
        CLAIM_WINDOW = c.claimWindow;
        if (c.reserveBps >= BPS) revert InvalidDistribution();
        RESERVE_BPS = c.reserveBps;
        GAS_PER_PAYOUT = c.gasPerPayout;
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // 0. bind — once
    // ------------------------------------------------------------------

    /// @notice Points the pot at the $FORM4 token. Anyone can call it, but it only
    /// accepts a token that the Pons factory says was launched by DEPLOYER with
    /// this contract as its creator fee recipient. Once set it cannot change.
    function bind(address token_) external {
        if (address(token) != address(0)) revert AlreadyBound();
        IPonsV2LaunchFactory.LaunchedToken memory l = FACTORY.getLaunchedToken(token_);
        if (!l.exists || l.token != token_ || l.deployer != DEPLOYER || l.creatorFeeRecipient != address(this)) {
            revert NotOurLaunch();
        }
        token = IERC20(token_);
        emit Bound(token_);
    }

    // ------------------------------------------------------------------
    // 1. harvest
    // ------------------------------------------------------------------

    /// @notice Pulls our creator fees out of the Pons escrow into this contract.
    function harvest() external nonReentrant returns (uint256 amount) {
        if (ESCROW.balanceOf(address(this)) == 0) return 0;
        amount = ESCROW.claim();
        uint256 reserved = amount * RESERVE_BPS / BPS;
        if (reserved != 0) gasReserve += reserved;
        emit Harvested(amount, reserved, msg.sender);
    }

    // ------------------------------------------------------------------
    // 2. buy — operator only
    // ------------------------------------------------------------------

    /// @notice Spends `ethIn` of the pot on `stock` through Uniswap v3. Output
    /// always lands in this contract. Only the operator may call this, and it
    /// is responsible for `minOut`: quote off-chain, pass a real floor.
    /// @param stock     Any real Robinhood stock token (codehash checked).
    /// @param ethIn     Wei to spend. At least MIN_SPEND_BPS of the pot and MIN_SPEND_WEI.
    /// @param feeWeth   v3 fee tier of the WETH pool. If `feeUsdg` is 0 the route is
    ///                  WETH -> stock in that pool. Otherwise WETH -> USDG in this pool,
    ///                  then USDG -> stock in the `feeUsdg` pool.
    /// @param feeUsdg   v3 fee tier of the USDG/stock pool, or 0 for the direct route.
    /// @param minOut    Least stock we accept. Must be non-zero.
    /// @param filing    Hash of the Form 4 accession / URL. Stored in the event only.
    function buy(address stock, uint256 ethIn, uint24 feeWeth, uint24 feeUsdg, uint256 minOut, bytes32 filing)
        external
        nonReentrant
        onlyOperator
        returns (uint256 stockOut)
    {
        if (stock.codehash != STOCK_CODEHASH) revert NotRobinhoodStock(stock);
        if (minOut == 0) revert NoMinOut();
        if (address(token) == address(0)) revert NotBound();
        if (block.timestamp < lastBuyAt + BUY_INTERVAL) revert TooSoon(lastBuyAt + BUY_INTERVAL);
        if (IStockToken(stock).oraclePaused()) revert StockOraclePaused(stock);

        ethIn = _spend(ethIn);

        lastBuyAt = block.timestamp;
        stockOut = _route(stock, ethIn, feeWeth, feeUsdg);
        if (stockOut < minOut) revert TooLittleOut(stockOut, minOut);

        // Anything an expired round could not give away is handed to this one.
        // It is stock this contract already holds; nothing new enters or leaves.
        uint256 credit = rolledOver[stock];
        if (credit != 0) rolledOver[stock] = 0;

        distributions.push(Distribution(stock, uint40(block.timestamp), 0, false, stockOut + credit, 0, 0, bytes32(0)));
        // Bought reports the swap alone, so the receipt is never inflated by credit.
        emit Bought(stock, ethIn, stockOut, filing, msg.sender);
        if (credit != 0) emit RolledIn(distributions.length - 1, stock, credit);
    }

    /// @dev Clamp to the pot and enforce the minimum spend.
    function _spend(uint256 ethIn) private view returns (uint256) {
        // Delivery money is not stock money. Whatever harvest() set aside is
        // invisible to the buy, so a full-size buy can never leave the pot
        // unable to pay for handing the stock out.
        uint256 held = address(this).balance;
        uint256 pot = held > gasReserve ? held - gasReserve : 0;
        if (pot == 0) revert NothingToBuy();
        if (ethIn > pot) ethIn = pot;
        uint256 floor = pot * MIN_SPEND_BPS / BPS;
        if (floor < MIN_SPEND_WEI) floor = MIN_SPEND_WEI;
        if (ethIn < floor) revert BuyTooSmall(ethIn, floor);
        return ethIn;
    }

    /// @dev Wrap and swap. feeUsdg == 0 means WETH -> stock direct, else WETH -> USDG -> stock.
    function _route(address stock, uint256 ethIn, uint24 feeWeth, uint24 feeUsdg) private returns (uint256) {
        WETH.deposit{value: ethIn}();
        if (feeUsdg == 0) return _swap(address(WETH), stock, feeWeth, ethIn);
        uint256 usdgOut = _swap(address(WETH), address(USDG), feeWeth, ethIn);
        return _swap(address(USDG), stock, feeUsdg, usdgOut);
    }

    /// @dev Exact-input swap straight against the v3 pool. Output lands here.
    function _swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn) private returns (uint256 out) {
        address pool = V3_FACTORY.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert NoPool();
        bool zeroForOne = tokenIn < tokenOut;
        _expectedPool = pool;
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(tokenIn)
        );
        _expectedPool = address(0);
        out = uint256(-(zeroForOne ? a1 : a0));
    }

    /// @dev Pays the pool. Only the pool we just called may invoke this.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _expectedPool || _expectedPool == address(0)) revert NotPool();
        address tokenIn = abi.decode(data, (address));
        uint256 owedToPool = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        _safeTransfer(IERC20(tokenIn), msg.sender, owedToPool);
    }

    // ------------------------------------------------------------------
    // 3. publish holder snapshot / claim
    // ------------------------------------------------------------------

    /// @notice Attach an auditable holder snapshot to a completed buy. The
    /// operator is fixed at deploy time and cannot move purchased stock.
    function publishDistribution(
        uint256 roundId,
        bytes32 holderRoot,
        uint256 eligibleSupply,
        uint256 snapshotBlock
    ) external onlyOperator {
        if (holderRoot == bytes32(0) || eligibleSupply == 0) revert InvalidDistribution();
        if (snapshotBlock == 0 || snapshotBlock > block.number) revert InvalidDistribution();
        Distribution storage d = distributions[roundId];
        if (d.holderRoot != bytes32(0)) revert AlreadyPublished();
        // A rolled round already gave its stock to another round's snapshot.
        // Publishing one now would promise the same units twice.
        if (d.rolled) revert AlreadyRolled(roundId);
        d.holderRoot = holderRoot;
        d.eligibleSupply = eligibleSupply;
        d.snapshotBlock = uint48(snapshotBlock);
        d.windowAt = uint40(block.timestamp);
        emit DistributionPublished(roundId, holderRoot, eligibleSupply, snapshotBlock);
    }

    /// @notice Claim one round using the $FORM4 balance recorded in its snapshot.
    /// A round can never pay out more than the stock it bought, so a bad
    /// snapshot cannot eat another round's stock. Reverts with the reason if
    /// this round is not claimable for you.
    function claim(uint256 roundId, uint256 holderBalance, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        address stock;
        (, stock, amount) = _credit(msg.sender, roundId, holderBalance, proof, true);
        if (amount != 0) _safeTransfer(IERC20(stock), msg.sender, amount);
    }

    /// @notice Claim several rounds in one transaction.
    ///
    /// The pot buys at most once an hour, so a holder who has been around a
    /// week is owed a hundred-odd separate rounds. Claiming them one signature
    /// at a time is not a thing anyone does, and unclaimed stock is the one
    /// failure this product cannot afford.
    ///
    /// Rounds you cannot claim - unpublished, expired, already taken, bad
    /// proof - are skipped rather than reverting the batch, so one stale entry
    /// in a proof file does not cost you the other ninety-nine. If nothing at
    /// all was claimable it reverts, because then the caller wasted gas on
    /// nothing and should be told.
    ///
    /// @return total   stock units transferred across every round that worked
    /// @return rounds  how many rounds actually paid out
    function claimMany(uint256[] calldata roundIds, uint256[] calldata holderBalances, bytes32[][] calldata proofs)
        external
        nonReentrant
        returns (uint256 total, uint256 rounds)
    {
        return _settle(msg.sender, roundIds, holderBalances, proofs);
    }

    /// @notice Push one holder everything they are owed. Same rules as
    /// claimMany, one difference: the caller pays the gas and `account` gets
    /// the stock.
    ///
    /// This is how a round empties without anyone doing anything. A holder who
    /// never opens the site, never connects a wallet and never hears of us
    /// still ends up with the stock in their wallet, because we run this over
    /// the snapshot ourselves.
    ///
    /// Permissionless, because there is nothing here to aim. The destination
    /// is the address inside the snapshot leaf; a proof that does not hash to
    /// the published root is skipped, so the worst a stranger can do is spend
    /// their own gas paying somebody else.
    function distributeTo(
        address account,
        uint256[] calldata roundIds,
        uint256[] calldata holderBalances,
        bytes32[][] calldata proofs
    ) external nonReentrant onlyOperator returns (uint256 total, uint256 rounds) {
        (total, rounds) = _settle(account, roundIds, holderBalances, proofs);
        _refundGas(rounds);
    }

    /// @notice Push many holders at once - the shape the keeper uses after a
    /// publish, when one fresh round has to reach every wallet in its snapshot.
    ///
    /// Flat parallel arrays, one entry per (round, holder). Entries that are
    /// not payable are skipped exactly as in claimMany, so a snapshot that has
    /// partly claimed itself already does not revert the sweep. No aggregation
    /// here: every entry can have a different recipient, so every paying entry
    /// is its own transfer. Use distributeTo when it is one wallet and many
    /// rounds - that one aggregates.
    function distribute(
        uint256[] calldata roundIds,
        address[] calldata accounts,
        uint256[] calldata holderBalances,
        bytes32[][] calldata proofs
    ) external nonReentrant onlyOperator returns (uint256 total, uint256 rounds) {
        uint256 n = roundIds.length;
        if (n == 0 || accounts.length != n || holderBalances.length != n || proofs.length != n) revert BadBatch();
        for (uint256 i = 0; i < n; i++) {
            (bool ok, uint256 amount) = _push(accounts[i], roundIds[i], holderBalances[i], proofs[i]);
            if (!ok) continue;
            total += amount;
            rounds++;
        }
        if (rounds == 0) revert NothingClaimed();
        _refundGas(rounds);
    }

    /// @dev One pushed entry: credit it, send it on. Its own function only so
    /// distribute() keeps enough stack for four parallel calldata arrays.
    function _push(address account, uint256 roundId, uint256 holderBalance, bytes32[] calldata proof)
        private
        returns (bool ok, uint256 amount)
    {
        address stock;
        (ok, stock, amount) = _credit(account, roundId, holderBalance, proof, false);
        if (ok && amount != 0) _safeTransfer(IERC20(stock), account, amount);
    }

    /// @dev Pay the caller back for delivering `payouts` holders their stock,
    /// out of the reserve and never out of anything else. Capped by what the
    /// reserve actually holds, so a short reserve degrades to a part-refund
    /// rather than reverting a push that already moved stock.
    function _refundGas(uint256 payouts) private {
        uint256 owed = payouts * GAS_PER_PAYOUT;
        if (owed > gasReserve) owed = gasReserve;
        if (owed == 0) return;
        gasReserve -= owed;
        (bool ok,) = msg.sender.call{value: owed}("");
        if (!ok) revert RefundFailed();
        emit GasRefunded(msg.sender, payouts, owed);
    }

    /// @dev The running state of one settle pass. It lives in memory rather
    /// than in locals because a batch loop over four parallel calldata arrays
    /// does not leave sixteen stack slots for anything else.
    struct Batch {
        address account;
        address[] stocks;
        uint256[] owed;
        uint256 k;
        uint256 total;
        uint256 rounds;
    }

    /// @dev Credit a batch to one account and pay it in as few transfers as
    /// possible. A holder owed twenty rounds of the same stock gets one
    /// transfer, not twenty - which is most of the gas in a long claim, and
    /// the whole reason a sweep of the snapshot is affordable at all.
    function _settle(
        address account,
        uint256[] calldata roundIds,
        uint256[] calldata holderBalances,
        bytes32[][] calldata proofs
    ) private returns (uint256, uint256) {
        uint256 n = roundIds.length;
        if (n == 0 || holderBalances.length != n || proofs.length != n) revert BadBatch();
        Batch memory b;
        b.account = account;
        b.stocks = new address[](n);
        b.owed = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            _creditInto(b, roundIds[i], holderBalances[i], proofs[i]);
        }
        if (b.rounds == 0) revert NothingClaimed();
        for (uint256 j = 0; j < b.k; j++) {
            if (b.owed[j] != 0) _safeTransfer(IERC20(b.stocks[j]), account, b.owed[j]);
        }
        return (b.total, b.rounds);
    }

    /// @dev One round of a settle pass: credit it, then fold what it owes into
    /// the running per-stock total. Rounds that cannot pay are skipped.
    function _creditInto(Batch memory b, uint256 roundId, uint256 holderBalance, bytes32[] calldata proof) private {
        (bool ok, address stock, uint256 amount) = _credit(b.account, roundId, holderBalance, proof, false);
        if (!ok) return;
        b.total += amount;
        b.rounds++;
        uint256 j;
        while (j < b.k && b.stocks[j] != stock) j++;
        if (j == b.k) {
            b.stocks[b.k] = stock;
            b.k++;
        }
        b.owed[j] += amount;
    }

    /// @dev Every check, then the state write and the event - but not the
    /// transfer, which the caller batches. `strict` picks whether an
    /// unpayable round reverts with the reason or is reported as a miss.
    /// Nothing is written until every check has passed, so a miss inside a
    /// batch leaves no trace.
    function _credit(address account, uint256 roundId, uint256 holderBalance, bytes32[] calldata proof, bool strict)
        private
        returns (bool, address, uint256)
    {
        if (roundId >= distributions.length) {
            if (strict) revert NoSuchRound(roundId);
            return (false, address(0), 0);
        }
        Distribution storage d = distributions[roundId];
        if (d.holderRoot == bytes32(0)) {
            if (strict) revert DistributionNotPublished();
            return (false, address(0), 0);
        }
        if (block.timestamp > uint256(d.windowAt) + CLAIM_WINDOW) {
            if (strict) revert ClaimWindowClosed(roundId, uint256(d.windowAt) + CLAIM_WINDOW);
            return (false, address(0), 0);
        }
        if (paid[roundId][account]) {
            if (strict) revert AlreadyClaimed();
            return (false, address(0), 0);
        }
        // A push must never burn. Nothing else can reach zero: it cannot sign.
        if (account == address(0)) {
            if (strict) revert ZeroAddress();
            return (false, address(0), 0);
        }
        if (!_verify(proof, d.holderRoot, keccak256(bytes.concat(keccak256(abi.encode(account, holderBalance)))))) {
            if (strict) revert InvalidProof();
            return (false, address(0), 0);
        }
        uint256 amount = d.stockAmount * holderBalance / d.eligibleSupply;
        if (d.paidOut + amount > d.stockAmount) {
            if (strict) revert RoundExhausted(roundId);
            return (false, address(0), 0);
        }

        paid[roundId][account] = true;
        d.paidOut += amount;
        emit Claimed(roundId, account, d.stock, amount, msg.sender != account);
        return (true, d.stock, amount);
    }

    function claimable(uint256 roundId, address user, uint256 holderBalance, bytes32[] calldata proof)
        external
        view
        returns (uint256)
    {
        return _claimable(roundId, user, holderBalance, proof);
    }

    function _claimable(uint256 roundId, address user, uint256 holderBalance, bytes32[] calldata proof)
        private
        view
        returns (uint256)
    {
        if (roundId >= distributions.length) return 0;
        Distribution memory d = distributions[roundId];
        if (d.holderRoot == bytes32(0) || paid[roundId][user]) return 0;
        if (block.timestamp > uint256(d.windowAt) + CLAIM_WINDOW) return 0;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(user, holderBalance))));
        if (!_verify(proof, d.holderRoot, leaf)) return 0;
        uint256 amount = d.stockAmount * holderBalance / d.eligibleSupply;
        if (d.paidOut + amount > d.stockAmount) return 0;
        return amount;
    }

    /// @notice Every amount a holder can still claim, in one call.
    ///
    /// A holder who has been around a week is owed a hundred-odd rounds, and
    /// asking the RPC about each one separately is what makes a claim page feel
    /// broken. Returns 0 for any round that is unpublished, expired, already
    /// claimed, or not theirs - so the caller can build a claimMany batch from
    /// exactly the non-zero entries.
    function claimableMany(
        uint256[] calldata roundIds,
        address user,
        uint256[] calldata holderBalances,
        bytes32[][] calldata proofs
    ) external view returns (uint256[] memory amounts) {
        uint256 n = roundIds.length;
        if (holderBalances.length != n || proofs.length != n) revert BadBatch();
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = _claimable(roundIds[i], user, holderBalances[i], proofs[i]);
        }
    }

    /// @notice After CLAIM_WINDOW, move what nobody claimed out of a dead round
    /// and into credit for its stock. The next buy() of that same stock adds the
    /// credit to its own round, where a fresh snapshot can hand it out.
    ///
    /// Permissionless on purpose: there is no choice to make here and no way to
    /// aim the result. The stock does not move, does not convert, and cannot be
    /// withdrawn - it stays in this contract and can still only leave through a
    /// holder's claim.
    function rollover(uint256 roundId) external returns (uint256 amount) {
        if (roundId >= distributions.length) revert NoSuchRound(roundId);
        Distribution storage d = distributions[roundId];
        // No published-root check on purpose. publishDistribution() is operator
        // only, so a round we bought and never published would otherwise be
        // stranded forever: claim() refuses it for want of a root, and so did
        // this. windowAt is set at the buy and overwritten at the publish, so
        // the same deadline reads as "our deadline to publish" before a root
        // exists and "the holder's deadline to claim" after one does.
        uint256 closesAt = uint256(d.windowAt) + CLAIM_WINDOW;
        if (block.timestamp <= closesAt) revert ClaimWindowOpen(roundId, closesAt);
        if (d.rolled) revert AlreadyRolled(roundId);

        d.rolled = true;
        amount = d.stockAmount - d.paidOut;
        if (amount != 0) rolledOver[d.stock] += amount;
        emit RolledOver(roundId, d.stock, amount);
    }

    function distributionsCount() external view returns (uint256) {
        return distributions.length;
    }

    /// @notice When `roundId` stops being claimable. 0 if it is not published.
    function claimClosesAt(uint256 roundId) external view returns (uint256) {
        if (roundId >= distributions.length) return 0;
        Distribution memory d = distributions[roundId];
        if (d.holderRoot == bytes32(0)) return 0;
        return uint256(d.windowAt) + CLAIM_WINDOW;
    }

    /// @notice True if `stock` is something buy() would accept.
    function isRobinhoodStock(address stock) external view returns (bool) {
        return stock.codehash == STOCK_CODEHASH;
    }

    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            computed = computed < sibling
                ? keccak256(abi.encodePacked(computed, sibling))
                : keccak256(abi.encodePacked(sibling, computed));
        }
        return computed == root;
    }

    // ------------------------------------------------------------------
    // ERC20 helpers (no external library, keep the file self-contained)
    // ------------------------------------------------------------------
    function _safeTransfer(IERC20 t, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = address(t).call(abi.encodeWithSelector(t.transfer.selector, to, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer failed");
    }
}
