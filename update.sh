#!/bin/bash
#
# update.sh
#
# Lives on the STEAM DECK. This is a small STATIC bootstrap: it downloads the
# latest snapshot of the repo from GitHub (one tarball, no git needed), then
# hands off to deck-update.sh from that snapshot, which resolves the latest
# mod versions and runs the installer. All logic that evolves lives in the
# repo; this file should almost never need to change.
#
# One-time setup on the Deck (Desktop Mode, Konsole):
#
#   curl -fO https://raw.githubusercontent.com/aarons/balatro-mod-installer/main/update.sh
#   chmod +x update.sh
#
# After that, updating everything is just:
#
#   ./update.sh               # fetch latest code + mod list, resolve, install
#   ./update.sh --status      # flags are passed through to the installer
#   ./update.sh --force
#
set -u

REPO="${BALATRO_REPO:-aarons/balatro-mod-installer}"
BRANCH="${BALATRO_BRANCH:-main}"
TARBALL_URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"

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
# Fetch the latest repo snapshot
# ---------------------------------------------------------------------------

WORK_DIR="$(mktemp -d /tmp/balatro-mod-installer.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

echo
printf '%s\n' "${C_BOLD}Fetching latest $REPO ($BRANCH) from GitHub${C_RESET}"

if ! curl -fsSL --connect-timeout 10 "$TARBALL_URL" \
     | tar -xz -C "$WORK_DIR" --strip-components=1; then
  fail "Could not download $TARBALL_URL"
  note "Is the Deck online? Is github.com reachable?"
  exit 1
fi

if [ ! -f "$WORK_DIR/deck-update.sh" ]; then
  fail "deck-update.sh missing from the downloaded snapshot — repo layout changed?"
  exit 1
fi

ok "Got latest scripts and mod list."

# ---------------------------------------------------------------------------
# Hand off (any flags given to update.sh are passed straight through)
# ---------------------------------------------------------------------------

echo
bash "$WORK_DIR/deck-update.sh" "$@"
exit $?
