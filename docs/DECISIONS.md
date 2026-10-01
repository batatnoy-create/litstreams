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

## M3: Review findings (2026-10-01)

An independent sub-agent reviewed the brief (§1, §2, §4, §5), the contract, the tests and the docs. It ran
mutation experiments in a scratch copy. Result: **no Critical, High or Medium findings**. It confirmed:
- the §4.3 math (exact, floor rounding, safe casts);
- the boundaries and the five-state status logic;
- checks-effects-interactions on every payout path;
- the memory-safe assembly `call`;
- the events and errors match §4.5/§4.6;
- pagination;
- `paris` bytecode: no PUSH0, TLOAD, TSTORE or MCOPY, and no use of NUMBER, BLOCKHASH or PREVRANDAO.

It also found that the intentional M2 deviations are sound.

| # | Sev. | Finding | Decision |
| --- | --- | --- | --- |
| A1 | Low | Anyone can add fake entries to any address's `receivedIds` for gas only. A contract can create a cancelable stream and cancel it in the same transaction, getting the whole deposit back. The entry then shows any size, e.g. "1000 zkLTC". A dust filter on `deposit` doesn't stop it. | **No contract change.** On-chain mitigations either break the spec or cost the attacker nothing: the spec requires a full refund before start, a minimum deposit is refunded anyway, and a "no cancel in the creation block" rule is bypassed by waiting one block. §4.7 already says "the contract allows it; the UI filters it". **M5 requirement:** the UI measures streams by `deposit − refunded`, hides canceled streams that streamed nothing, and applies the 0.0001 zkLTC dust filter to that amount. SECURITY.md item 8 and SPEC.md "Edge semantics" are updated. |
| A2 | Info | `statusOf` reports `Depleted` for a canceled stream once everything is paid out, including a stream canceled before its start. `cancelable` stays `true` after cancel. | **Keep:** this matches the §4.4 status definition and DECISIONS M2. Documented in SPEC.md "Edge semantics" and in the NatSpec of `getStream`, `statusOf` and `refundableAmountOf`. Two new tests pin the behaviour: `testFuzz_RefundableIffCancelSucceeds` (`refundableAmountOf > 0` exactly when cancel succeeds), and `test_Cancel_MidStream`, which asserts that `cancelable` stays true. **M5 requirement:** use `refundableAmountOf > 0` for the Cancel button, and `canceled` for the "Canceled" label. |
| A3 | Info | Payouts forward all gas to the recipient. Because the guard is global, a recipient whose `receive` calls back into a guarded function can never be paid. | **Keep.** A gas cap would break smart-contract wallets (e.g. Safe) as recipients. The extra gas costs only the caller who chose to pay out, and wallets show it in the gas estimate. Documented in SECURITY.md item 3. |
| A4 | Info | NatSpec was incomplete: views lacked `@param`/`@return`, which §4.7 requires. | **Fixed:** every external/public function now has full NatSpec. Logic is unchanged. Only the metadata hash in the bytecode changes. |
| B1 | Low | The reentrancy tests mostly passed because of CEI, not because of the guard. The mocks treated any revert as "blocked". Mutants that removed a guard, or moved a state update after the transfer, survived. | **Fixed.** A new `ReentrantActor` mock (`test/utils/Mocks.sol`) records the exact revert selector of its re-entry and snapshots the stream from inside the payout. Rewritten and new tests: <br>• all withdraw/withdrawMax/cancel pairs must hit `ReentrancyGuardReentrantCall`, including on a second stream where the inner call would otherwise succeed; <br>• the state is already final when the counterparty is paid (CEI); <br>• re-entering the unguarded `createStream`/`renounce` is safe. <br>The vacuous `RecipientCannotCancelDuringPayout` test was removed. |
| B2 | Low | The invariant suite ran with `fail_on_revert = false`. Many handler calls were no-ops, and mid-stream cancels were rare. Refunds were never checked against what the senders actually received. | **Fixed.** Changes to the suite: <br>• `fail_on_revert = true` (every handler filters its own preconditions), with explicit target selectors; <br>• withdraw, withdrawMax and cancel pick a stream where the action has an effect; <br>• cancel can first warp to a random point before the stream ends; <br>• new invariant `RefundsReachSenders`: refunds are measured at the senders and recomputed from the formula, independently of the contract; <br>• new invariant `StreamedMatchesFormula`. |
| B3 | Info | The `Canceled` event after a partial withdraw was not pinned, `renounce` after the end was untested, and one assertion was a tautology. | **Fixed:** added an `expectEmit` in `test_Cancel_AfterPartialWithdraw`, where `recipientStreamed` is the total streamed including the amount already withdrawn. Added `test_Renounce_AfterEndIsAllowed`, and replaced the tautology with the exact value. |
| C1 | Low | SECURITY.md presented the dust filter as spam protection. | **Fixed** (item 8, see A1). |
| C2 | Low | SECURITY.md overclaimed the reentrancy test coverage. | **Fixed:** the row now describes the new tests and the mutation check (B1). |
| C3 | Info | "No function loops over an unbounded array" was imprecise: `_slice` loops up to the caller's `limit`, and anyone can inflate a list. | **Fixed:** reworded in SECURITY.md, with `@dev` notes on `sentIds`/`receivedIds`. **M5 requirement:** read the id lists in fixed-size pages. |
| C4 | Info | Timestamps are non-decreasing, not strictly monotonic. The bounds weren't quantified, and sequencer ordering/censorship was missing. | **Fixed** in SECURITY.md item 5. The Nitro defaults are given (about 24 h behind / 1 h ahead, and forced inclusion after about 24 h); LitVM's actual config is marked as unverified. |
| C5 | Info | SPEC.md lacked events, errors and edge semantics. | **Fixed:** added the "Events", "Errors" and "Edge semantics" sections. |
| — | Info | (Own finding) `forge lint` flagged `block.timestamp` read across `vm.warp` in tests. | **Fixed:** the tests use `vm.getBlockTimestamp()`. `forge lint` is now clean. |

