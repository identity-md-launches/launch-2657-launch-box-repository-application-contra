# Box

Pay for an IdentityMD swarm request in imdUSD.

A user pays for an order that an off-chain evaluator quoted. In one call to `pay`:

- the cost of the order's first request goes to the **float** at once (an operator wallet that pays the swarm in IMD),
- a small buffer goes to the imdUSD **Treasury**,
- anything else (the later steps of a chained order) is held in the contract as **escrow**.

`Paid` carries `commitment = keccak256(request body)`, so the body later sent to the swarm can be checked against it.

Escrow leaves the contract only by:

- **`settle` / `settleMany`**: an EIP-712 `Settlement{key, toTreasury, toFloat, toPayer}` signed by `SIGNER`, which must
  add up to the order's escrow exactly. Anyone may execute one. The signer can only split one order's escrow among the
  Treasury, the float and that order's payer.
- **`reclaim`**: the payer takes the escrow back if no settlement was executed within 60 days of payment.

Orders are stored under `keyOf(payer, orderId)`, so another wallet cannot take an order id from the mempool.
There is no owner, no pause, no upgrade. The contract checks no prices: the operator sends only orders whose `Paid`
matches its own quote.

Constants on mainnet: imdUSD v1 `0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25` (plain ERC-20, 18 decimals, no permit),
Treasury `0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc`.


`settleMany` skips an entry whose order is already closed (reclaimed, settled on its own ahead of the batch, or
repeated in the batch) and settles the rest; any other failing entry (unknown order, wrong total, bad signature)
still reverts the whole batch.

## Trust assumptions and things to know

- **Do not transfer imdUSD (or any token) to the Box directly.** Only `pay` creates escrow; tokens sent any other way
  belong to no order and no function can move them.
- **An orderId is unique per payer, not globally.** Two wallets can pay the same quote; their `Paid` events differ
  only in `payer` and `key`. The operator's quote should bind the payer address, and its matcher should check
  `Paid.payer`. Once a payer has used an orderId, it is spent for that payer even if the payment was wrong, so a
  retry needs a fresh orderId.
- **Settlements never expire.** A signed settlement can be executed by anyone at any time until the order is closed,
  including after the 60-day mark, when it races the payer's `reclaim` (both are allowed from exactly
  `paidAt + 60 days`; whichever lands first closes the order).
- **SIGNER and FLOAT are immutable EOAs.** A compromised SIGNER can only split each *open* order's escrow among the
  Treasury, the float and that order's payer. If the SIGNER key is lost, every open escrow goes back to its payer via
  `reclaim`. If the FLOAT key is lost, later payments still send `toFloat` there. Neither can be rotated on-chain.
- **imdUSD's vault can mint and burn any balance**, including the Box's escrow (live imdUSD exposes
  `mint`/`burn` callable by its `vault()`). The Box keeps its balance equal to the sum of open escrow; only the token
  can break that, after which the last settlements or reclaims of open orders would revert.

Tests:

    forge test --no-match-contract BoxForkTest                       # unit
    MAINNET_RPC_URL=<rpc> forge test --match-contract BoxForkTest    # same suite against live imdUSD

`test/BoxInvariant.t.sol` (part of the unit run) checks, over random pay/settle/settleMany/reclaim/warp sequences,
that the Box's balance equals the sum of open escrow and that the Treasury and float receive exactly what was routed.
