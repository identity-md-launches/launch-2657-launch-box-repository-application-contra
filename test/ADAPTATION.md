# Independent Box test contribution

Only `test/` changes in this contribution. This note is under `test/` because the assignment prohibits editing the root `ADAPTATION.md`. The accepted implementation and its earlier adaptations remain unchanged. No dependencies, configuration, deployment manifest, recipients, privileges, or outflow paths were added.

## Changes

| File | Change and purpose |
| --- | --- |
| `test/Box.t.sol` | Extend the shared local/fork suite with payment and settlement rollback at each transfer leg, batch rollback after late validation/transfer failure, quote-log decoding, full-range escrow splitting, immediate amounts above uint128, overflow rejection, malformed signatures, empty/closed batches, permanent order-id consumption, and packed-field/deadline boundaries. |
| `test/helpers/BoxSigning.sol` | Compute the published EIP-712 domain and settlement encoding independently of Box's getters. This catches a consistently incorrect type hash or domain that a self-referential signing helper could miss. |
| `test/Box.t.sol` (`test_settleSplitsEscrow`) | Compute the signature before `vm.prank(mallory)`. Previously, the signing helper called Box getters after the prank, consuming the intended caller override before `settle`. The existing permissionless-execution test now actually executes as Mallory. |
| `test/Box.t.sol` (time boundary helpers) | Capture the original timestamp with `vm.getBlockTimestamp()` before changing it. This avoids optimizer reuse of a timestamp read across a cheatcode mutation. |
| `test/Box.t.sol` (`BoxForkTest`) | Preserve the existing `MAINNET_RPC_URL` setup and skip only when it is empty. Add assertions for mainnet, live imdUSD code/decimals, Treasury code, and the supplied FLOAT/SIGNER being EOAs. No URL or block is hardcoded into a test; the brief specifies no fork block. |
| `test/BoxModelInvariant.t.sol` | Add an independent ledger and order-state model, keeping the original invariant suite. Five funded actors include Treasury and FLOAT; an unrelated executor starts with no tokens. Random actions include valid/invalid pay, settle, duplicate-key batches, invalid batches, reclaim, signature substitution, replay, allowance failures, donations, time advancement, and full refund round trips. |
| `test/BoxLaunch.t.sol` | Rehearse CREATE2 factory deployment with exactly the four approved static addresses on an empty chain; expect no external calls to dependencies/recipients. Check domain, immutables, deployment/runtime size limits, all four zero-argument failures, nonpayability, safe failure on first use of an absent token, and absence of common administrative/withdrawal entrypoints. |

The new invariant campaign uses inline configuration: 256 runs, 128 calls per run, and `fail-on-revert = true`. Expected failures are explicitly matched, so an unexpected revert or failed assertion in the handler fails the campaign. Only action selectors are targeted; minting, model assertions, and the end-of-campaign drain are excluded. Inputs are bounded rather than discarded with assumptions. A directed handler test exercises rejection paths and both exit methods independently of random selection.

## Property discovery and implementation

The supplied Pashov and Trail of Bits references informed five review passes. These are original Foundry tests, not copied templates.

| Review pass | Grounded property and evidence | Implementation |
| --- | --- | --- |
| Conservation | Paid amounts must arrive at the three specified destinations; escrow exits must be fully accounted for (`src/Box.sol:102`, `:122`, `:148`). | Independent balances for every payer and recipient, total supply, open obligations, and separately tracked donations; no payment to the unrelated executor. |
| State transitions | An id cannot be reused; open orders close only once; payer, payment timestamp, and original escrow remain fixed (`src/Box.sol:98`, `:113`, `:120`, `:144`, `:146`). | Model orders are created from test inputs and updated from successful requested actions, never from Box getters. Every stored field is compared with that model after random calls. |
| Round trips and arithmetic | A full refund returns exactly the deposited escrow, with no dust/profit. A uint128 escrow must survive both exits, and deadline arithmetic must widen the uint64 timestamp (`src/Box.sol:96`, `:114`, `:145`). | Refund round trips, one wei, max uint128, max representable uint64 payment time, overflow failures, and large immediate legs. No shares, conversion rates, or division exist here. |
| Adversarial value extraction and liveness | Neither a hostile signer nor a permissionless executor can debit another order or select arbitrary recipients. Every remaining open escrow must be reclaimable after 60 days. | Arbitrary signed splits, two funded orders, independent recipient balances, replay/malformed/domain substitution failures, and `afterInvariant()` reclaiming every remaining open order. |
| Protocol-specific behavior | This is a keyed escrow, not a FIFO queue. Duplicate/closed batch entries pay at most once; other failures are atomic. An operator needs payer, id, commitment, all amounts, and attribution to match a quote (`src/Box.sol:46`, `:106`, `:130`). | Mixed/duplicate batches, rollback snapshots, and decoding actual Paid topics/data against arbitrary quote inputs. |

