#!/bin/bash
#
# update.sh
#
# Lives on the STEAM DECK. Downloads the latest Steam Deck installer from
# the Mac (which must be running ./share.sh) and runs it locally.
#
# One-time setup on the Deck (with share.sh running on the Mac):
#
#   curl -fO http://192.168.1.69:8000/update.sh && chmod +x update.sh
#
# After that, updating is just:
#
#   ./update.sh               # download latest installer and run it
#   ./update.sh --status      # flags are passed through to the installer
#   ./update.sh --force
#
set -u

# ---------------------------------------------------------------------------
# Configuration -- hard-coded to the Mac's (usually fixed) LAN address.
# If the Mac's IP changes, edit HOST below, or override per-run:
#   BALATRO_HOST=192.168.1.42 ./update.sh
# ---------------------------------------------------------------------------

HOST="${BALATRO_HOST:-192.168.1.69}"
PORT="${BALATRO_PORT:-8000}"
INSTALLER="install-balatro-mods-steamdeck.sh"
URL="http://$HOST:$PORT/$INSTALLER"

# ---------------------------------------------------------------------------
# Pretty output (mirrors the installer's style)
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''; C_GREEN=''; C_RED=''
fi

ok()   { printf '  %s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { printf '  %s[ERR]%s  %s\n' "$C_RED" "$C_RESET" "$*"; }
note() { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# ---------------------------------------------------------------------------
# Fetch the latest installer
# ---------------------------------------------------------------------------

TMP="$(mktemp /tmp/${INSTALLER}.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

echo
printf '%s\n' "${C_BOLD}Fetching latest installer from $URL${C_RESET}"

if ! curl -fsS --connect-timeout 5 -o "$TMP" "$URL"; then
  fail "Could not download the installer from $HOST."
  note "Is ./share.sh running on the Mac?"
  note "Is the Deck on the same Wi-Fi/network?"
  note "If the Mac's IP changed, edit HOST at the top of this script."
  exit 1
fi

ok "Downloaded $(wc -c <"$TMP" | tr -d ' ') bytes."

# ---------------------------------------------------------------------------
# Run it (any flags given to update.sh are passed straight through)
# ---------------------------------------------------------------------------

echo
bash "$TMP" "$@"
