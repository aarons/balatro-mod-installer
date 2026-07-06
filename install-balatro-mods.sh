#!/bin/bash
#
# install-balatro-mods.sh
#
# One-shot installer / updater for a curated set of Balatro mods on macOS.
# Re-running it is safe: it checks the installed version of each component
# against the latest available and only downloads what is missing or stale.
#
#   ./install-balatro-mods.sh            # check + install/update everything
#   ./install-balatro-mods.sh --status   # report only, change nothing
#   ./install-balatro-mods.sh --force    # reinstall everything from scratch
#   ./install-balatro-mods.sh --help
#
# Requirements: macOS, curl, tar (all stock). No jq/python needed.
# Optional: set GITHUB_TOKEN to raise the GitHub API rate limit (60 -> 5000/hr).
#
# Version policy: most mods are installed from the HEAD of their default branch
# (the genuinely latest code). Most of these repos either have no installable
# release asset or tag releases well behind their default branch, so tracking
# the latest commit is the most reliable "latest version".
# Exceptions, both installed from their latest GitHub release:
#   - Lovely: ships a compiled binary only via Releases.
#   - Steamodded: its `main` is a development branch; the team recommends the
#     latest release for content-mod compatibility (see MODS_TABLE below).
#
set -u

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Balatro"
DEFAULT_MODS_DIR="$HOME/Library/Application Support/Balatro/Mods"

GAME_DIR="${BALATRO_GAME_DIR:-$DEFAULT_GAME_DIR}"
MODS_DIR="${BALATRO_MODS_DIR:-$DEFAULT_MODS_DIR}"

LOVELY_REPO="ethangreen-dev/lovely-injector"

# Source-installed mods. One record per line:  key|owner/repo|target-folder|ref
# The ref is either a branch name (install the latest commit of that branch) or
# the literal "@release" (install the source of the latest GitHub release).
# Order: framework + common dependencies first, then content mods. (Load order
# on disk does not actually matter to Steamodded, but it reads nicely.)
#
# Steamodded is pinned to @release: its `main` branch carries an in-progress
# blind/scoring refactor that content mods haven't adopted yet, and the
# Steamodded team recommends running the latest release for mod compatibility.
MODS_TABLE='
smods|Steamodded/smods|smods|@release
Amulet|frostice482/amulet|Amulet|main
JokerDisplay|nh6574/JokerDisplay|JokerDisplay|main
Cartomancer|stupxd/Cartomancer|Cartomancer|main
Handy|SleepyG11/HandyBalatro|HandyBalatro|main
Cryptid|SpectralPack/Cryptid|Cryptid|main
unik|70UNIK/UNIKs-mod|UNIKs-mod|main
Bunco|jumbocarrot0/Bunco|Bunco|main
AllInJest|survovoaneend/All-In-Jest|All-In-Jest|main
BetterStakes|kjossul/BetterStakes|BetterStakes|main
NeowBlessings|aarons/Balatro-NeowBlessings|NeowBlessings|main
typist|kasimeka/balatro-typist-mod|balatro-typist-mod|main
'

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

MODE="install"   # install | status
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --status|--check) MODE="status" ;;
    --force) FORCE=1 ;;
    --game-dir) shift; GAME_DIR="${1:-}" ;;
    --mods-dir) shift; MODS_DIR="${1:-}" ;;
    -h|--help)
      grep '^#' "$0" | sed -e 's/^#!.*//' -e 's/^# \{0,1\}//' | sed '/^$/q'
      exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_RED=$'\033[31m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RED=''
fi

hr()    { printf '%s\n' "${C_DIM}--------------------------------------------------------------${C_RESET}"; }
title() { printf '%s\n' "${C_BOLD}$*${C_RESET}"; }
ok()    { printf '  %s[ok]%s   %s\n'    "$C_GREEN"  "$C_RESET" "$*"; }
upd()   { printf '  %s[up]%s   %s\n'    "$C_BLUE"   "$C_RESET" "$*"; }
add()   { printf '  %s[new]%s  %s\n'    "$C_YELLOW" "$C_RESET" "$*"; }
skip()  { printf '  %s[--]%s   %s\n'    "$C_DIM"    "$C_RESET" "$*"; }
fail()  { printf '  %s[ERR]%s  %s\n'    "$C_RED"    "$C_RESET" "$*"; }
note()  { printf '         %s%s%s\n'    "$C_DIM"    "$*" "$C_RESET"; }

