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

## Later (out of scope for v1)

- **Pocket money preset:** weekly tranches (unlock X every 7 days) instead of linear.
- ERC-20 streams (for example a testnet USDC).
- Open-ended streams with top-ups (salary without a fixed end).
- Batch payroll (create many streams from a CSV in one transaction).
- Transferable streams (NFT receipts) and changing the recipient.
- Reminders and notifications.
- A pitch for streamed grants from the Litecoin DAO / LitVM treasury.
- Mainnet (needs an external audit first).
