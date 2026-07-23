#!/bin/bash
#
# share.sh
#
# ONE-TIME bootstrap transfer: serve this repo over the LAN so a Steam Deck
# can curl update.sh (the static updater). After that first transfer the Deck
# never needs this again -- update.sh fetches everything from GitHub.
# Run it on your Mac (in the repo dir), then follow the printed instructions
# on the Deck. The HTTP server runs in the FOREGROUND -- press Ctrl-C (or
# kill this script) and the server stops with it. Nothing is left running.
#
#   ./share.sh            # serve on port 8000
#   ./share.sh 9000       # serve on a custom port
#
# Requirements: macOS, python3 (stock on macOS).
#
set -u

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT="${1:-8000}"
UPDATER="update.sh"

# Serve from the directory this script lives in (the repo), regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "could not cd to $SCRIPT_DIR"; exit 1; }

# ---------------------------------------------------------------------------
# Pretty output (mirrors the installer's style)
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_RED=$'\033[31m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RED=''
fi

hr()    { printf '%s\n' "${C_DIM}--------------------------------------------------------------${C_RESET}"; }
title() { printf '%s\n' "${C_BOLD}$*${C_RESET}"; }
note()  { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
fail()  { printf '  %s[ERR]%s  %s\n' "$C_RED" "$C_RESET" "$*"; }

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

command -v python3 >/dev/null 2>&1 || {
  fail "python3 not found -- install it (e.g. 'brew install python3')."
  exit 1
}

[ -f "$UPDATER" ] || {
  fail "$UPDATER not found in $SCRIPT_DIR -- run this from the repo."
  exit 1
}

# ---------------------------------------------------------------------------
# Discover this machine's LAN IP address
# ---------------------------------------------------------------------------

get_ip() {
  local ip iface
  # Prefer the interface backing the default route (handles Wi-Fi vs Ethernet).
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  [ -n "$iface" ] && ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
  # Fallbacks: common interface names.
  [ -z "${ip:-}" ] && ip="$(ipconfig getifaddr en0 2>/dev/null)"
  [ -z "${ip:-}" ] && ip="$(ipconfig getifaddr en1 2>/dev/null)"
  printf '%s' "${ip:-}"
}

IP="$(get_ip)"
[ -n "$IP" ] || {
  fail "Could not determine a LAN IP address. Are you connected to a network?"
  exit 1
}

# ---------------------------------------------------------------------------
# Print the Steam Deck instructions
# ---------------------------------------------------------------------------

BASE="http://$IP:$PORT"

echo
hr
title "Sharing this repo at ${C_GREEN}http://$IP:$PORT/${C_RESET}"
hr
echo
title "On the Steam Deck:"
note "(Deck must be on the same Wi-Fi/network as this Mac.)"
echo
printf '  %s1.%s Switch to Desktop Mode, then open %sKonsole%s.\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
echo
printf '  %s2.%s Download the updater and run it:\n' "$C_BOLD" "$C_RESET"
echo
printf '       %scurl -fO %s/%s && chmod +x %s && ./%s%s\n' \
  "$C_GREEN" "$BASE" "$UPDATER" "$UPDATER" "$UPDATER" "$C_RESET"
echo
note "(update.sh fetches everything else -- scripts and mod list -- from"
note "GitHub, so this transfer is only needed ONCE. From then on, updating"
note "is just ./update.sh on the Deck; this server need not be running.)"
note "Flags pass through to the installer, e.g.:"
note "  ./$UPDATER --status      # report only, change nothing"
note "  ./$UPDATER --force       # reinstall everything"
echo
hr
title "Server running -- press ${C_BOLD}Ctrl-C${C_RESET} to stop sharing."
hr
echo

# ---------------------------------------------------------------------------
# Start the file server in the FOREGROUND.
# exec replaces this shell with python3, so killing the script (Ctrl-C / SIGTERM)
# stops the server immediately -- it is never a lingering background job.
# Binds to 0.0.0.0 by default so the Deck can reach it over the LAN.
# ---------------------------------------------------------------------------

exec python3 -m http.server "$PORT"