# Counters
N_OK=0; N_NEW=0; N_UPD=0; N_FAIL=0
FAILED_LIST=""

# ---------------------------------------------------------------------------
# Workspace + cleanup
# ---------------------------------------------------------------------------

WORK_DIR=""
cleanup() { [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# HTTP helpers (curl only)
# ---------------------------------------------------------------------------

# api_get URL  -> prints body to stdout, non-zero on HTTP/transport error
api_get() {
  local url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  fi
}

# download URL DEST
download() { curl -fsSL "$1" -o "$2"; }

# Resolve the latest commit SHA of a branch. Prefers `git ls-remote` (git
# smart-HTTP, which is NOT subject to the REST API's 60/hr anonymous limit);
# falls back to the REST API if git is unavailable.
#   resolve_sha owner/repo branch  -> sha on stdout (empty on failure)
resolve_sha() {
  local repo="$1" branch="$2" sha=""
  if [ "${USE_GIT:-0}" = 1 ]; then
    sha="$(git ls-remote "https://github.com/$repo.git" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  if [ -z "$sha" ]; then
    sha="$(api_get "https://api.github.com/repos/$repo/commits/$branch" 2>/dev/null | extract_sha)"
  fi
  printf '%s' "$sha"
}

# Resolve a repo's latest release tag. Prefers the github.com
# /releases/latest redirect (not rate-limited); falls back to the REST API.
#   resolve_release_tag owner/repo  -> tag on stdout (empty on failure)
resolve_release_tag() {
  local repo="$1" tag="" loc
  loc="$(curl -sI -o /dev/null -w '%{redirect_url}' "https://github.com/$repo/releases/latest" 2>/dev/null)"
  case "$loc" in
    */releases/tag/*) tag="${loc##*/tag/}"; tag="${tag%%[!A-Za-z0-9._-]*}" ;;
  esac
  if [ -z "$tag" ]; then
    tag="$(api_get "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | extract_str tag_name)"
  fi
  printf '%s' "$tag"
}

# Pretty-print a ref value: shorten 40-char commit SHAs, show release tags whole.
dispv() {
  case "$1" in
    *[!0-9a-f]*) printf '%s' "$1" ;;                                  # has non-hex -> a tag
    *) if [ ${#1} -gt 12 ]; then short "$1"; else printf '%s' "$1"; fi ;;  # all hex -> a SHA
  esac
}

# Extract the first top-level "sha" hex value from a JSON body on stdin.
extract_sha() {
  grep -o '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]\{7,\}"' \
    | head -1 \
    | sed 's/.*"\([0-9a-f]\{7,\}\)".*/\1/'
}

# Extract a top-level string field value from a JSON body on stdin.
# extract_str FIELD
extract_str() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# ---------------------------------------------------------------------------
# Version state (plain key=value file; portable, no jq)
# ---------------------------------------------------------------------------

STATE_FILE="$MODS_DIR/.balatro-mod-installer.state"

state_get() {
  [ -f "$STATE_FILE" ] || return 0
  grep "^$1=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

state_set() {
  local key="$1" val="$2" tmp
  mkdir -p "$MODS_DIR"
  tmp="$STATE_FILE.tmp.$$"
  if [ -f "$STATE_FILE" ]; then
    grep -v "^$key=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

short() { printf '%s' "${1:0:8}"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  title "Balatro mod installer"
  hr
  note "game dir : $GAME_DIR"
  note "mods dir : $MODS_DIR"

  if [ ! -e "$GAME_DIR/Balatro.app" ]; then
    fail "Could not find Balatro.app in the game directory."
    note "Expected: $GAME_DIR/Balatro.app"
    note "In Steam: right-click Balatro > Manage > Browse local files,"
    note "then re-run with:  BALATRO_GAME_DIR=\"/that/path\" $0"
    exit 1
  fi

  case "$(uname -m)" in
    arm64)  ARCH_ASSET="lovely-aarch64-apple-darwin.tar.gz"; note "cpu      : Apple Silicon (arm64)" ;;
    x86_64) ARCH_ASSET="lovely-x86_64-apple-darwin.tar.gz";  note "cpu      : Intel (x86_64)" ;;
    *)      fail "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac

  USE_GIT=0
  if command -v git >/dev/null 2>&1; then
    USE_GIT=1
    note "resolve  : git ls-remote (not rate-limited)"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    note "resolve  : GitHub REST API (authenticated)"
  else
    note "resolve  : GitHub REST API (anonymous, 60/hr — install git or set GITHUB_TOKEN if limited)"
  fi

  mkdir -p "$MODS_DIR"
  WORK_DIR="$MODS_DIR/.balatro-mod-installer.tmp"
  rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
  hr
}