**Mutation check after the fixes.** Ten hand-made mutants of `LitStreams.sol` were tested in a scratch copy, and each one made at least one test fail (10/10 killed):
- no guard on `withdraw`, on `withdrawMax`, or on `cancel`;
- `withdrawn` updated after the transfer;
- cancel state updated after the transfer;
- the `Canceled` event reporting the amount net of withdrawals;
- `renounce` forbidden after the end;
- `withdraw` reverting for odd amounts;
- `cancel` reverting mid-stream;
- the refund sent one wei short.

The last three are caught by the invariant suite alone. Before M3, the first five and the `Canceled` event mutant survived.

**After M3:** `forge test` passes 68/68: 58 unit, 9 fuzz, and 1 invariant suite with 8 invariants at 256 × 64 with `fail_on_revert`. `forge lint` is clean. Coverage of `LitStreams.sol` is still 100% (lines 98/98, statements 125/125, branches 31/31, functions 20/20).

Git: the first commit (`d9c03d2`, a baseline before M3) was made with the user's approval. Git had no `user.name`
configured, so the commit author name is "LitStreams dev". It can be changed before pushing to GitHub.

## M4: Testnet deployment

| Decision | Choice and why |
| --- | --- |
| Deployer | The fresh "sender" test wallet, via `forge script`. The user's main wallet key stays out of `.env` (it controls real assets on other chains; a plaintext key on disk is a risk with no on-chain benefit, since the contract has no owner). The user may link the deployer address to their identity in the listing. |
| Remix attempt | Deploying from the main wallet through Remix + MetaMask failed before broadcast ("Interaction failed", no tx id, no funds spent). Not pursued further. |
| Second wallet funding | The faucet refused a second wallet (about 0.06 zkLTC per day). The recipient got 0.004 zkLTC from the sender instead (tx `0x33cf39f3f3a6eba265643768d7626a6a795d47070abe9b2c6870e39955317e4d`). |
| Stream amounts | 0.005 zkLTC per stream instead of the brief's 0.01-0.05, because the faucet gives little. |
| Lifecycle runner | `script/run-lifecycle.sh` uses `cast send`, not `forge script`. LitVM only produces blocks when there are transactions, so `forge script` simulates against a stale `block.timestamp` and would revert timed calls. The user gave one explicit approval for the whole A/B/C list with exact amounts. |
| Stream C | Created with a start time 10 minutes ahead and canceled right away (before start): full refund, status `Depleted` (`refunded == deposit`), as in SPEC "Edge semantics". |
| Verification | `forge verify-contract --verifier blockscout`: fully verified (solc 0.8.24, paris, 200 runs). The first attempt failed with "not a smart contract" because the explorer indexer was ~8,600 blocks behind; the retry worked once it had indexed the block. |
| Code check | `keccak256(eth_getCode)` matched `keccak256(forge inspect deployedBytecode)` before verification. |