## Answers to the audit questions

| Question | Result and reproduction/evidence |
| --- | --- |
| Can someone move more than an order's escrow? | No reproduced path. Valid-signature underpayment/overpayment and uint256 wrapping are rejected, including when another order supplies enough token balance. Random executions compare each order's payout with its own original escrow. |
| Can someone choose another recipient? | No reproduced path. Arbitrary signed splits credit only Treasury, FLOAT, and the recorded payer. The unrelated executor's balance stays zero. Treasury/FLOAT also act as payers to exercise overlapping roles. |
| Can funds be stuck? | Every legitimately paid open escrow in the model exits after its deadline, even without a usable signer. **Direct transfers remain unassigned and unrecoverable**, as already documented and reproduced by the accepted `test_directTransferIsNotEscrowAndCannotLeave`. A sweep would violate this task's design. Transfer failures revert without consuming an order, so it can be retried. |
| Replay or malleability? | No reproduced replay across order keys, different verifying contracts, or different chain IDs, nor after settlement/reclaim. Duplicate batch keys pay once. Existing high-s/compact/bad-v tests plus new malformed-length, zero-recovery, independent-domain, and personal-sign tests reject unauthorized signatures. |
| Settle versus reclaim at 60 days? | Reclaim fails one second before the deadline and succeeds exactly at it. Settlement has no expiry: both calls are eligible at/after that boundary; the first successful call closes the order. This intentional race is already documented and tested in both transaction orders. |
| Can balance fall below open escrows? | No reproduced Box-only path with the specified plain token. The model asserts `balance == open escrow + direct donations` after every action and checks every payer/recipient balance. **The token vault's privileged burn is an external trust assumption**, already recorded in the README; the model does not grant Box immunity to token-side balance destruction, fees, or rebases. |
| uint128/uint64 packing? | Escrow above uint128 is rejected; values through max uint128 survive payments, settlements, and reclaims. Payment timestamps through max uint64 preserve all packed fields; deadline addition uses uint256, including a deadline beyond uint64. Immediate payment legs remain uint256. These are representable-payment-time tests, not a claim about casts of arbitrary EVM-cheated timestamps beyond uint64. |
| Is Paid missing something for the quoted-order matcher? | No missing specified field reproduced. The fuzz test decodes exactly one Box log and checks payer/key/id, commitment, each amount, and ref independently. Quotes must bind the payer and the operator must check the emitting Box/domain; two wallets can legitimately use the same orderId. Quote pricing, expiration policy, and body delivery are off-chain responsibilities. |
| Is SIGNER compromise bounded? | For existing open escrow, yes under the stated token assumptions: it permits arbitrary splits only among the three fixed recipients, within one order's escrow. It cannot reopen closed orders, consume unassigned donations, reclaim another payer's order, or use an administrative withdrawal path. Losing the signing key does not prevent eventual payer reclaim. |

No new implementation defect requiring a failing proof was reproduced. The known direct-transfer, token-vault, and immutable-key limitations are not treated as newly discovered defects or silently removed from the audit conclusion.

## Verification

Use the assignment seed for every command:

```sh
export FOUNDRY_FUZZ_SEED=0x9a66dd083e6d3158658c59c758f794ad7a65ff0cb08a9a42dafbcda1a98d830c
forge build
forge test --no-match-contract BoxForkTest
forge test
# With the caller-provided MAINNET_RPC_URL set:
forge test --match-contract BoxForkTest
```

The fork suite is inherited from the local suite and operates on live imdUSD with the real Treasury. Payer funding is test-only balance setup, and a test-controlled EOA signs test settlements. The separate launch test verifies the actual approved SIGNER/FLOAT constructor values without needing either real private key. Failure-injection tests temporarily mock only the selected failing token call and then retry on the actual token implementation.

Final observed checks with the supplied seed:

| Check | Result |
| --- | --- |
| `forge build` | Passed. Compiler/linter advisories are not suppressed in production code. |
| `forge test --no-match-contract BoxForkTest` | 64 passed, zero failed, zero skipped. |
| `forge test` without `MAINNET_RPC_URL` | 64 passed, zero failed; the fork suite's setup was the sole expected skip. |
| `forge test --match-contract BoxForkTest` with a reachable mainnet RPC supplied via `MAINNET_RPC_URL` | 57 passed against live imdUSD and the real Treasury, zero failed, zero skipped. |
| Original invariant campaign | 64 runs / 6,400 calls, zero unexpected reverts. |
| New independent-model invariant campaign | 256 runs / 32,768 calls, zero unexpected reverts, with final reclaim liveness checks. |
| `git diff --check` and changed-path review | Passed; every delivered change is under `test/`. |