# ---------------------------------------------------------------------------
# Lovely injector  (release binary -> game directory, NOT the Mods folder)
# ---------------------------------------------------------------------------

install_lovely() {
  local tag dll="$GAME_DIR/liblovely.dylib" sh="$GAME_DIR/run_lovely_macos.sh"
  local cur installed_present=0

  tag="$(resolve_release_tag "$LOVELY_REPO")"
  if [ -z "$tag" ]; then
    fail "Lovely: could not resolve latest release (network / GitHub rate limit?)"
    N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST Lovely"; return
  fi

  cur="$(state_get lovely)"
  [ -f "$dll" ] && [ -f "$sh" ] && installed_present=1

  if [ "$MODE" = "status" ]; then
    if [ "$installed_present" = 1 ] && [ "$cur" = "$tag" ]; then ok "Lovely $tag (installed)"
    elif [ "$installed_present" = 1 ];                    then upd "Lovely $cur -> $tag available"
    else                                                       add "Lovely $tag (not installed)"; fi
    return
  fi

  if [ "$FORCE" = 0 ] && [ "$installed_present" = 1 ] && [ "$cur" = "$tag" ]; then
    ok "Lovely $tag"; N_OK=$((N_OK+1)); return
  fi

  local was_new=1; [ "$installed_present" = 1 ] && was_new=0
  if [ "$was_new" = 1 ]; then add "Lovely $tag (installing)"; else upd "Lovely $cur -> $tag"; fi

  local url="https://github.com/$LOVELY_REPO/releases/download/$tag/$ARCH_ASSET"
  local tgz="$WORK_DIR/lovely.tar.gz"
  if ! download "$url" "$tgz"; then
    fail "Lovely: download failed ($url)"
    N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST Lovely"; return
  fi

  # Tarball holds exactly liblovely.dylib + run_lovely_macos.sh, no wrapper dir.
  if ! tar -xzf "$tgz" -C "$GAME_DIR"; then
    fail "Lovely: extraction failed"
    N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST Lovely"; return
  fi
  chmod +x "$sh" 2>/dev/null || true

  # The bundled launcher hardcodes the default Steam path. If this machine uses
  # a custom game dir, point the launcher at it so the relative dylib resolves.
  if [ "$GAME_DIR" != "$DEFAULT_GAME_DIR" ]; then
    sed -i '' "s|^defaultpath=.*|defaultpath=\"$GAME_DIR\"|" "$sh" 2>/dev/null \
      && note "patched run_lovely_macos.sh -> $GAME_DIR"
  fi

  state_set lovely "$tag"
  if [ "$was_new" = 1 ]; then N_NEW=$((N_NEW+1)); else N_UPD=$((N_UPD+1)); fi
}

# ---------------------------------------------------------------------------
# Source mods  (branch HEAD or latest release source -> Mods/<folder>/)
# ---------------------------------------------------------------------------

