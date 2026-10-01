#!/usr/bin/env bash
# Runs the on-chain lifecycle from brief §6.4 (streams A, B, C) with cast, honoring the on-chain timers.
# Keys are read from .env and never printed. Output goes to docs/lifecycle-run.log.
set -uo pipefail
export PATH="$PATH:/c/Users/batat/.foundry/bin"
cd "$(dirname "$0")/.."
set -a; source <(tr -d '\r' < .env); set +a

C=0xB3146ab6401d69DC7EFCa457a637760d192D1fFD
LOG=docs/lifecycle-run.log
S_ADDR=$(cast wallet address --private-key "$PRIVATE_KEY")
R_ADDR=$(cast wallet address --private-key "$RECIPIENT_PRIVATE_KEY")
: > "$LOG"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# send <label> <pk> <fn-sig> [args...] ; extra flags via SEND_FLAGS
send() {
  local label=$1 pk=$2; shift 2
  local out
  out=$(cast send "$C" "$@" --private-key "$pk" --rpc-url "$RPC_URL" $SEND_FLAGS 2>&1) || { log "FAILED $label: $out"; exit 1; }
  local hash status block
  hash=$(echo "$out" | awk '$1=="transactionHash"{print $2}')
  status=$(echo "$out" | awk '$1=="status"{print $2}')
  block=$(echo "$out" | awk '$1=="blockNumber"{print $2}')
  log "$label | tx $hash | block $block | status $status"
  [ "$status" = "1" ] || { log "NON-SUCCESS $label"; exit 1; }
  LAST_BLOCK=$block
}
status() { cast call "$C" "statusOf(uint256)(uint8)" "$1" --rpc-url "$RPC_URL"; }
sleep_until() { local t=$1; local now; now=$(date +%s); [ "$t" -gt "$now" ] && sleep $((t - now)); return 0; }

log "Contract $C | sender $S_ADDR | recipient $R_ADDR"
log "recipient balance before: $(cast balance "$R_ADDR" --rpc-url "$RPC_URL" --ether)"

# ---- Create A (10 min, cancelable, starts now) ----
SEND_FLAGS="--value 0.005ether" send "A create" "$PRIVATE_KEY" "createStream(address,uint40,uint40,bool)" "$R_ADDR" 0 600 true
TA=$(date +%s); BA=$LAST_BLOCK
# ---- Create B (5 min, cancelable) and renounce ----
SEND_FLAGS="--value 0.005ether" send "B create" "$PRIVATE_KEY" "createStream(address,uint40,uint40,bool)" "$R_ADDR" 0 300 true
TB=$(date +%s)
SEND_FLAGS="" send "B renounce" "$PRIVATE_KEY" "renounce(uint256)" 2
# ---- Create C (starts in ~10 min, 10 min long, cancelable) ----
CSTART=$(( $(date +%s) + 600 ))
SEND_FLAGS="--value 0.005ether" send "C create (start $CSTART)" "$PRIVATE_KEY" "createStream(address,uint40,uint40,bool)" "$R_ADDR" "$CSTART" 600 true
log "C status before cancel (0=Pending): $(status 3)"
SEND_FLAGS="" send "C cancel (before start)" "$PRIVATE_KEY" "cancel(uint256)" 3
log "C getStream refunded/status after cancel: status=$(status 3)"

# ---- A: recipient withdrawMax at ~3 min ----
sleep_until $((TA + 185))
log "A status (1=Streaming): $(status 1) | withdrawable: $(cast call "$C" 'withdrawableAmountOf(uint256)(uint128)' 1 --rpc-url "$RPC_URL")"
SEND_FLAGS="" send "A withdrawMax by recipient" "$RECIPIENT_PRIVATE_KEY" "withdrawMax(uint256)" 1
# ---- A: sender cancel at ~5 min ----
sleep_until $((TA + 305))
log "A refundable before cancel: $(cast call "$C" 'refundableAmountOf(uint256)(uint128)' 1 --rpc-url "$RPC_URL")"
SEND_FLAGS="" send "A cancel by sender" "$PRIVATE_KEY" "cancel(uint256)" 1
log "A status after cancel (3=Canceled): $(status 1)"
SEND_FLAGS="" send "A withdrawMax rest by recipient" "$RECIPIENT_PRIVATE_KEY" "withdrawMax(uint256)" 1
log "A status final (4=Depleted): $(status 1)"

# ---- B: after end, the SENDER calls withdrawMax; funds must land at the recipient ----
sleep_until $((TB + 310))
REC_BEFORE=$(cast balance "$R_ADDR" --rpc-url "$RPC_URL")
SEND_FLAGS="" send "B withdrawMax by SENDER" "$PRIVATE_KEY" "withdrawMax(uint256)" 2
REC_AFTER=$(cast balance "$R_ADDR" --rpc-url "$RPC_URL")
log "B recipient balance delta (wei): $(( REC_AFTER - REC_BEFORE )) (expected 5000000000000000)"
log "B status final (4=Depleted): $(status 2)"
log "sender balance: $(cast balance "$S_ADDR" --rpc-url "$RPC_URL" --ether) | recipient balance: $(cast balance "$R_ADDR" --rpc-url "$RPC_URL" --ether)"
log "DONE"
