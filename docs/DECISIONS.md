# Decisions

Every judgment call is recorded here, newest at the bottom.

## M0: Market re-check (2026-10-01)

Method: Blockscout API (`/api/v2/search`, `/api/v2/smart-contracts?q=`, with a curl-like User-Agent), the testnet.litvm.com ecosystem directory, GitHub repository search.

| Check | Result |
| --- | --- |
| Verified contracts matching Sablier / Payroll | 0 |
| Verified contracts matching "Stream" | 0 |
| Verified contracts matching "Salary" | 1 (unnamed, `0xd61A…6B20`; likely the known `LitClinicSalaryVault`, not a streaming protocol) |
| Verified contracts matching "Vesting" | 3 (unnamed; token vesting, not native zkLTC streaming) |
| Tokens named "Stream"/"Flow"/"Drip" | Many; all look like meme/test ERC-20 tokens, none is a streaming protocol. A token named "Silver Stream" exists (`0x1c5C…26e0`). |
| testnet.litvm.com directory (~80 apps) | No streaming or payroll app. Payments: LitZap, LitVMPay, Lunaria. **New:** "Lester Labs" (token launch, locking, vesting, airdrops) is adjacent: ERC-20 vesting/locking, not per-second native zkLTC payment streams. |
| GitHub "litvm stream" | 0 repositories |

Conclusion: the niche is still empty in LitVM. The only adjacent product is Lester Labs' token vesting/locking.

Name conflict checks (chain token search + GitHub name search):

| Name | Chain | GitHub | Note |
| --- | --- | --- | --- |
| LitFlow | only "LitFlower" token | 27 small personal repos | no known company |
| Silverflow | none | 42 | Silverflow is an existing European payments company: rejected |
| Secondly | none | 58 | exists as a company (OpenPhone-related): rejected |
| Tickr | none | 620 | crowded: rejected |
| Rivulet | none | 258 | generic, no known crypto project (not checked beyond GitHub) |
| Paysecond | none | 1 | nearly free |

## M0: Product name (2026-10-01)

The user chose to keep **LitStreams**. No conflict found on LitVM (chain, directory, GitHub). The name is generic, which is accepted.

## M1: Tooling (2026-10-01)

- Git 2.52.0 (already installed). Foundry 1.8.3 installed via foundryup into `~/.foundry/bin` (not on PATH in new shells; use `export PATH="$PATH:/c/Users/batat/.foundry/bin"`). WSL is not needed: WSL1 is unsupported on this machine and Foundry runs natively in Git Bash.
- Libraries installed with `forge install`: forge-std (latest) and OpenZeppelin contracts v5.7.0. M2 must check that `ReentrancyGuard` from this version compiles under solc 0.8.24 / evm `paris`.
- `foundry.toml` pins solc 0.8.24, `evm_version = "paris"`, optimizer 200 runs, per brief §4.8.

## M2: Contract and tests (2026-10-01)

- **OpenZeppelin `ReentrancyGuard` (v5.7.0)** compiles under solc 0.8.24 / `paris`. It is marked "deprecated, replaced by the transient variant in v6", which is fine because the library is pinned at v5.7.0. The deployed bytecode was disassembled: no `PUSH0`, `TLOAD`, `TSTORE` or `MCOPY` in executable code (the only `PUSH0` byte is inside the CBOR metadata trailer).
- **Storage layout** kept exactly as suggested in brief §4.2 (4 slots). `refunded` cannot share slot 1 with `recipient` (20 + 16 bytes > 32), so there is no cheaper packing worth the complexity.
- **Value transfers** use an inline-assembly `call(gas(), to, amount, 0, 0, 0, 0)` that does not copy return data. This is still `call{value: x}("")` semantically, but a receiver cannot force the caller to pay for a huge returndata payload ("returnbomb"). The result is checked and reverts with `TransferFailed`.
- **Events are emitted before the external call** (effects first, then interaction).
- **`cancelable` is not cleared on cancel.** `canceled` is the authoritative flag; `refundableAmountOf` and `renounce` check it explicitly.
- **Check order** in `cancel`: `NotSender` → `AlreadyCanceled` → `NotCancelable` → `StreamEnded`. In `renounce`: `NotSender` → `AlreadyCanceled` → `NotCancelable`.
- **`renounce` after `endTime` is allowed.** The brief only requires "cancelable and not canceled". Renouncing an ended stream changes nothing practical (cancel is already impossible), so no extra error was added.
- **All per-id views revert with `StreamNotFound`** for unknown ids (the brief required it for `getStream`; applied to `statusOf`, `streamedAmountOf`, `withdrawableAmountOf`, `refundableAmountOf` for consistency, so the UI gets one clear error).
- **`statusOf` precedence:** `Depleted` (withdrawn + refunded == deposit) → `Canceled` → `Pending` (now < start) → `Settled` (now ≥ end) → `Streaming`. At exactly `startTime` the status is `Streaming` while the streamed amount is still 0.
- **Recipient validation** rejects only zero, the sender, and this contract, as specified. Other contracts and precompiles are accepted; documented in SECURITY.md.
- **Lint:** `forge lint`'s `block-timestamp` rule is disabled in `foundry.toml` (the product is time-based by design). The three `uint128`/`uint40` casts carry `forge-lint: disable-next-line(unsafe-typecast)` with a reason.
- **Tests:** 53 unit, 8 fuzz (1000 runs each, set in `foundry.toml`), 1 invariant suite with 6 invariants (256 runs × depth 64). Helper attack contracts live in `test/utils/Mocks.sol` (one extra file beyond the §3 tree). Invariants check `balance >= owed` (required) and also the stricter `balance == owed + force-sent` using a ghost counter.
- **Coverage:** 100% lines (98/98), statements (125/125), branches (31/31), functions (20/20) for `LitStreams.sol` (`forge coverage --no-match-coverage "(test|script)"`).
