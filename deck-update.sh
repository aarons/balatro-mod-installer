#!/bin/bash
#
# deck-update.sh
#
# Orchestrates a full update on the Steam Deck. Normally run via ./update.sh
# (the static bootstrap that downloads the latest repo snapshot and calls
# this), but it works from any checkout of the repo too.
#
#   1. Resolve the latest version of every mod (update-mods.sh) into a
#      TEMP copy of mods.csv — the committed mods.csv is never modified,
#      and any mod that fails to resolve keeps its committed version.
#   2. Run install-balatro-mods-steamdeck.sh against that resolved list.
#
# All flags are passed through to the installer:
#
#   ./deck-update.sh              # resolve latest + install/update everything
#   ./deck-update.sh --status     # resolve latest + report only
#   ./deck-update.sh --force
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''
fi
note() { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# ---------------------------------------------------------------------------
# 1. Resolve latest versions into a temp copy of mods.csv
# ---------------------------------------------------------------------------

RESOLVED_CSV="$(mktemp /tmp/balatro-mods.csv.XXXXXX)"
trap 'rm -f "$RESOLVED_CSV"' EXIT INT TERM

cp "$SCRIPT_DIR/mods.csv" "$RESOLVED_CSV"

if ! bash "$SCRIPT_DIR/update-mods.sh" --file "$RESOLVED_CSV"; then
  # update-mods.sh keeps the old row for anything it can't resolve, so a
  # partial failure still leaves a fully usable list — install what we have.
  echo
  note "some versions could not be resolved; using last-known versions for those."
fi

# ---------------------------------------------------------------------------
# 2. Install from the resolved list
# ---------------------------------------------------------------------------

echo
bash "$SCRIPT_DIR/install-balatro-mods-steamdeck.sh" --mods-file "$RESOLVED_CSV" "$@"
exit $?
