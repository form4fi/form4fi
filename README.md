# FORM-4 FI

**They signed for it. So did we.**

The fee wallet behind **FORM-4** ($FORM4) on Robinhood Chain.

When a company insider buys their own stock they have to file a Form 4 with the SEC.
FORM-4 buys what they bought. Trading fees from the $FORM4 token go into this
contract, the contract turns them into the actual Robinhood stock token, and the
shares reach $FORM4 holders — pushed to their wallets by the operator, or pulled by
the holder with a claim, whichever comes first.

There is no staking, no upgrade, and no withdraw function. The operator is the
wallet that launched $FORM4: it picks which stock and when, publishes the holder
snapshot for each buy, and can deliver shares against that snapshot.

Contract: `src/SignedPot.sol` (SignedPot is the contract name; FORM-4 is the
product). One file, no dependencies, ~760 lines.

## How the money moves

```
someone trades $FORM4 on Pons
  -> Pons takes its cut, the creator tax goes to this contract's escrow balance
  -> harvest()          anyone. pulls the ETH from the Pons escrow into the pot
  -> buy(stock, ...)    operator. swaps the ETH for one Robinhood stock on Uniswap v3
  -> publishDistribution()  operator. fixes the holder snapshot for that buy,
                            with the block it was taken at
  -> claim() / claimMany()  holders. prove and pull their snapshot share
  -> distribute() / distributeTo()
                            operator. push a holder's share to them, against
                            the same proof they would have used. the pot
                            reimburses the gas from a reserve it kept back
  -> rollover()             anyone, once a round's window has closed, published
                            or not. what nobody took is credited to the next
                            round of that same stock
```

That is the whole list. Every transfer in the contract is one of these:

- ETH in: only from the Pons fee escrow, via `harvest()`. A fifth of every harvest
  is set aside as `gasReserve`; `buy()` cannot see it.
- ETH out: into WETH, then to a Uniswap v3 pool, inside `buy()` — and a flat
  `GAS_PER_PAYOUT` to the operator per holder it pushes stock to, out of the
  reserve and never out of anything else.
- Stock in: only from a Uniswap v3 pool, to the contract itself.
- Stock out: only to the address inside a valid snapshot leaf, once per buy round,
  and never more per round than that round bought. Whether the holder claims it or
  the operator pushes it, the destination comes from the proof, not the caller.
- `rollover()` moves nothing. It is bookkeeping: an expired round's remainder is
  re-labelled as credit for its stock, and the next round of that stock pays it
  to holders. The stock never leaves the contract on that path.
- $FORM4 never enters the pot. Hold it in your wallet.

## Holder distribution

Stock is split by each wallet's $FORM4 balance at a fixed block. No staking, no
approval, no sign-up. Each buy opens its own distribution round carrying a Merkle
root, the eligible supply, the stock amount, and the block the snapshot was taken
at. A proof binds a recorded balance to one wallet, and each wallet takes each
round once — moving $FORM4 after the snapshot does not create a second claim.

The Pons token is a plain ERC20 and keeps no historical balances, so the snapshot
is built from the token's own `Transfer` logs and published on chain together with
the block it was taken at. That block is what makes a round checkable after the
fact: replay the same logs to the same block with `../snapshot.py`, rebuild the
tree, and compare the root against the one stored in the round. The builder is
dependency-free and lives in the repo so that comparison needs nothing from us.

### Claiming in batches

The pot can buy every hour, so a holder accumulates one claimable round per buy.
`claimMany` takes as many rounds as fit in a transaction. Rounds in the batch that
are not claimable — unpublished, expired, already taken, or not yours — are skipped
rather than reverting the whole batch, so one stale entry in a proof file does not
cost you the other ninety-nine. It reverts only when nothing at all was claimable.
`claimableMany` is the matching view, so a page can price the whole batch in one
call instead of one per round.

### Or we push it

The operator can also deliver a holder's share without the holder doing anything:
`distributeTo(account, ...)` for one wallet across many rounds, `distribute(...)`
for many wallets at once. Both take the same proofs a claim would, and the
recipient is the address inside the leaf — a pusher cannot aim a payout at itself
or anywhere else. Rounds of the same stock collapse into one transfer, for a push
and for a `claimMany` alike.