## M5: Frontend

| Decision | Choice and why |
| --- | --- |
| ethers vendor | `ethers@6.17.0` UMD build (`dist/ethers.umd.min.js` from the official npm tarball), saved as `web/vendor/ethers-6.17.0.umd.min.js`. Tarball integrity matched the npm registry value (`sha512-BpyrpIPJ3ydEVow8zGaz1DuPS7YU8DcWxuBnY9a0UA/lvAPwrMr+EPXsfrul628SRaekPNeIM4UFh/91GWZang==`). SHA-256 of the vendored file: `532950515fd29ae9f7a21ceb2b68100815024d7944c3d5a92246d5b900bd703b`. Loaded from our own origin, never from a CDN. (The M4 handoff said it was already vendored; it was not, so it was added at the start of M5.) |
| Time source in the UI | Amounts, status and counters are computed in the browser (BigInt, same formulas as the contract) from `getStream` plus the browser clock, so each card costs one RPC call instead of five. The chain remains the source of truth: every transaction re-checks on chain, and after each transaction the lists are re-read. Lists re-sync every 15 s. |
| "Start now" | Sends `startTime = 0`, so the chain's own clock decides (no browser/chain skew). The plain-English summary shows the browser time as an approximation. |
| Scheduled start | Must be at least 5 minutes ahead (otherwise the UI shows a message and asks the user to choose "Start now"), and at most 364 days ahead (the contract allows 365; the extra day absorbs clock skew). |
| Cancelable default | ON in the Create form, with a one-line explanation and a summary that says CAN / CANNOT. |
| Outgoing list | Newest first, read in pages of 25 from `sentIds`. Cancel and Renounce buttons show only when `refundableAmountOf > 0` (computed locally as `cancelable && !canceled && now < end`); "Pay out now" shows when something is withdrawable. Cancel, Renounce and Pay out ask for a native `confirm()` first, then the wallet. Label "Canceled" comes from `getStream().canceled`. "Hide dust" (default ON) measures `deposit - refunded < 0.0001 zkLTC`. |
| Network switching | `wallet_switchEthereumChain`, falling back to `wallet_addEthereumChain` with the values from §2. The wallet provider is created with network `"any"` so a chain switch does not break ethers. Nothing is stored in localStorage. |
| Local preview | `.claude/launch.json` at the workspace root serves `litstreams/web` on port 8765 with `python -m http.server`. It is outside the git repo. |
| Design system | Dark "digital silver" theme in plain CSS (no framework, no external fonts, no images): system font stack with tabular numbers for all amounts, glass cards with hairline borders, silver gradient primary buttons, ice-blue accent for focus and progress, sticky blurred header, bottom tab bar on screens up to 860 px, skeleton loaders, soft entrance animations, `prefers-reduced-motion` respected. The header blur is on a pseudo-element because `backdrop-filter` on the header itself would trap the fixed mobile nav. |
| Confirmations | Cancel and Renounce use an in-page `<dialog>` (with the exact amount and "cannot be undone") instead of the native `confirm()`. Withdraw and Pay out go straight to the wallet (they are not destructive and the money always goes to the recipient). |
| Live counters | One shared `requestAnimationFrame` loop per view; amounts are computed locally at millisecond resolution from `getStream` (display only, the chain stays authoritative); digits past the 4th decimal are dimmed; every 15 s the data is re-read from the chain, and again after every transaction. Counters do not poll the RPC per frame. |
| Incoming list | `receivedIds` in pages of 25 (newest first), dust measured on `deposit - refunded`, plus a live "Available to withdraw now" total over the visible streams. |
| Stream page | `#/stream/<id>` works with no wallet (public RPC only). It shows two live counters, all parameters, explorer links, and a best-effort "Created in" link found from the `StreamCreated` event (from the deploy block). If a wallet is connected, the same Withdraw / Pay out / Cancel / Renounce buttons appear, based on who the connected account is. Not-found ids show a friendly page. |
| Logo | `web/assets/logo.svg` and `favicon.svg`: three flowing bars on a dark rounded square, silver gradient with an ice-blue dot. Original artwork. PNG exports and banners come in M7. |