install_source_mod() {
  local key="$1" repo="$2" folder="$3" ref_spec="$4"
  local target="$MODS_DIR/$folder" ref cur present=0 url

  # Resolve the version (commit SHA for a branch, tag for @release) and the
  # matching source-tarball URL.
  if [ "$ref_spec" = "@release" ]; then
    ref="$(resolve_release_tag "$repo")"
    url="https://github.com/$repo/archive/refs/tags/$ref.tar.gz"
    if [ -z "$ref" ]; then
      fail "$key: could not resolve latest release ($repo) — network / rate limit?"
      N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST $key"; return
    fi
  else
    ref="$(resolve_sha "$repo" "$ref_spec")"
    url="https://github.com/$repo/archive/$ref.tar.gz"
    if [ -z "$ref" ]; then
      fail "$key: could not resolve latest commit ($repo@$ref_spec) — network / rate limit?"
      N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST $key"; return
    fi
  fi

  cur="$(state_get "$key")"
  [ -d "$target" ] && present=1

  if [ "$MODE" = "status" ]; then
    if [ "$present" = 1 ] && [ "$cur" = "$ref" ]; then ok  "$key ($(dispv "$ref")) [$folder]"
    elif [ "$present" = 1 ];                       then upd "$key $(dispv "$cur") -> $(dispv "$ref") [$folder]"
    else                                                add "$key (not installed) -> $(dispv "$ref")"; fi
    return
  fi

  if [ "$FORCE" = 0 ] && [ "$present" = 1 ] && [ "$cur" = "$ref" ]; then
    ok "$key ($(dispv "$ref")) [$folder]"; N_OK=$((N_OK+1)); return
  fi

  local was_new=1; [ "$present" = 1 ] && was_new=0
  if [ "$was_new" = 1 ]; then add "$key -> $(dispv "$ref") [$folder]"
  else upd "$key $(dispv "$cur") -> $(dispv "$ref") [$folder]"; fi

  local tgz="$WORK_DIR/$key.tar.gz"
  local ex="$WORK_DIR/$key.extract"

  if ! download "$url" "$tgz"; then
    fail "$key: download failed ($url)"
    N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST $key"; return
  fi

  rm -rf "$ex"; mkdir -p "$ex"
  # GitHub archives wrap everything in one top-level dir; strip it so the mod's
  # files (manifest / <name>.json / *.lua / lovely/) land at the folder root.
  if ! tar -xzf "$tgz" -C "$ex" --strip-components=1; then
    fail "$key: extraction failed"
    N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST $key"; rm -rf "$ex"; return
  fi

  # Atomic-ish replace within the same filesystem.
  rm -rf "$target"
  if ! mv "$ex" "$target"; then
    fail "$key: could not move into place ($target)"
    N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST $key"; return
  fi

  state_set "$key" "$ref"
  if [ "$was_new" = 1 ]; then N_NEW=$((N_NEW+1)); else N_UPD=$((N_UPD+1)); fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

preflight

title "Lovely injector  (game directory)"
install_lovely
echo

title "Mods  (Mods directory)"
while IFS='|' read -r key repo folder ref; do
  case "$key" in ''|\#*) continue ;; esac
  install_source_mod "$key" "$repo" "$folder" "$ref"
done < <(printf '%s\n' "$MODS_TABLE")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
hr
if [ "$MODE" = "status" ]; then
  title "Status check complete (no changes made)."
else
  title "Done."
  printf '  %sinstalled%s %d   %supdated%s %d   %sup-to-date%s %d   %sfailed%s %d\n' \
    "$C_YELLOW" "$C_RESET" "$N_NEW" \
    "$C_BLUE"   "$C_RESET" "$N_UPD" \
    "$C_GREEN"  "$C_RESET" "$N_OK" \
    "$C_RED"    "$C_RESET" "$N_FAIL"
  [ -n "$FAILED_LIST" ] && note "failed:$FAILED_LIST"
fi
hr

if [ "$MODE" != "status" ] && [ "$N_FAIL" = 0 ]; then
  cat <<EOF

${C_BOLD}How to launch (Steam launch is broken on macOS — you must use Lovely):${C_RESET}
  1. Open Terminal.
  2. Run:  ${C_BOLD}sh "$GAME_DIR/run_lovely_macos.sh"${C_RESET}
     (or drag run_lovely_macos.sh from that folder onto Terminal and press Enter)

${C_DIM}Notes:
  - Amulet replaces Talisman (big-number scaling). Don't also install Talisman.
  - Cryptid requires Steamodded + Amulet (both included above).
  - Re-run this script any time to update everything to the latest version.${C_RESET}
EOF
fi

[ "$N_FAIL" = 0 ] || exit 1
exit 0