Push gas comes out of the pot, not the operator's pocket. `harvest()` keeps back
`RESERVE_BPS` (20%) of every harvest as `gasReserve`, which `buy()` cannot spend,
and each push reimburses the operator `GAS_PER_PAYOUT` per holder actually paid.
It is a flat allowance rather than measured gas on purpose: `tx.gasprice` is chosen
by the caller, so refunding real cost would leave the reserve open to being drained
in a single call. Claims are not reimbursed; a holder who pulls pays their own.

### Rounds expire

A round stays claimable for `CLAIM_WINDOW`, 90 days from the moment it was
published. After that `claim` reverts with `ClaimWindowClosed` and anyone may call
`rollover(roundId)`, which credits the unclaimed remainder to that stock. The next
`buy()` of the same stock adds the credit to its own round, where a fresh snapshot
hands it out.

The same clock covers a round that was bought but never published: it starts at
the buy, and 90 days later `rollover` accepts the round with no root at all.
Without that, a round the operator stopped short of publishing was stuck forever —
`claim` refused it for want of a root and so did `rollover` — and the gap between
buy and publish is ordinary operation, every round. A rolled round can never be
published afterwards, so its stock cannot be promised twice.

Without expiry at all, stock that nobody collected would sit in the contract
permanently, on a product whose entire promise is that the stock leaves.

## What the contract enforces

`buy()` and `publishDistribution()` are operator-only. Everything below holds on
every buy regardless of who is asking:

- The stock must be a real Robinhood stock token. Every one of them is a beacon
  proxy with runtime codehash `0x6c1fdd40…5630`, checked on chain. A fake GME, the
  $FORM4 token itself, WETH, or any pool anyone controls: revert. That covers all
  177 Robinhood companies, not a fixed list.
- Output always lands in this contract. There is no recipient parameter.
- `minOut` must be non-zero. The floor is quoted off-chain and passed in; if the
  pool returns less, revert and the ETH stays put.
- One buy per hour, and each buy must spend at least a quarter of the pot.
- Paused stock oracle, or no pool at the fee tier given: revert.

| Try | Result |
|---|---|
| call `withdraw` | does not exist |
| upgrade it | no proxy |
| call `buy` yourself | operator only |
| point `buy` at a token you control | codehash check: only real Robinhood stock tokens pass |
| buy to your own wallet | output recipient is hardcoded to the contract |
| sandwich a buy | operator-triggered only, with a non-zero `minOut` from a fresh quote |
| push someone's share to yourself | recipient is the address in the leaf, not the caller |
| drain the pot through gas refunds | flat allowance per holder actually paid, capped by a reserve `buy()` never touches; claims refund nothing |
| move tokens and claim twice | proof binds wallet and snapshot balance; one claim per round |
| pay a round out twice | a round can never pay out more stock than it bought |
| re-enter via the swap callback | callback only accepts the pool the contract just called |
| point the Pons fees somewhere else | the recipient is this contract, and it has no function that calls Pons to move it |

Earlier versions used a Chainlink floor and a 35-name allowlist instead of an
operator gate. That only covered the stocks with a public feed, which is most of the
names a Form 4 never lands on. We would rather buy the actual stock the insider bought.

## Platform limits

Two properties of the platforms underneath, neither of them specific to this
contract:

- Pons's factory owner can reassign any launch's fee recipient after a 3-day
  timelock. It is in their verified source, and it is public for three days before
  it takes effect.
- Robinhood can pause or blocklist a stock token. While a token is paused, `buy`
  and `claim` for it revert until they unpause. Fail closed.

## Which stocks

Any real Robinhood stock token. The contract does not carry a list; it checks the
token's runtime codehash against `0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630`,
which every Robinhood stock-token beacon proxy shares (NVDA, AAPL, TSLA... verified on
chain, and asserted again by the deploy script). Dexscreener returns nine fake GMEs and
four fake NVDAs. None of them pass.

`universe/allowlist.json` is kept as research: the 35 names with a Chainlink feed and
their deepest pools. It is no longer read by the contract.

## Deployments

Robinhood Chain, chain id 4663.

| | Address |
|---|---|
| SignedPot | `0xf085483D167B24Ae5cFc3C8B1c9C564AB5F73c69` |

