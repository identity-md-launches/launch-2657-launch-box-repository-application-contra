# Adaptation for launch

Launch: `evm_contracts` on Ethereum mainnet (chain id 1). One contract, `Box`, with constructor arguments
`[0x61aaf8a992a3143e2b0c9cb0030b9fe702854a25 (imdUSD v1), 0x6ac8ff96fb8dcf5d79a8ef1e59d9ac23f2bd27bc (Treasury),
0xfe0bac821272c9b905bac995bf4af2122b9ba741 (FLOAT), 0xb5d3289a90868da0a8d5a4283902a0a907a29ddf (SIGNER)]`.
No token, pool or distributor; no `launch.json` (the manifest step writes it).

## Launch rules: no change needed

The contract arrived launchable and none of this was changed:

- The constructor is nonpayable and takes four static `address` arguments (the 16-argument limit is not an issue). It
  makes no external call and only rejects zero addresses, so it runs on an empty chain.
- It has no owner, admin, pause, mint, blacklist, proxy, initializer, DELEGATECALL, CALLCODE or SELFDESTRUCT. Nothing
  is assigned from `msg.sender` or `tx.origin`. `$owner` is not used because Box has no privileged role. SIGNER is an
  outside value the brief gives, not an owner.
- OpenZeppelin ECDSA, EIP712 and SafeERC20 are used through internal functions only, so no library linking is needed.
- `foundry.toml` already has `bytecode_hash = "none"`. The build configuration and dependencies are untouched.

## Changes

| File | Change | Why |
|---|---|---|
| `src/Box.sol` (`settleMany`) | An entry whose order already exists and is closed is skipped (`continue`). Before, it reverted the whole batch with `OrderClosed`. Unknown orders, wrong totals and bad signatures still revert the batch. | Audit finding **ca391bf9** (low) reproduced: a payer reclaiming ahead of the keeper's batch, anyone executing one copied `(Settlement, signature)` pair ahead of it, or a key repeated in it made the whole batch revert. Every entry is still paid at most once, by the same `settle` code, to the same recipients. No new outflow, recipient or role. |
| `src/Box.sol` (NatSpec of `settleMany`) | The doc comment now describes the skip. | Follows the change above. |
| `test/Box.t.sol` | New tests in `BoxTest` (so `BoxForkTest` runs them against live imdUSD too): `test_settleManySkipsOrderReclaimedAhead`, `test_settleManySkipsOrderSettledAhead`, `test_settleManyDuplicateKeySettlesOnce` (all three fail on the original code with `OrderClosed()`), `test_settleManyStillRevertsOnUnknownOrWrongTotal`, plus the edge coverage finding **830e119f** asked for: replay on another chain id and on another Box, a settlement signed before pay, a high-s malleated signature, compact 64-byte and bad-v signatures, settle/reclaim at exactly the 60-day mark and settle 400 days later, max-uint128 escrow with a near-max uint64 timestamp, two wallets paying one orderId, and a direct transfer. | Test the fix and close the coverage gaps. |
| `test/Box.t.sol` (`BoxForkTest.setUp`) | Reads `MAINNET_RPC_URL` with `vm.envOr` and skips the fork suite when it is unset, instead of failing `setUp` in `vm.envString`. With it set, the suite runs exactly as before (35 pass against live imdUSD and the real Treasury). | Tests must pass with an empty environment: a plain `forge test` failed on the missing variable. |
| `test/BoxInvariant.t.sol` | New stateful invariant test (64 runs × 100 calls via inline config): the Box's balance equals the sum of open escrow, and the Treasury and float receive exactly what was routed to them, across random pay/settle/settleMany (including closed and duplicate entries)/reclaim/warp. | Conservation check after the change (finding 830e119f). |
| `README.md` | Describes the `settleMany` skip and adds a "Trust assumptions and things to know" section. | Findings 30ec834b, c5741fc1, b9968506, 0c1a39ec ask for these to be documented, not changed. |

The existing test `test_settleManyAllOrNothing` still passes unchanged: a bad signature on an open order still reverts
the batch.

## Audit findings not changed in code

- **30ec834b** (low): reproduces as described. Two wallets can pay the same orderId, and an orderId is spent per payer
  after one pay. This is not a defect: keying by orderId alone would bring back mempool squatting, and `Paid` already
  carries `payer`. Documented in the README (the quote should bind the payer).
- **c5741fc1** (low): reproduces (`test_directTransferIsNotEscrowAndCannotLeave`). Tokens sent outside `pay` are stuck.
  A sweep would be a new way for funds to leave, which the brief forbids. Documented in the README.
- **b9968506** (info): a trust assumption about the live imdUSD vault's mint/burn power, not a Box defect. Documented.
- **0c1a39ec** (info): trust assumptions (immutable SIGNER/FLOAT, settlements without expiry). Rotation or expiry
  would add a setter or change the design, which the brief forbids. Documented. The 60-day boundary behaviour is
  tested.
- **cbdd297e** (info): `settleMany` reports an array-length mismatch as `WrongTotal`. This reproduces but is cosmetic,
  with no effect on funds. The repository's own `test_settleManyLengthMismatch` and any keeper tooling expect this
  error, so it stays as it is.
- **a20c95ba** (info): the audit's scope and verdict. The answers below agree with it.

## Answers to the brief's questions

- Can anyone move more than an order's escrow, or move it to anyone other than TREASURY, FLOAT or the order's payer?
  **No.** `settle` reads the recipients from immutables and `o.payer`, and the split must equal `o.escrow`. `reclaim`
  pays `o.escrow` to the payer, identified by a key derived from `msg.sender`. `closed` is set before any transfer.
  Funds get stuck only when sent outside `pay` (c5741fc1).
- Signature replay or malleability: **no.** A replay across orders fails (the key is in the typed data), across
  contracts (`address(this)` in the domain), across chains (`chainid`, with the domain rebuilt on a fork), after
  reclaim or settle (`closed`), and with a duplicate key in `settleMany` (now skipped and paid once). OpenZeppelin
  ECDSA rejects high-s, 64-byte and bad-v signatures. All are tested.
- Settle vs reclaim at 60 days: both are allowed from exactly `paidAt + 60 days`. Whichever lands first closes the
  order. There is no off-by-one (the existing `test_reclaimAfter60Days`, plus `test_settleAndReclaimBothOpenAtBoundary`).
- Can the balance fall below the sum of open escrow? Not through Box (invariant test). Only the imdUSD vault's burn
  can do it (b9968506).
- uint128/uint64 packing is safe: `EscrowTooLarge` is checked before the cast, and a max-uint128 escrow round-trips
  (tested).
- Is anything missing from `Paid`? No, provided the operator's match includes `payer` (30ec834b).
- Is a SIGNER compromise limited to misdirecting open escrow among the three recipients? **Yes.**

## Checks run

- `forge build` passes.
- `FOUNDRY_FUZZ_SEED=0x9a66…830c forge test --no-match-contract BoxForkTest`: 36 passed (35 unit tests and the
  invariant suite).
- `MAINNET_RPC_URL=<public RPC> forge test --match-contract BoxForkTest`: 35 passed against live imdUSD and the real
  Treasury.
- No Slither or Mythril run. Neither tool is provided for this task.
