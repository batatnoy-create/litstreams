# LitStreams specification

Per-second payment streaming of native zkLTC on LitVM (LiteForge testnet, chain id 4441).
Source of truth for behavior: [`contracts/LitStreams.sol`](../contracts/LitStreams.sol). Judgment calls: [DECISIONS.md](DECISIONS.md).

## Model

A sender locks `msg.value` zkLTC for one recipient, with a start time and a duration. The streamed amount
grows linearly from 0 at `startTime` to the full deposit at `endTime`. Anyone can trigger a withdrawal of
the accrued amount; funds always go to the recipient. A cancelable stream can be canceled by the sender
before it ends: the unstreamed part is refunded immediately and the streamed part stays withdrawable.
The sender can permanently give up the right to cancel (`renounce`).

One contract holds all streams. Ids start at 1 (0 never exists). No admin, fee, pause, proxy, or token.

## Constants

| Name | Value |
| --- | --- |
| `MIN_DURATION` | 60 s |
| `MAX_DURATION` | 3650 days |
| `MAX_START_DELAY` | 365 days |

## Math

```
streamedAmountOf(id):
  if canceled:          deposit - refunded            // frozen at cancel time
  if now <= startTime:  0
  if now >= endTime:    deposit
  else:                 deposit * (now - startTime) / (endTime - startTime)   // uint256, floor

withdrawableAmountOf(id) = streamedAmountOf(id) - withdrawn
refundableAmountOf(id)   = (cancelable && !canceled && now < endTime) ? deposit - streamedAmountOf(id) : 0
```

## Functions

| Function | Who | Notes |
| --- | --- | --- |
| `createStream(recipient, startTime, duration, cancelable)` payable | anyone | `startTime == 0` means now. Otherwise `now <= startTime <= now + MAX_START_DELAY`. Recipient not zero, not the caller, not the contract. `0 < msg.value <= type(uint128).max`. |
| `withdraw(id, amount)` | anyone | `0 < amount <= withdrawable`; pays the recipient. |
| `withdrawMax(id)` | anyone | Pays the full withdrawable amount to the recipient; reverts if 0. |
| `cancel(id)` | sender | Cancelable, not canceled, `now < endTime`. Refunds the unstreamed part to the sender only. |
| `renounce(id)` | sender | Cancelable and not canceled. One-way. |
| `getStream`, `statusOf`, `streamedAmountOf`, `withdrawableAmountOf`, `refundableAmountOf` | view | Revert `StreamNotFound` for unknown ids. |
| `sentCount`, `receivedCount`, `sentIds(addr, offset, limit)`, `receivedIds(addr, offset, limit)` | view | Append-only id lists, oldest first, paginated. |

Status: `Depleted` (withdrawn + refunded == deposit) → `Canceled` → `Pending` (now < start) →
`Settled` (now ≥ end) → `Streaming`, checked in that order.

Plain transfers and unknown calls revert with `DirectTransferNotAllowed`.

## Events

| Event | Fields (`indexed` marked) | Notes |
| --- | --- | --- |
| `StreamCreated` | `id`ⁱ, `sender`ⁱ, `recipient`ⁱ, `deposit`, `startTime`, `endTime`, `cancelable` | `startTime` is the resolved start (the block time when 0 was passed). |
| `Withdrawn` | `id`ⁱ, `recipient`ⁱ, `caller`, `amount` | `caller` is whoever sent the transaction; the funds went to `recipient`. |
| `Canceled` | `id`ⁱ, `sender`ⁱ, `recipient`ⁱ, `senderRefund`, `recipientStreamed` | `recipientStreamed` is the total streamed at cancel time, **including** anything already withdrawn. |
| `Renounced` | `id`ⁱ | |

## Errors

| Error | When |
| --- | --- |
| `ZeroRecipient`, `SelfStream`, `InvalidRecipient` | `createStream`: recipient is zero, the caller, or the contract. |
| `ZeroDeposit`, `DepositTooLarge` | `createStream`: `msg.value` is 0 or above `type(uint128).max`. |
| `StartInPast`, `StartTooFar` | `createStream`: non-zero `startTime` before now, or after now + `MAX_START_DELAY`. |
| `DurationOutOfRange` | `createStream`: duration outside `[MIN_DURATION, MAX_DURATION]`. |
| `StreamNotFound` | Any per-id function or view with an unknown id. |
| `NotSender` | `cancel` / `renounce` by anyone but the sender. |
| `AlreadyCanceled`, `NotCancelable`, `StreamEnded` | `cancel` (and `renounce`, except `StreamEnded`), checked in that order after `NotSender`. |
| `ZeroAmount`, `AmountExceedsWithdrawable` | `withdraw` with 0 or too much; `withdrawMax` with nothing to withdraw (`ZeroAmount`). |
| `TransferFailed` | The zkLTC transfer to the recipient (withdraw) or sender (cancel) failed. |
| `DirectTransferNotAllowed` | Plain transfer or unknown function call. |
| `ReentrancyGuardReentrantCall` (OpenZeppelin) | Re-entering `withdraw`, `withdrawMax` or `cancel` during a payout. |

## Edge semantics (for UIs and integrators)

- At exactly `startTime` the status is `Streaming` while the streamed amount is still 0.
- A canceled stream whose funds are all paid out reports `Depleted`, not `Canceled`. This includes a stream
  canceled before its start (full refund at once). Read `canceled` from `getStream` to label it "Canceled".
- `cancel` does not clear `cancelable`. The single reliable "can cancel now" signal is
  `refundableAmountOf(id) > 0` (exactly equivalent to `cancelable && !canceled && now < endTime`, because the
  refund is at least 1 wei).
- `renounce` is allowed after `endTime`; it changes nothing at that point.
- Spam: `deposit` alone says nothing about value. A stream created and canceled at once refunds everything.
  Measure a stream by `deposit − refunded` and hide canceled streams that streamed nothing (see SECURITY.md).
- Id lists can be inflated by anyone; read them in fixed-size pages.

## Later (out of scope for v1)

- **Pocket money preset:** weekly tranches (unlock X every 7 days) instead of linear.
- ERC-20 streams (for example a testnet USDC).
- Open-ended streams with top-ups (salary without a fixed end).
- Batch payroll (create many streams from a CSV in one transaction).
- Transferable streams (NFT receipts) and changing the recipient.
- Reminders and notifications.
- A pitch for streamed grants from the Litecoin DAO / LitVM treasury.
- Mainnet (needs an external audit first).
