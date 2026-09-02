// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {SignedPot, IERC20} from "../src/SignedPot.sol";
import {PotConfig} from "../src/Config.sol";

interface IPonsFactory {
    struct Socials { string twitter; string telegram; string discord; string website; string farcaster; }
    struct TokenParams {
        string name; string symbol; string logo; string description; Socials socials;
        address creatorFeeRecipient; uint16 creatorTaxBps; bool buybackEnabled;
        bytes32 expectedEconomics; bytes32 salt;
    }
    function launchToken(TokenParams calldata, uint256, address) external payable returns (address token, address curve);
    function launchFee() external view returns (uint256);
}

interface ICurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sweepFees(uint256 minBuybackTokensOut) external;
}

interface IHook { function feeSweepOperator() external view returns (address); }
interface IEscrow {
    function credit(address recipient) external payable;
    function balanceOf(address) external view returns (uint256);
}

/// Runs against a fork of Robinhood Chain mainnet:
/// forge test --fork-url robinhood -vv
contract SignedPotTest is Test {
    IPonsFactory constant FACTORY = IPonsFactory(PotConfig.PONS_FACTORY);
    IEscrow constant ESCROW = IEscrow(PotConfig.PONS_ESCROW);
    address constant DEV = PotConfig.DEV;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant FAKE_GME = 0xDeCF74e4AA6fF30b1612e65665AAF650BEdecbA3;
    uint24 constant FEE = 500;

    SignedPot pot;
    IERC20 signed;
    ICurve curve;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    function setUp() public {
        pot = new SignedPot(PotConfig.get());
        vm.deal(DEV, 20 ether);
        vm.startPrank(DEV);
        (address token_, address curve_) = FACTORY.launchToken{value: FACTORY.launchFee()}(_params(address(pot)), 0, address(0));
        signed = IERC20(token_);
        curve = ICurve(curve_);
        pot.bind(token_);
        curve.buy{value: 1 ether}(1 ether, 0, DEV);
        vm.stopPrank();
    }

    function _params(address recipient) private pure returns (IPonsFactory.TokenParams memory p) {
        p.name = "FORM-4";
        p.symbol = "FORM4";
        p.description = "test";
        p.creatorFeeRecipient = recipient;
        p.creatorTaxBps = 200;
    }

    function _fund(uint256 amount) private {
        vm.deal(stranger, amount);
        vm.prank(stranger);
        ESCROW.credit{value: amount}(address(pot));
        pot.harvest();
    }

    function _buy(uint256 amount) private returns (uint256 out, uint256 roundId) {
        _fund(amount);
        roundId = pot.distributionsCount();
        vm.prank(DEV);
        out = pot.buy(NVDA, amount, FEE, FEE, 1, keccak256("filing"));
    }

    function _leaf(address user, uint256 balance) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, balance))));
    }

    function _root(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_bind_once_and_reject_foreign_launch() public {
        vm.expectRevert(SignedPot.AlreadyBound.selector);
        pot.bind(address(signed));
        SignedPot fresh = new SignedPot(PotConfig.get());
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (address foreign,) = FACTORY.launchToken{value: FACTORY.launchFee()}(_params(address(fresh)), 0, address(0));
        vm.expectRevert(SignedPot.NotOurLaunch.selector);
        fresh.bind(foreign);
    }

    function test_real_curve_fees_reach_pot() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        curve.buy{value: 1 ether}(1 ether, 0, alice);
        address operator = IHook(0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044).feeSweepOperator();
        vm.prank(operator);
        curve.sweepFees(0);
        uint256 credited = ESCROW.balanceOf(address(pot));
        assertGt(credited, 0);
        assertEq(pot.harvest(), credited);
    }

    function test_holder_claims_without_staking() public {
        uint256 devBalance = signed.balanceOf(DEV);
        uint256 nvdaBefore = IERC20(NVDA).balanceOf(DEV);
        (uint256 out, uint256 roundId) = _buy(2 ether);
        bytes32 leaf = _leaf(DEV, devBalance);
        vm.prank(DEV);
        pot.publishDistribution(roundId, leaf, devBalance, block.number);
        bytes32[] memory proof = new bytes32[](0);
        assertApproxEqAbs(pot.claimable(roundId, DEV, devBalance, proof), out, 1);
        vm.prank(DEV);
        pot.claim(roundId, devBalance, proof);
        assertApproxEqAbs(IERC20(NVDA).balanceOf(DEV) - nvdaBefore, out, 1);
    }

    function test_two_holders_receive_snapshot_pro_rata() public {
        uint256 transferAmount = signed.balanceOf(DEV) / 3;
        vm.prank(DEV);
        signed.transfer(alice, transferAmount);
        uint256 devBalance = signed.balanceOf(DEV);
        uint256 aliceBalance = signed.balanceOf(alice);
        uint256 eligible = devBalance + aliceBalance;
        (uint256 out, uint256 roundId) = _buy(2 ether);
        bytes32 devLeaf = _leaf(DEV, devBalance);
        bytes32 aliceLeaf = _leaf(alice, aliceBalance);
        vm.prank(DEV);
        pot.publishDistribution(roundId, _root(devLeaf, aliceLeaf), eligible, block.number);
        bytes32[] memory devProof = new bytes32[](1);
        devProof[0] = aliceLeaf;
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = devLeaf;
        vm.prank(DEV);
        uint256 devOut = pot.claim(roundId, devBalance, devProof);
        vm.prank(alice);
        uint256 aliceOut = pot.claim(roundId, aliceBalance, aliceProof);
        assertApproxEqAbs(devOut, out * devBalance / eligible, 1);
        assertApproxEqAbs(aliceOut, out * aliceBalance / eligible, 1);
    }

    function test_transfer_after_snapshot_cannot_double_claim() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (, uint256 roundId) = _buy(1 ether);
        bytes32 leaf = _leaf(DEV, devBalance);
        vm.prank(DEV);
        pot.publishDistribution(roundId, leaf, devBalance, block.number);
        vm.prank(DEV);
        signed.transfer(bob, devBalance);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert(SignedPot.InvalidProof.selector);
        pot.claim(roundId, devBalance, proof);
        vm.prank(DEV);
        pot.claim(roundId, devBalance, proof);
        vm.prank(DEV);
        vm.expectRevert(SignedPot.AlreadyClaimed.selector);
        pot.claim(roundId, devBalance, proof);
    }

    function test_only_distributor_can_publish() public {
        (, uint256 roundId) = _buy(1 ether);
        vm.prank(stranger);
        vm.expectRevert(SignedPot.NotOperator.selector);
        pot.publishDistribution(roundId, bytes32(uint256(1)), 1, block.number);
    }

    function test_stock_fingerprint_matches_real_tokens_only() public view {
        assertEq(NVDA.codehash, PotConfig.STOCK_CODEHASH);
        assertEq(AAPL.codehash, PotConfig.STOCK_CODEHASH);
        assertEq(TSLA.codehash, PotConfig.STOCK_CODEHASH);
        assertTrue(pot.isRobinhoodStock(NVDA));
        assertFalse(pot.isRobinhoodStock(FAKE_GME));
        assertFalse(pot.isRobinhoodStock(address(signed)));
        assertFalse(pot.isRobinhoodStock(PotConfig.WETH));
        assertFalse(pot.isRobinhoodStock(stranger));
    }

    function test_only_operator_can_buy() public {
        _fund(1 ether);
        vm.prank(stranger);
        vm.expectRevert(SignedPot.NotOperator.selector);
        pot.buy(NVDA, 1 ether, FEE, FEE, 1, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(SignedPot.NotOperator.selector);
        pot.buy(NVDA, 1 ether, FEE, FEE, 1, bytes32(0));
        assertEq(address(pot).balance, 1 ether);
    }

    function test_buy_rejects_fake_stock_and_zero_floor() public {
        _fund(1 ether);
        vm.startPrank(DEV);
        vm.expectRevert(abi.encodeWithSelector(SignedPot.NotRobinhoodStock.selector, FAKE_GME));
        pot.buy(FAKE_GME, 1 ether, FEE, FEE, 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SignedPot.NotRobinhoodStock.selector, address(signed)));
        pot.buy(address(signed), 1 ether, FEE, FEE, 1, bytes32(0));
        vm.expectRevert(SignedPot.NoMinOut.selector);
        pot.buy(NVDA, 1 ether, FEE, FEE, 0, bytes32(0));
        vm.stopPrank();
        assertEq(address(pot).balance, 1 ether);
    }

    function test_buy_respects_min_out_and_interval() public {
        _fund(1 ether);
        vm.startPrank(DEV);
        vm.expectRevert();
        pot.buy(NVDA, 1 ether, FEE, FEE, type(uint256).max, bytes32(0));
        uint256 out = pot.buy(NVDA, 1 ether, FEE, FEE, 1, bytes32(0));
        assertGt(out, 0);
        assertEq(IERC20(NVDA).balanceOf(address(pot)), out);
        vm.expectRevert(abi.encodeWithSelector(SignedPot.TooSoon.selector, block.timestamp + 1 hours));
        pot.buy(NVDA, 1 ether, FEE, FEE, 1, bytes32(0));
        vm.stopPrank();
    }

    function test_round_cannot_overpay_into_other_rounds() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (uint256 out0, uint256 round0) = _buy(1 ether);
        vm.warp(block.timestamp + 1 hours);
        (uint256 out1, uint256 round1) = _buy(1 ether);
        // Publish round0 with a bogus eligibleSupply that says dev owns 2x the supply.
        bytes32 leaf = _leaf(DEV, devBalance);
        vm.startPrank(DEV);
        pot.publishDistribution(round0, leaf, devBalance / 2, block.number);
        pot.publishDistribution(round1, leaf, devBalance, block.number);
        bytes32[] memory proof = new bytes32[](0);
        assertEq(pot.claimable(round0, DEV, devBalance, proof), 0);
        vm.expectRevert(abi.encodeWithSelector(SignedPot.RoundExhausted.selector, round0));
        pot.claim(round0, devBalance, proof);
        // round1 is untouched and pays exactly what it bought.
        uint256 got = pot.claim(round1, devBalance, proof);
        vm.stopPrank();
        assertEq(got, out1);
        assertEq(IERC20(NVDA).balanceOf(address(pot)), out0);
    }

    function test_no_eth_withdraw_surface() public {
        _fund(1 ether);
        bytes4[4] memory selectors = [
            bytes4(keccak256("withdraw()")), bytes4(keccak256("rescue(address,uint256)")),
            bytes4(keccak256("execute(address,bytes)")), bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i = 0; i < selectors.length; i++) {
            (bool ok,) = address(pot).call(abi.encodeWithSelector(selectors[i]));
            assertFalse(ok);
        }
    }

    // ------------------------------------------------------------------
    // claimMany - one signature instead of one per round
    // ------------------------------------------------------------------

    /// Three rounds, one transaction. This is the whole reason claimMany exists:
    /// the pot buys hourly, so a holder who waits a week is owed ~168 rounds and
    /// nobody signs 168 times.
    function test_claim_many_sweeps_every_round() public {
        uint256 devBalance = signed.balanceOf(DEV);
        uint256 before = IERC20(NVDA).balanceOf(DEV);
        bytes32 leaf = _leaf(DEV, devBalance);

        uint256[] memory ids = new uint256[](3);
        uint256 expected;
        for (uint256 i = 0; i < 3; i++) {
            (uint256 out, uint256 roundId) = _buy(1 ether);
            expected += out;
            ids[i] = roundId;
            vm.prank(DEV);
            pot.publishDistribution(roundId, leaf, devBalance, block.number);
            vm.warp(block.timestamp + 1 hours);
        }

        vm.prank(DEV);
        (uint256 total, uint256 rounds) = pot.claimMany(ids, _balances(devBalance, 3), _emptyProofs(3));

        assertEq(rounds, 3);
        assertApproxEqAbs(total, expected, 3);
        assertApproxEqAbs(IERC20(NVDA).balanceOf(DEV) - before, expected, 3);
        // and every round is individually marked, so a second sweep finds nothing
        vm.prank(DEV);
        vm.expectRevert(SignedPot.NothingClaimed.selector);
        pot.claimMany(ids, _balances(devBalance, 3), _emptyProofs(3));
    }

    /// A stale entry in a proof file must not cost the holder the other rounds.
    function test_claim_many_skips_unclaimable_rounds() public {
        uint256 devBalance = signed.balanceOf(DEV);
        bytes32 leaf = _leaf(DEV, devBalance);

        (uint256 outA, uint256 roundA) = _buy(1 ether);
        vm.prank(DEV);
        pot.publishDistribution(roundA, leaf, devBalance, block.number);
        vm.warp(block.timestamp + 1 hours);

        // published, and claimed on its own before the batch runs
        (uint256 outB, uint256 roundB) = _buy(1 ether);
        vm.startPrank(DEV);
        pot.publishDistribution(roundB, leaf, devBalance, block.number);
        pot.claim(roundB, devBalance, new bytes32[](0));
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);

        // bought but never published
        (, uint256 roundC) = _buy(1 ether);

        uint256[] memory ids = new uint256[](4);
        ids[0] = roundA;
        ids[1] = roundB; // already claimed
        ids[2] = roundC; // not published
        ids[3] = 999; // does not exist

        vm.prank(DEV);
        (uint256 total, uint256 rounds) = pot.claimMany(ids, _balances(devBalance, 4), _emptyProofs(4));

        assertEq(rounds, 1, "only round A was claimable");
        assertApproxEqAbs(total, outA, 1);
        // round B stayed claimed-once, its stock did not go out twice
        (,,,, uint256 stockAmount, uint256 paidOut,,) = pot.distributions(roundB);
        assertEq(stockAmount, outB);
        assertApproxEqAbs(paidOut, outB, 1);
    }

    function test_claim_many_rejects_a_ragged_batch() public {
        uint256[] memory ids = new uint256[](2);
        vm.startPrank(DEV);
        vm.expectRevert(SignedPot.BadBatch.selector);
        pot.claimMany(ids, _balances(1, 1), _emptyProofs(2));
        vm.expectRevert(SignedPot.BadBatch.selector);
        pot.claimMany(ids, _balances(1, 2), _emptyProofs(1));
        vm.expectRevert(SignedPot.BadBatch.selector);
        pot.claimMany(new uint256[](0), _balances(1, 0), _emptyProofs(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // claim window + rollover - unclaimed stock must not be stranded
    // ------------------------------------------------------------------

    function test_claim_window_closes_and_says_when() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (, uint256 roundId) = _buy(1 ether);
        vm.prank(DEV);
        pot.publishDistribution(roundId, _leaf(DEV, devBalance), devBalance, block.number);
        uint256 closesAt = pot.claimClosesAt(roundId);
        assertEq(closesAt, block.timestamp + 90 days);

        bytes32[] memory proof = new bytes32[](0);
        vm.warp(closesAt + 1);
        assertEq(pot.claimable(roundId, DEV, devBalance, proof), 0);
        vm.prank(DEV);
        vm.expectRevert(abi.encodeWithSelector(SignedPot.ClaimWindowClosed.selector, roundId, closesAt));
        pot.claim(roundId, devBalance, proof);
    }

    /// The failure this fixes: before rollover existed, stock nobody claimed sat
    /// in the pot forever, on a product whose whole promise is that it leaves.
    function test_rollover_hands_unclaimed_stock_to_the_next_round() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (uint256 out0, uint256 round0) = _buy(1 ether);
        vm.prank(DEV);
        pot.publishDistribution(round0, _leaf(DEV, devBalance), devBalance, block.number);

        // nobody claims, the window closes
        vm.warp(block.timestamp + 90 days + 1);
        uint256 potHeld = IERC20(NVDA).balanceOf(address(pot));

        vm.prank(stranger); // permissionless on purpose
        uint256 rolled = pot.rollover(round0);
        assertEq(rolled, out0);
        assertEq(pot.rolledOver(NVDA), out0);
        // rollover is bookkeeping: not one unit of stock moved
        assertEq(IERC20(NVDA).balanceOf(address(pot)), potHeld);

        // the next buy of the same stock picks the credit up
        (uint256 out1, uint256 round1) = _buy(1 ether);
        (,,,, uint256 stockAmount,,,) = pot.distributions(round1);
        assertEq(stockAmount, out1 + out0, "round1 pays its own buy plus the dead round");
        assertEq(pot.rolledOver(NVDA), 0);

        // and a holder actually receives all of it
        uint256 before = IERC20(NVDA).balanceOf(DEV);
        vm.startPrank(DEV);
        pot.publishDistribution(round1, _leaf(DEV, devBalance), devBalance, block.number);
        pot.claim(round1, devBalance, new bytes32[](0));
        vm.stopPrank();
        assertApproxEqAbs(IERC20(NVDA).balanceOf(DEV) - before, out0 + out1, 1);
    }

    function test_rollover_only_after_the_window_and_only_once() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (, uint256 round0) = _buy(1 ether);

        vm.expectRevert(abi.encodeWithSelector(SignedPot.NoSuchRound.selector, 999));
        pot.rollover(999);
        // Unpublished, but the clock started at the buy: this is our deadline
        // to publish, not the holder's to claim.
        uint256 publishBy = block.timestamp + pot.CLAIM_WINDOW();
        vm.expectRevert(abi.encodeWithSelector(SignedPot.ClaimWindowOpen.selector, round0, publishBy));
        pot.rollover(round0);

        vm.prank(DEV);
        pot.publishDistribution(round0, _leaf(DEV, devBalance), devBalance, block.number);
        uint256 closesAt = pot.claimClosesAt(round0);

        vm.expectRevert(abi.encodeWithSelector(SignedPot.ClaimWindowOpen.selector, round0, closesAt));
        pot.rollover(round0);

        vm.warp(closesAt + 1);
        pot.rollover(round0);
        vm.expectRevert(abi.encodeWithSelector(SignedPot.AlreadyRolled.selector, round0));
        pot.rollover(round0);
    }

    /// A round that was fully claimed has nothing left to roll, and rolling it
    /// must not invent credit out of thin air.
    function test_rollover_of_a_fully_claimed_round_credits_nothing() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (uint256 out, uint256 roundId) = _buy(1 ether);
        vm.startPrank(DEV);
        pot.publishDistribution(roundId, _leaf(DEV, devBalance), devBalance, block.number);
        uint256 got = pot.claim(roundId, devBalance, new bytes32[](0));
        vm.stopPrank();
        assertEq(got, out);

        vm.warp(block.timestamp + 90 days + 1);
        assertEq(pot.rollover(roundId), 0);
        assertEq(pot.rolledOver(NVDA), 0);
    }

    /// The claim page reads N rounds in one RPC call; make sure it agrees with
    /// what claimMany would actually pay.
    function test_claimable_many_matches_what_claim_many_pays() public {
        uint256 devBalance = signed.balanceOf(DEV);
        bytes32 leaf = _leaf(DEV, devBalance);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            (, uint256 roundId) = _buy(1 ether);
            ids[i] = roundId;
            if (i != 2) {
                // leave the last round unpublished on purpose
                vm.prank(DEV);
                pot.publishDistribution(roundId, leaf, devBalance, block.number);
            }
            vm.warp(block.timestamp + 1 hours);
        }

        uint256[] memory quoted = pot.claimableMany(ids, DEV, _balances(devBalance, 3), _emptyProofs(3));
        assertGt(quoted[0], 0);
        assertGt(quoted[1], 0);
        assertEq(quoted[2], 0, "unpublished round quotes zero");

        vm.prank(DEV);
        (uint256 total, uint256 rounds) = pot.claimMany(ids, _balances(devBalance, 3), _emptyProofs(3));
        assertEq(rounds, 2);
        assertEq(total, quoted[0] + quoted[1]);

        // after claiming, the quote goes to zero rather than lying
        uint256[] memory afterClaim = pot.claimableMany(ids, DEV, _balances(devBalance, 3), _emptyProofs(3));
        assertEq(afterClaim[0], 0);
        assertEq(afterClaim[1], 0);
    }

    // ------------------------------------------------------------------
    // the off-chain builder has to agree with _verify, or every claim reverts
    // ------------------------------------------------------------------

    /// Root and proofs below were produced by ../merkle.py from these five
    /// holders. Nothing in this test computes them: if merkle.py ever stops
    /// matching _verify, this is what says so.
    ///   python3 merkle.py --selftest   builds the same shape
    function test_tree_built_by_merkle_py_verifies_and_pays() public {
        address[5] memory addrs = [
            0x547F05472B7f0C6948e05a46062682a0980B0160,
            0x00000000000000000000000000000000000000A1,
            0x00000000000000000000000000000000000000b2,
            0x00000000000000000000000000000000000000C3,
            0x00000000000000000000000000000000000000D4
        ];
        uint256[5] memory bals = [
            uint256(1000000000000000000000), 250000000000000000000, 75500000000000000000, 1000000000000000000, 500000000000000000
        ];
        bytes32 pyRoot = 0x63ea045c5dd155aa5d3ff2b8bb4865d4ddc0b85f3fc52d47ae855ff719eabcc7;
        uint256 eligible = 1327000000000000000000;

        (uint256 out, uint256 roundId) = _buy(1 ether);
        vm.prank(DEV);
        pot.publishDistribution(roundId, pyRoot, eligible, block.number);

        uint256 paid;
        for (uint256 i = 0; i < 5; i++) {
            bytes32[] memory proof = _pyProof(i);
            assertGt(pot.claimable(roundId, addrs[i], bals[i], proof), 0, "python proof rejected");
            vm.prank(addrs[i]);
            paid += pot.claim(roundId, bals[i], proof);
        }
        // the five of them are the whole snapshot, so they take the whole round
        assertApproxEqAbs(paid, out, 5);
        assertLe(paid, out, "a round must never pay out more than it bought");
    }

    function _pyProof(uint256 i) private pure returns (bytes32[] memory p) {
        bytes32 A = 0xf3a41d4b77c9ed5f8e0c22268c36b13a0af4f017b24783b6c9eeee6b567bcc84;
        bytes32 B = 0xbc35b1459793ff2626ad61bda263cd2fc74ffbf54e91a677279b3bef80377646;
        bytes32 C = 0x9a2e02c98c19afeec24bbc7cb23e3b18eaae91de4a60378820a6e3b3dfbb5525;
        if (i == 3) {
            p = new bytes32[](1);
            p[0] = 0xd8f7528edd7d219ac17898f5fb1ea9cfbdd7e744a14d1d5956d02a8a2828e9d2;
            return p;
        }
        p = new bytes32[](3);
        p[1] = (i == 1 || i == 2) ? C : B;
        p[2] = A;
        if (i == 0) p[0] = 0x32ea7e64f40f279c939c5ddf9b4056a8cf07a6aabf0a3fd2b9b6e198b75aaaeb;
        if (i == 1) p[0] = 0x941ae79272d02e0aefe6158e27840a3aba74a4b219b4b2483fe5ff7e09294d95;
        if (i == 2) p[0] = 0xa29f7cebf45a48aa24d7fafeea8a42f91d81278d8ff1b754c5d60ecfde0c6fac;
        if (i == 4) p[0] = 0x4121ac48a4fb7d34078fbb38632367a06e6d3aa99589fae7463d814d3959f9ff;
    }

    /// CLAIM_BATCH in the frontend is 40 rounds a transaction. If that does not
    /// fit in a block, the claim button is broken for exactly the people who
    /// held longest — so measure it rather than guess.
    function test_claim_many_batch_size_fits_in_a_block() public {
        uint256 devBalance = signed.balanceOf(DEV);
        bytes32 leaf = _leaf(DEV, devBalance);
        uint256 n = 12;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (, uint256 roundId) = _buy(0.05 ether);
            ids[i] = roundId;
            vm.prank(DEV);
            pot.publishDistribution(roundId, leaf, devBalance, block.number);
            vm.warp(block.timestamp + 1 hours);
        }

        vm.prank(DEV);
        uint256 before = gasleft();
        (, uint256 rounds) = pot.claimMany(ids, _balances(devBalance, n), _emptyProofs(n));
        uint256 used = before - gasleft();
        assertEq(rounds, n);

        uint256 perRound = used / n;
        emit log_named_uint("gas for 12 rounds", used);
        emit log_named_uint("gas per round", perRound);
        emit log_named_uint("projected gas for 40", perRound * 40);
        // Proofs here are empty (single-leaf tree); a real 12-deep proof adds
        // roughly a dozen keccaks per round, which is noise next to the transfer.
        assertLt(perRound * 40, 15_000_000, "CLAIM_BATCH of 40 would not fit in a block");
    }


    // ------------------------------------------------------------------
    // push - we pay the gas, the snapshot picks the destination
    // ------------------------------------------------------------------

    /// The point of the whole thing: a holder who never opens the site, never
    /// connects a wallet and never signs anything still ends up with the stock.
    function test_operator_pushes_stock_to_a_holder_who_never_claims() public {
        uint256 transferAmount = signed.balanceOf(DEV) / 3;
        vm.prank(DEV);
        signed.transfer(alice, transferAmount);
        uint256 aliceBalance = signed.balanceOf(alice);
        uint256 devBalance = signed.balanceOf(DEV);
        uint256 eligible = devBalance + aliceBalance;

        (uint256 out, uint256 roundId) = _buy(2 ether);
        bytes32 devLeaf = _leaf(DEV, devBalance);
        bytes32 aliceLeaf = _leaf(alice, aliceBalance);
        vm.prank(DEV);
        pot.publishDistribution(roundId, _root(devLeaf, aliceLeaf), eligible, block.number);

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = devLeaf;

        uint256 before = IERC20(NVDA).balanceOf(alice);
        vm.prank(DEV);
        (uint256 total, uint256 rounds) = pot.distributeTo(alice, _ids(roundId), _balances(aliceBalance, 1), proofs);

        assertEq(rounds, 1);
        assertApproxEqAbs(total, out * aliceBalance / eligible, 1);
        assertApproxEqAbs(IERC20(NVDA).balanceOf(alice) - before, total, 1, "alice never signed anything");
        assertTrue(pot.paid(roundId, alice));

        // and it cannot be pushed twice
        vm.prank(DEV);
        vm.expectRevert(SignedPot.NothingClaimed.selector);
        pot.distributeTo(alice, _ids(roundId), _balances(aliceBalance, 1), proofs);
    }

    /// A pusher supplies the proof but cannot aim the payout. The recipient is
    /// the address inside the leaf, so pushing someone else's share to yourself
    /// is not a thing the contract can express.
    function test_push_pays_the_snapshot_address_not_the_caller() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (uint256 out, uint256 roundId) = _buy(1 ether);
        vm.prank(DEV);
        pot.publishDistribution(roundId, _leaf(DEV, devBalance), devBalance, block.number);

        // DEV pays the gas, and DEV is also the snapshot holder here - so aim
        // it at bob instead and watch the proof stop matching.
        vm.prank(DEV);
        vm.expectRevert(SignedPot.NothingClaimed.selector);
        pot.distributeTo(bob, _ids(roundId), _balances(devBalance, 1), _emptyProofs(1));

        uint256 bobBefore = IERC20(NVDA).balanceOf(bob);
        uint256 devBefore = IERC20(NVDA).balanceOf(DEV);
        vm.prank(DEV);
        pot.distributeTo(DEV, _ids(roundId), _balances(devBalance, 1), _emptyProofs(1));
        assertEq(IERC20(NVDA).balanceOf(bob), bobBefore, "bob was never in the snapshot");
        assertApproxEqAbs(IERC20(NVDA).balanceOf(DEV) - devBefore, out, 1);
    }

    function test_push_is_operator_only() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (, uint256 roundId) = _buy(1 ether);
        vm.prank(DEV);
        pot.publishDistribution(roundId, _leaf(DEV, devBalance), devBalance, block.number);

        address[] memory who = new address[](1);
        who[0] = DEV;
        vm.startPrank(stranger);
        vm.expectRevert(SignedPot.NotOperator.selector);
        pot.distributeTo(DEV, _ids(roundId), _balances(devBalance, 1), _emptyProofs(1));
        vm.expectRevert(SignedPot.NotOperator.selector);
        pot.distribute(_ids(roundId), who, _balances(devBalance, 1), _emptyProofs(1));
        vm.stopPrank();

        // the holder can still take it themselves - that is the fail-open
        vm.prank(DEV);
        assertGt(pot.claim(roundId, devBalance, new bytes32[](0)), 0);
    }

    /// Aggregation is what makes a sweep affordable: three rounds of the same
    /// stock must leave the contract as ONE transfer, not three.
    function test_push_aggregates_one_transfer_per_stock() public {
        uint256 devBalance = signed.balanceOf(DEV);
        bytes32 leaf = _leaf(DEV, devBalance);
        uint256[] memory ids = new uint256[](3);
        uint256 expected;
        for (uint256 i = 0; i < 3; i++) {
            (uint256 out, uint256 roundId) = _buy(1 ether);
            expected += out;
            ids[i] = roundId;
            vm.prank(DEV);
            pot.publishDistribution(roundId, leaf, devBalance, block.number);
            vm.warp(block.timestamp + 1 hours);
        }

        vm.recordLogs();
        vm.prank(DEV);
        (uint256 total,) = pot.distributeTo(DEV, ids, _balances(devBalance, 3), _emptyProofs(3));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == NVDA && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")) {
                transfers++;
            }
        }
        assertEq(transfers, 1, "three rounds of one stock must cost one transfer");
        assertApproxEqAbs(total, expected, 3);
    }

    /// The keeper shape: one call, one round, every wallet in the snapshot.
    function test_distribute_pays_many_holders_in_one_call() public {
        uint256 transferAmount = signed.balanceOf(DEV) / 3;
        vm.prank(DEV);
        signed.transfer(alice, transferAmount);
        uint256 devBalance = signed.balanceOf(DEV);
        uint256 aliceBalance = signed.balanceOf(alice);
        uint256 eligible = devBalance + aliceBalance;

        (uint256 out, uint256 roundId) = _buy(2 ether);
        bytes32 devLeaf = _leaf(DEV, devBalance);
        bytes32 aliceLeaf = _leaf(alice, aliceBalance);
        vm.prank(DEV);
        pot.publishDistribution(roundId, _root(devLeaf, aliceLeaf), eligible, block.number);

        uint256[] memory ids = new uint256[](2);
        ids[0] = roundId;
        ids[1] = roundId;
        address[] memory who = new address[](2);
        who[0] = DEV;
        who[1] = alice;
        uint256[] memory bals = new uint256[](2);
        bals[0] = devBalance;
        bals[1] = aliceBalance;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = aliceLeaf;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = devLeaf;

        vm.prank(DEV);
        (uint256 total, uint256 rounds) = pot.distribute(ids, who, bals, proofs);

        assertEq(rounds, 2);
        assertApproxEqAbs(total, out, 2, "the two of them are the whole snapshot");
        // alice is a fresh address, so her balance IS her share - and she never
        // sent a transaction in this test.
        assertApproxEqAbs(IERC20(NVDA).balanceOf(alice), out * aliceBalance / eligible, 1);
        assertTrue(pot.paid(roundId, DEV) && pot.paid(roundId, alice));
    }

    // ------------------------------------------------------------------
    // an unpublished round must not strand
    // ------------------------------------------------------------------

    /// publishDistribution() is operator-only, so before this fix a round we
    /// bought and never published was stuck forever: claim() refused it for
    /// want of a root, and so did rollover(). The gap between buy and publish
    /// is normal operation, so this is the likely way to lose stock, not a
    /// far-fetched one.
    function test_unpublished_round_rolls_over_instead_of_stranding() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (uint256 out0, uint256 round0) = _buy(1 ether);

        // never published. wait out our deadline to publish.
        vm.warp(block.timestamp + 90 days + 1);
        uint256 held = IERC20(NVDA).balanceOf(address(pot));

        vm.prank(stranger); // permissionless, as rollover always was
        assertEq(pot.rollover(round0), out0);
        assertEq(pot.rolledOver(NVDA), out0);
        assertEq(IERC20(NVDA).balanceOf(address(pot)), held, "bookkeeping only");

        // it can never be published now - that would promise the same units twice
        vm.prank(DEV);
        vm.expectRevert(abi.encodeWithSelector(SignedPot.AlreadyRolled.selector, round0));
        pot.publishDistribution(round0, _leaf(DEV, devBalance), devBalance, block.number);

        // and the stock reaches holders through the next round of that stock
        vm.warp(block.timestamp + 1 hours);
        (uint256 out1, uint256 round1) = _buy(1 ether);
        (,,,, uint256 stockAmount,,,) = pot.distributions(round1);
        assertEq(stockAmount, out1 + out0);

        uint256 before = IERC20(NVDA).balanceOf(DEV);
        vm.startPrank(DEV);
        pot.publishDistribution(round1, _leaf(DEV, devBalance), devBalance, block.number);
        pot.claim(round1, devBalance, new bytes32[](0));
        vm.stopPrank();
        assertApproxEqAbs(IERC20(NVDA).balanceOf(DEV) - before, out0 + out1, 1);
    }


    // ------------------------------------------------------------------
    // delivery gas comes out of the pot, never out of the dev wallet
    // ------------------------------------------------------------------

    function test_harvest_sets_aside_a_share_for_delivery_gas() public {
        _fund(1 ether);
        assertEq(pot.gasReserve(), 0.2 ether, "20% of the harvest is delivery money");
        assertEq(address(pot).balance, 1 ether, "all of it is still here, just earmarked");
    }

    /// The failure this prevents: a full-size buy empties the pot, and then the
    /// push that hands the stock out has nothing to pay gas with.
    function test_buy_cannot_spend_the_delivery_reserve() public {
        _fund(1 ether);
        vm.prank(DEV);
        pot.buy(NVDA, 1 ether, FEE, FEE, 1, bytes32(0)); // asks for everything

        assertEq(address(pot).balance, 0.2 ether, "the reserve survived the buy");
        assertEq(pot.gasReserve(), 0.2 ether);
    }

    function test_push_is_refunded_from_the_reserve_but_a_claim_is_not() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (, uint256 roundA) = _buy(1 ether);
        vm.prank(DEV);
        pot.publishDistribution(roundA, _leaf(DEV, devBalance), devBalance, block.number);

        uint256 reserveBefore = pot.gasReserve();
        uint256 ethBefore = DEV.balance;
        vm.prank(DEV);
        pot.distributeTo(DEV, _ids(roundA), _balances(devBalance, 1), _emptyProofs(1));

        uint256 allowance = pot.GAS_PER_PAYOUT();
        assertEq(DEV.balance - ethBefore, allowance, "the pot paid the operator back");
        assertEq(reserveBefore - pot.gasReserve(), allowance, "and it came out of the reserve");

        // a holder pulling their own stock is not reimbursed - they chose to pay
        vm.warp(block.timestamp + 1 hours);
        (, uint256 roundB) = _buy(1 ether);
        vm.startPrank(DEV);
        pot.publishDistribution(roundB, _leaf(DEV, devBalance), devBalance, block.number);
        uint256 reserveAtClaim = pot.gasReserve();
        uint256 ethAtClaim = DEV.balance;
        pot.claim(roundB, devBalance, new bytes32[](0));
        vm.stopPrank();
        assertEq(pot.gasReserve(), reserveAtClaim, "claim must not touch the reserve");
        assertEq(DEV.balance, ethAtClaim);
    }

    /// A short reserve must not revert a push that already moved stock.
    function test_a_short_reserve_part_pays_rather_than_reverting() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (, uint256 roundId) = _buy(1 ether);
        vm.prank(DEV);
        pot.publishDistribution(roundId, _leaf(DEV, devBalance), devBalance, block.number);

        // drain the reserve down to less than one payout's allowance
        uint256 crumb = pot.GAS_PER_PAYOUT() / 4;
        vm.store(address(pot), bytes32(uint256(2)), bytes32(crumb));
        assertEq(pot.gasReserve(), crumb, "storage slot 2 is gasReserve");

        uint256 ethBefore = DEV.balance;
        vm.prank(DEV);
        pot.distributeTo(DEV, _ids(roundId), _balances(devBalance, 1), _emptyProofs(1));

        assertEq(DEV.balance - ethBefore, crumb, "paid what was there, not what was owed");
        assertEq(pot.gasReserve(), 0);
        assertGt(IERC20(NVDA).balanceOf(DEV), 0, "and the stock still went out");
    }

    /// Without the block on chain, "anyone can rebuild the tree and check us"
    /// is false - a verifier would have to be told which block to replay to.
    function test_publish_records_the_snapshot_block_and_rejects_a_future_one() public {
        uint256 devBalance = signed.balanceOf(DEV);
        (, uint256 roundId) = _buy(1 ether);

        vm.startPrank(DEV);
        vm.expectRevert(SignedPot.InvalidDistribution.selector);
        pot.publishDistribution(roundId, _leaf(DEV, devBalance), devBalance, block.number + 1);
        vm.expectRevert(SignedPot.InvalidDistribution.selector);
        pot.publishDistribution(roundId, _leaf(DEV, devBalance), devBalance, 0);

        uint256 at = block.number - 3;
        pot.publishDistribution(roundId, _leaf(DEV, devBalance), devBalance, at);
        vm.stopPrank();

        (,, uint48 snapshotBlock,,,,,) = pot.distributions(roundId);
        assertEq(uint256(snapshotBlock), at);
    }

    function _ids(uint256 id) private pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = id;
    }


    /// The real trust boundary, written down so nobody mistakes it again.
    ///
    /// publishDistribution() takes `eligibleSupply` as an operator-supplied
    /// number with no relation to the token's actual supply, and the root is
    /// whatever the operator says. So the operator can name one address as the
    /// entire snapshot and that address takes 100% of the round through the
    /// ordinary permissionless claim() path - no special transfer function
    /// needed, which is why a bytecode audit reports "no path to a transfer".
    ///
    /// What protects holders is not that this is impossible. It is that
    /// snapshot.py is reproducible from chain history, so a false root can be
    /// proven false by anyone. Detectable, not prevented. Say that, not
    /// "trustless".
    function test_operator_can_take_a_whole_round_by_publishing_a_false_root() public {
        (uint256 out, uint256 roundId) = _buy(1 ether);
        address thief = makeAddr("thief");
        uint256 fake = 1000;

        vm.prank(DEV);
        pot.publishDistribution(roundId, _leaf(thief, fake), fake, block.number);

        uint256 before = IERC20(NVDA).balanceOf(thief);
        vm.prank(thief);
        uint256 got = pot.claim(roundId, fake, new bytes32[](0));

        assertEq(got, out, "operator took the entire round");
        assertEq(IERC20(NVDA).balanceOf(thief) - before, out);
    }

    function _balances(uint256 value, uint256 n) private pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = value;
        }
    }

    function _emptyProofs(uint256 n) private pure returns (bytes32[][] memory out) {
        out = new bytes32[][](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = new bytes32[](0);
        }
    }
}