Deployed 2026-09-02 at block 52873804 in tx
`0x25d60507ad91edbc197e1bd39c0d0e9866a0e0f5ef592fd2a9bb76e08ba6eba6`, operator
`0x0F3807c87C4B1bBA350A3C37530aE4635407fd8D`, verified on
[Sourcify](https://repo.sourcify.dev/4663/0xf085483D167B24Ae5cFc3C8B1c9C564AB5F73c69)
and [Blockscout](https://robinhoodchain.blockscout.com/address/0xf085483D167B24Ae5cFc3C8B1c9C564AB5F73c69?tab=contract)
(exact match on both). Unbound until $FORM4 launches on Pons; `bind()` is the one call
that attaches the token, and it can only happen once.

Fixed addresses the contract talks to:

| | |
|---|---|
| Pons V2 factory | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` |
| Pons V2 fee escrow | `0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e` |
| Uniswap v3 factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |

## Using it

```solidity
harvest()                                  // move fees from Pons escrow into the pot
buy(stock, ethIn, feeWeth, feeUsdg, minOut, filing)
    // stock:   any real Robinhood stock token (codehash checked)
    // ethIn:   wei to spend, >= 25% of the pot and >= 0.001 ETH
    // feeWeth: v3 fee tier of the WETH pool (500 for WETH/USDG)
    // feeUsdg: v3 fee tier of the USDG/stock pool, or 0 to go WETH -> stock direct
    // minOut:  least stock accepted, must be > 0; quote it off-chain first
    // filing:  hash of the Form 4 accession or URL, stored in the Bought event
publishDistribution(roundId, holderRoot, eligibleSupply, snapshotBlock)   // operator

claim(roundId, holderBalance, proof)                      // one round
claimMany(roundIds[], holderBalances[], proofs[])         // many; skips what it cannot take;
                                                          // one transfer per stock
distributeTo(account, roundIds[], holderBalances[], proofs[])   // operator: push one wallet
distribute(roundIds[], accounts[], holderBalances[], proofs[])  // operator: push many
rollover(roundId)                          // anyone, after the window closes

// views
claimable(roundId, user, holderBalance, proof)
claimableMany(roundIds[], user, holderBalances[], proofs[])
claimClosesAt(roundId)                     // 0 if the round is not published
distributionsCount()
distributions(roundId)                     // stock, windowAt, snapshotBlock, rolled,
                                           // stockAmount, paidOut, eligibleSupply, holderRoot
paid(roundId, account)                     // true once claimed OR pushed
rolledOver(stock)                          // credit waiting for the next round
gasReserve()                               // ETH held back for delivery gas
isRobinhoodStock(stock)                    // would buy() accept this token
```

The snapshot side lives outside this repo, in `../merkle.py` and `../snapshot.py`:
a dependency-free keccak256 and Merkle builder, and the pass that replays the
token's `Transfer` logs, builds the tree, publishes the root and writes the proof
files the page serves. `test_tree_built_by_merkle_py_verifies_and_pays` pins the
two together — it publishes a root produced by that Python and claims against it,
so if the builder ever stops matching `_verify`, a test says so rather than a
holder finding out.

## Build and test

```
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge test --fork-url robinhood -vv
```

34 tests run against a fork of mainnet: a real Pons launch and real NVDA pools. They
cover the money paths, holder snapshot split, transfer-and-reclaim attack, operator
boundary on buy, publish and push, codehash fingerprint against real and fake tokens,
per-round payout cap, withdraw-style selectors, batch claiming (a bad entry is
skipped rather than reverting the batch; rounds of one stock become one transfer),
the claim window closing, rollover of published and unpublished rounds, the gas
reserve surviving a full-size buy, push refunds coming only from that reserve, the
snapshot block being recorded, and the cross-check that the off-chain Merkle builder
agrees with `_verify`.

Deploy is two scripts: `script/Deploy.s.sol`, then launch on Pons from the same
wallet with the pot as fee recipient, then `script/Bind.s.sol`. The pot binds once to
a token the Pons factory says was launched by the deploy wallet with the pot as
recipient. After that it is frozen.

## Not financial advice

Robinhood stock tokens are Regulation S instruments issued by Robinhood Assets
(Jersey) Limited. Not available to US persons. Read their prospectus, not ours.
