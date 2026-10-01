#!/usr/bin/env bash
# Renders the PNG assets with headless Chrome (a throwaway profile, nothing else is touched).
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/c/Program Files/Google/Chrome/Application/chrome.exe}"
PROFILE="$(mktemp -d)"
SRC="file:///$(pwd -W 2>/dev/null || pwd)"
OUT="$(cd ../web/assets && (pwd -W 2>/dev/null || pwd))"
shot() { # url width height out [transparent]
  local bg=()
  [ "${5:-}" = "t" ] && bg=(--default-background-color=00000000)
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --user-data-dir="$PROFILE" "${bg[@]}" --window-size="$2,$3" --screenshot="$4" "$1" >/dev/null 2>&1
}
shot "$SRC/logo.html" 512 512 "$OUT/logo-512.png" t
shot "$SRC/card.html?v=og" 1200 630 "$OUT/og-image.png"
shot "$SRC/card.html?v=banner" 1500 500 "$OUT/x-banner-1500x500.png"
rm -rf "$PROFILE"
