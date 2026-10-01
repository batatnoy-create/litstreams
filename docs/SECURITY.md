# Security (draft)

> **LitStreams is unaudited, experimental software that runs on the LitVM LiteForge testnet only.**
> Do not use it with anything of real value. There is no admin, so nobody can rescue funds,
> pause the contract, or fix a bug after deployment.

## Scope

One contract, [`contracts/LitStreams.sol`](../contracts/LitStreams.sol). It has no owner, admin, pause,
proxy, upgrade path, fee, or token. It holds native zkLTC only.

## What the contract guarantees

| Property | How it is enforced | Tested by |
| --- | --- | --- |
| Withdrawn funds always go to the stream's recipient, whoever calls `withdraw` / `withdrawMax`. | The payout address is read from storage, never from the caller. | Unit + fuzz (`testFuzz_WithdrawByAnyone`) |
| The recipient can never take more than has streamed. | `amount <= streamed - withdrawn`; `withdrawn` is updated before the transfer. | Unit, fuzz, invariant `PerStreamBounds` |
| A cancel splits the deposit exactly: `refund + streamed == deposit`. | `refund = deposit - streamed`, both computed at the same timestamp. | Unit, fuzz `testFuzz_Cancel` |
| The streamed part of a canceled stream stays claimable by the recipient. | Pull pattern: cancel only pays the sender; the recipient withdraws later. | Unit `test_Cancel_MidStream` |
| A recipient that rejects zkLTC cannot block the sender's cancel. | Cancel never sends to the recipient. | Unit `test_RejectingRecipient_CannotBlockCancel` |
| The contract is always solvent. | Every payout reduces what is owed by the same amount. | Invariants `Solvency`, `ExactBalance` |
| The streamed amount never decreases over time. | Linear formula on a monotonic clock; frozen at cancel. | Invariant `StreamedMonotonic`, fuzz `testFuzz_StreamedMath` |
| No reentrancy. | Checks-effects-interactions plus OpenZeppelin `ReentrancyGuard` (storage-based, not transient) on `withdraw`, `withdrawMax`, `cancel`. | Unit reentrancy tests with malicious sender and recipient contracts |
| Plain transfers to the contract are rejected. | `receive` and `fallback` revert. | Unit `test_RevertWhen_DirectTransfer` |

Other design notes:

- Native zkLTC is sent with a low-level `call` that does not copy return data, and the result is checked.
  `transfer` / `send` are never used.
- Math: `deposit * elapsed / duration`, computed in `uint256` (a `uint128 × uint40` product cannot overflow),
  rounded down. Rounding favors the sender until `endTime`; at `endTime` the recipient is owed exactly `deposit`.
- Only `block.timestamp` is used. `block.number`, `blockhash`, and `prevrandao` are not used
  (on LitVM they are approximate or not random).
- Views that list streams are paginated, so no function loops over an unbounded array.
- Compiled with solc 0.8.24, `evm_version = paris`. The deployed bytecode contains no post-Paris opcodes
  (no `PUSH0`, `TLOAD`, `TSTORE`, `MCOPY`).

## Known limitations

1. **The recipient cannot be changed** in v1. Streams are not transferable.
2. **If the recipient loses their key, streamed funds are stuck forever.** The sender can only reclaim the
   *unstreamed* part, and only if the stream is still cancelable and has not ended.
3. **A recipient that cannot receive zkLTC** (for example a contract without a payable `receive`) can never be
   paid. Its streamed part stays locked in the contract. The sender can still cancel to recover the unstreamed part.
4. **A sender that cannot receive zkLTC** (a contract that rejects refunds) cannot cancel its own streams,
   because the refund transfer fails and the whole cancel reverts. This only affects that sender.
5. **Timestamps come from the sequencer.** LitVM is an Arbitrum Orbit chain; `block.timestamp` is set by the
   sequencer's clock within the bounds the Nitro stack enforces, and is monotonic. A misbehaving sequencer could
   shift time somewhat, which changes how much has streamed at a given moment. It cannot make the streamed
   amount exceed the deposit or decrease.
6. **The AnyTrust data layer and the bridge add trust assumptions.** LitVM uses AnyTrust for data availability,
   which relies on a data availability committee. Bridged and withdrawn funds rely on the rollup's bridge.
7. **Force-sent zkLTC is stuck.** Plain transfers revert, but zkLTC can still be forced in (for example via
   `selfdestruct` from another contract or bridge/retryable credits). Such funds belong to no stream and nobody
   can withdraw them. Because of this, the contract's balance can be greater than what it owes, never smaller.
8. **Spam / dust streams.** Anyone can create tiny streams to any address. The contract allows it; the web UI
   hides streams below 0.0001 zkLTC by default.
9. **Anyone can trigger a payout.** A third party can push the recipient's streamed funds to them at any time.
   The funds can only go to the recipient, but the recipient does not control *when* they are paid.
10. **Cancelable means cancelable.** A sender can cancel a cancelable stream at any moment before it ends,
    including one second before the end. Recipients who need certainty should ask for a non-cancelable stream,
    or for the sender to `renounce`.
11. **Arbitrary recipient addresses are accepted.** The contract only rejects the zero address, the sender, and
    itself. Sending a stream to a wrong address, a precompile, or a contract that cannot handle zkLTC is not
    detected on chain.
12. **No admin, no recovery.** Nobody can rescue stuck funds, reverse a mistaken stream, or pause the contract.
13. **Unaudited, testnet only.** The contract has had an internal review only (see `DECISIONS.md`, M3).
    It must have an external audit before any mainnet use.

## Reporting a problem

Open an issue in the GitHub repository. Do not include private keys or seed phrases in any report.
