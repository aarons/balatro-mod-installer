#!/bin/bash
#
# install.sh
#
# Installer / updater for a curated set of Balatro mods. Works on both
# macOS (native build, Lovely dylib) and Steam Deck / Linux (Windows build
# via Proton, Lovely version.dll) — the platform is auto-detected.
#
# The mod list lives in mods.csv (name,type,url,ref,folder — no pinned
# versions). This script resolves each mod's ref to a concrete version at
# run time (latest release tag, or a branch's latest commit), then downloads
# and installs whatever is missing or stale. Re-running is always safe.
# Folders in the Mods directory that aren't in the list are REMOVED, so
# dropped mods don't linger (pass --keep-extra to keep them).
#
# Where the mod list comes from:
#   - mods.csv next to this script, if present (a repo checkout)   [default]
#   - otherwise fetched from the repo on GitHub (a lone copy of this
#     script, e.g. on the Steam Deck). In that mode the script first
#     updates ITSELF from the repo, so the one file on the Deck never
#     goes stale.
#
#   ./install.sh                  # install/update everything
#   ./install.sh --status         # report installed vs latest, change nothing
#   ./install.sh --force          # reinstall everything from scratch
#   ./install.sh --keep-extra     # don't remove unlisted mod folders
#   ./install.sh --remote         # fetch mods.csv from GitHub even in a checkout
#   ./install.sh --mods-file F    # use a specific mod list
#   ./install.sh --no-self-update # skip the self-update check (remote mode)
#   ./install.sh --help
#
# Requirements: bash, curl, tar (stock everywhere). Linux additionally needs
# one of {unzip, bsdtar, python3} to unpack Lovely's Windows .zip (all stock
# on SteamOS). git is preferred for resolving branch versions (git ls-remote
# is not subject to GitHub's REST rate limit); without it the script falls
# back to the REST API (anonymous: 60 req/hr — set GITHUB_TOKEN to raise it).
#
set -u

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The repo this installer (and its mods.csv) lives in — used for remote mode
# and self-update. Override for forks/testing.
REPO_URL="${BALATRO_REPO_URL:-https://github.com/aarons/balatro-mod-installer}"
REPO_BRANCH="${BALATRO_BRANCH:-main}"

# Raw-file base URL derived from REPO_URL (GitHub only). BALATRO_RAW_BASE
# overrides it directly (handy for testing against a local server).
case "$REPO_URL" in
  https://github.com/*) RAW_BASE_DEFAULT="https://raw.githubusercontent.com/${REPO_URL#https://github.com/}/$REPO_BRANCH" ;;
  *)                    RAW_BASE_DEFAULT="" ;;
esac
RAW_BASE="${BALATRO_RAW_BASE:-$RAW_BASE_DEFAULT}"

# Balatro's Steam application id (locates its Proton prefix on Linux).
APPID=2379780

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

GAME_DIR="${BALATRO_GAME_DIR:-}"
MODS_DIR="${BALATRO_MODS_DIR:-}"
MODS_FILE="${BALATRO_MODS_FILE:-}"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

ORIG_ARGS=("$@")   # preserved for re-exec after self-update

MODE="install"     # install | status
FORCE=0
KEEP_EXTRA=0
REMOTE=0
SELF_UPDATE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --status|--check) MODE="status" ;;
    --force) FORCE=1 ;;
    --keep-extra) KEEP_EXTRA=1 ;;
    --remote) REMOTE=1 ;;
    --no-self-update) SELF_UPDATE=0 ;;
    --game-dir) shift; GAME_DIR="${1:-}" ;;
    --mods-dir) shift; MODS_DIR="${1:-}" ;;
    --mods-file) shift; MODS_FILE="${1:-}" ;;
    -h|--help)
      awk 'NR==1{next} /^#/{s=$0; sub(/^# ?/,"",s); print s; next} {exit}' "$0"
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
del()   { printf '  %s[del]%s  %s\n'    "$C_RED"    "$C_RESET" "$*"; }
fail()  { printf '  %s[ERR]%s  %s\n'    "$C_RED"    "$C_RESET" "$*"; }
note()  { printf '         %s%s%s\n'    "$C_DIM"    "$*" "$C_RESET"; }

# Counters
N_OK=0; N_NEW=0; N_UPD=0; N_FAIL=0; N_DEL=0
FAILED_LIST=""

record_fail() { fail "$*"; N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST ${*%%:*}"; }

# ---------------------------------------------------------------------------
# Workspace + cleanup
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/balatro-install.XXXXXX")"
WORK_DIR=""   # created under MODS_DIR in preflight (same fs as targets)
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null; [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null; }
trap cleanup EXIT INT TERM

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# download URL DEST
download() { curl -fsSL --connect-timeout 15 "$1" -o "$2"; }

# Pretty-print a version: shorten 40-char commit SHAs, show release tags whole.
dispv() {
  case "$1" in
    '') printf '%s' "(none)" ;;
    *[!0-9a-f]*) printf '%s' "$1" ;;
    *) if [ ${#1} -gt 12 ]; then printf '%s' "${1:0:8}"; else printf '%s' "$1"; fi ;;
  esac
}

# Emit mods.csv data rows (comments/blank lines stripped).
csv_rows() { grep -Ev '^[[:space:]]*(#|$)' "$MODS_FILE"; }

# host_of URL       -> e.g. github.com
# repo_path_of URL  -> e.g. owner/repo (no leading slash, no trailing .git)
host_of()      { local h="${1#*://}"; printf '%s' "${h%%/*}"; }
repo_path_of() { local p="${1#*://}"; p="${p#*/}"; p="${p%/}"; printf '%s' "${p%.git}"; }

# ---------------------------------------------------------------------------
# Version resolution (per mod, at run time)
# ---------------------------------------------------------------------------

# api_get URL  -> prints body to stdout, non-zero on HTTP/transport error
api_get() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$1"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$1"
  fi
}

# Extract the first top-level "sha" hex value from a JSON body on stdin.
extract_sha() {
  grep -o '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]\{7,\}"' \
    | head -1 \
    | sed 's/.*"\([0-9a-f]\{7,\}\)".*/\1/'
}

# Extract a top-level string field value from a JSON body on stdin.
extract_str() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# Resolve a repo's latest release tag. Prefers the /releases/latest redirect
# (works anonymously, not rate-limited); falls back to the REST API on GitHub.
#   resolve_release_tag URL  -> tag on stdout (empty on failure)
resolve_release_tag() {
  local url="$1" tag="" loc
  loc="$(curl -sI -o /dev/null -w '%{redirect_url}' --connect-timeout 15 "$url/releases/latest" 2>/dev/null)"
  case "$loc" in
    */releases/tag/*) tag="${loc##*/tag/}"; tag="${tag%%[!A-Za-z0-9._-]*}" ;;
  esac
  if [ -z "$tag" ] && [ "$(host_of "$url")" = "github.com" ]; then
    tag="$(api_get "https://api.github.com/repos/$(repo_path_of "$url")/releases/latest" 2>/dev/null | extract_str tag_name)"
  fi
  printf '%s' "$tag"
}

# resolve_ref URL REF -> sets R_KIND (sha|tag) and R_VERSION; non-zero on failure.
#   @release      -> latest release tag
#   40-hex sha    -> used as-is (a pin)
#   branch name   -> that branch's latest commit sha
#   tag name      -> used as-is (a pin; needs git to be recognized as a tag,
#                    otherwise it still resolves to the tagged commit's sha
#                    via the GitHub API)
resolve_ref() {
  local url="$1" ref="$2" sha=""
  R_KIND=""; R_VERSION=""

  if [ "$ref" = "@release" ]; then
    local tag; tag="$(resolve_release_tag "$url")"
    [ -n "$tag" ] && { R_KIND=tag; R_VERSION="$tag"; }
    [ -n "$R_VERSION" ]; return
  fi

  case "$ref" in
    *[!0-9a-f]*|'') ;;   # not a bare sha — fall through
    *) if [ ${#ref} -eq 40 ]; then R_KIND=sha; R_VERSION="$ref"; return 0; fi ;;
  esac

  if [ "$USE_GIT" = 1 ]; then
    sha="$(git ls-remote "$url" "refs/heads/$ref" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -n "$sha" ]; then R_KIND=sha; R_VERSION="$sha"; return 0; fi
    if [ -n "$(git ls-remote "$url" "refs/tags/$ref" 2>/dev/null)" ]; then
      R_KIND=tag; R_VERSION="$ref"; return 0
    fi
  fi
  if [ "$(host_of "$url")" = "github.com" ]; then
    # /commits/<ref> accepts branch and tag names alike.
    sha="$(api_get "https://api.github.com/repos/$(repo_path_of "$url")/commits/$ref" 2>/dev/null | extract_sha)"
    [ -n "$sha" ] && { R_KIND=sha; R_VERSION="$sha"; }
  fi
  [ -n "$R_VERSION" ]
}

# ---------------------------------------------------------------------------
# Download-URL construction — the only host-specific part. To support another
# git host (GitLab, Codeberg, ...), add a case to these two functions.
# ---------------------------------------------------------------------------

# source_tarball_url URL KIND VERSION -> tarball URL on stdout, non-zero if
# the host isn't supported.
source_tarball_url() {
  local url="$1" kind="$2" version="$3"
  case "$(host_of "$url")" in
    github.com)
      case "$kind" in
        sha) printf '%s' "$url/archive/$version.tar.gz" ;;
        tag) printf '%s' "$url/archive/refs/tags/$version.tar.gz" ;;
        *)   return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# release_asset_url URL TAG ASSET -> download URL for a release binary.
release_asset_url() {
  case "$(host_of "$1")" in
    github.com) printf '%s' "$1/releases/download/$2/$3" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Mod list source (local file vs fetched from the repo) + self-update
# ---------------------------------------------------------------------------

# Decide where mods.csv comes from. Sets MODS_FILE and LIST_MODE.
resolve_list_source() {
  if [ -n "$MODS_FILE" ]; then
    LIST_MODE="local"
  elif [ "$REMOTE" = 0 ] && [ -f "$SCRIPT_DIR/mods.csv" ]; then
    LIST_MODE="local"; MODS_FILE="$SCRIPT_DIR/mods.csv"
  else
    LIST_MODE="remote"; MODS_FILE="$TMP_DIR/mods.csv"
  fi
}

fetch_remote_list() {
  if [ -z "$RAW_BASE" ]; then
    fail "No local mods.csv and no way to fetch one — REPO_URL isn't on GitHub."
    note "Put mods.csv next to this script or pass --mods-file."
    exit 1
  fi
  if ! download "$RAW_BASE/mods.csv" "$MODS_FILE"; then
    fail "Could not fetch mod list: $RAW_BASE/mods.csv"
    note "Offline? Or pass a local list with --mods-file."
    exit 1
  fi
  if ! csv_rows | grep -q .; then
    fail "Fetched mod list is empty or unreadable: $RAW_BASE/mods.csv"
    exit 1
  fi
}

# In remote mode, refresh this script itself from the repo so a lone copy
# (the Steam Deck) never goes stale. Replaces the file and re-execs once;
# any failure just means we continue with the current version.
self_update() {
  local latest="$TMP_DIR/install.sh.latest"
  download "$RAW_BASE/install.sh" "$latest" 2>/dev/null || {
    note "self-update: could not fetch latest install.sh — continuing."
    return 0
  }
  head -1 "$latest" | grep -q '^#!/bin/bash' || {
    note "self-update: fetched file doesn't look like install.sh — ignoring."
    return 0
  }
  cmp -s "$latest" "$SCRIPT_PATH" && return 0
  if cp "$latest" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH" 2>/dev/null; then
    ok "install.sh updated from the repo — restarting."
    echo
    export BALATRO_SELF_UPDATED=1
    exec bash "$SCRIPT_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  note "self-update: could not overwrite $SCRIPT_PATH — continuing with current version."
}

# ---------------------------------------------------------------------------
# Version state (plain key=value file; portable, no jq)
# ---------------------------------------------------------------------------

STATE_FILE=""   # depends on MODS_DIR; set in preflight

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

# ---------------------------------------------------------------------------
# Steam library / Proton prefix discovery (Linux)
# ---------------------------------------------------------------------------

# Find the directory containing Balatro.exe by scanning the usual Steam library
# roots plus any extra libraries listed in libraryfolders.vdf (e.g. an SD card).
detect_game_dir_linux() {
  local roots r vdf p
  roots=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.steam/root"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"
  )
  for r in "${roots[@]}"; do
    vdf="$r/steamapps/libraryfolders.vdf"
    [ -f "$vdf" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] && roots+=("$p")
    done < <(grep -o '"path"[[:space:]]*"[^"]*"' "$vdf" 2>/dev/null \
               | sed 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/')
  done
  for r in "${roots[@]}"; do
    if [ -f "$r/steamapps/common/Balatro/Balatro.exe" ]; then
      printf '%s' "$r/steamapps/common/Balatro"
      return 0
    fi
  done
  return 1
}

# Given a steamapps directory, return the in-prefix Mods path for Balatro.
# Prints the path on stdout; returns non-zero (but still prints the expected
# path) if the Proton prefix doesn't exist yet.
derive_mods_dir_linux() {
  local steamapps="$1"
  local pfx="$steamapps/compatdata/$APPID/pfx"
  local udir="$pfx/drive_c/users/steamuser" c
  # Modern Proton always uses the Windows user "steamuser"; older Wine prefixes
  # used the Linux login name. Prefer steamuser, else any real user dir.
  if [ ! -d "$udir" ]; then
    for c in "$pfx"/drive_c/users/*; do
      [ -d "$c" ] || continue
      case "${c##*/}" in Public|steamuser) continue ;; esac
      udir="$c"; break
    done
  fi
  printf '%s' "$udir/AppData/Roaming/Balatro/Mods"
  [ -d "$pfx" ]
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

DEFAULT_GAME_DIR_MAC="$HOME/Library/Application Support/Steam/steamapps/common/Balatro"
DEFAULT_MODS_DIR_MAC="$HOME/Library/Application Support/Balatro/Mods"
DEFAULT_GAME_DIR_LINUX="$HOME/.local/share/Steam/steamapps/common/Balatro"

preflight() {
  case "$PLATFORM" in
    mac)  title "Balatro mod installer  (macOS)" ;;
    deck) title "Balatro mod installer  (Steam Deck / Proton)" ;;
  esac
  hr
  if [ "$LIST_MODE" = "remote" ]; then
    note "mod list : $RAW_BASE/mods.csv (fetched)"
  else
    note "mod list : $MODS_FILE"
  fi

  if [ ! -f "$MODS_FILE" ]; then
    fail "mod list not found: $MODS_FILE"
    note "It ships alongside this script; pass another list with --mods-file."
    exit 1
  fi

  if [ "$USE_GIT" = 1 ]; then
    note "resolve  : git ls-remote + release redirects (not rate-limited)"
  else
    note "resolve  : GitHub REST API fallback (anonymous: 60 req/hr; set GITHUB_TOKEN to raise)"
  fi

  if [ "$PLATFORM" = "mac" ]; then
    preflight_mac
  else
    preflight_deck
  fi

  STATE_FILE="$MODS_DIR/.balatro-mod-installer.state"
  mkdir -p "$MODS_DIR"
  WORK_DIR="$MODS_DIR/.balatro-mod-installer.tmp"
  rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
  hr
}

preflight_mac() {
  [ -z "$GAME_DIR" ] && GAME_DIR="$DEFAULT_GAME_DIR_MAC"
  [ -z "$MODS_DIR" ] && MODS_DIR="$DEFAULT_MODS_DIR_MAC"
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
    arm64)  LOVELY_ASSET="lovely-aarch64-apple-darwin.tar.gz"; note "cpu      : Apple Silicon (arm64)" ;;
    x86_64) LOVELY_ASSET="lovely-x86_64-apple-darwin.tar.gz";  note "cpu      : Intel (x86_64)" ;;
    *)      fail "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

preflight_deck() {
  # Balatro has no native Linux build; Steam runs the Windows game through
  # Proton, so Lovely is the Windows version.dll and mods live in the prefix.
  LOVELY_ASSET="lovely-x86_64-pc-windows-msvc.zip"

  if [ -z "$GAME_DIR" ]; then
    GAME_DIR="$(detect_game_dir_linux || true)"
    [ -n "$GAME_DIR" ] && note "found    : auto-detected game install"
  fi
  [ -z "$GAME_DIR" ] && GAME_DIR="$DEFAULT_GAME_DIR_LINUX"
  note "game dir : $GAME_DIR"

  if [ ! -e "$GAME_DIR/Balatro.exe" ]; then
    fail "Could not find Balatro.exe in the game directory."
    note "Expected: $GAME_DIR/Balatro.exe"
    note "In Steam: right-click Balatro > Manage > Browse local files,"
    note "then re-run with:  BALATRO_GAME_DIR=\"/that/path\" $0"
    note "(On Linux/Proton the install folder holds Balatro.exe, not Balatro.app.)"
    exit 1
  fi

  # Mods live inside Balatro's Proton prefix; derive it from the same Steam
  # library the game lives in, so an SD-card install finds its SD-card prefix.
  local steamapps prefix_ok=1
  case "$GAME_DIR" in
    */steamapps/common/Balatro) steamapps="${GAME_DIR%/common/Balatro}" ;;
    *) steamapps="" ;;
  esac

  if [ -z "$MODS_DIR" ]; then
    if [ -n "$steamapps" ]; then
      MODS_DIR="$(derive_mods_dir_linux "$steamapps")" || prefix_ok=0
    else
      fail "Custom --game-dir doesn't match the usual Steam layout, so the Mods"
      note "folder can't be derived. Pass it explicitly:"
      note "  --mods-dir \"<prefix>/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods\""
      exit 1
    fi
  fi
  note "mods dir : $MODS_DIR"

  if [ "$prefix_ok" = 0 ]; then
    fail "Balatro's Proton prefix doesn't exist yet — it's created on first run."
    note "Expected prefix: $steamapps/compatdata/$APPID/pfx"
    note "Fix: launch Balatro once through Steam (Proton), quit, then re-run this."
    note "(Or point at an existing Mods folder with --mods-dir \"...\".)"
    exit 1
  fi

  note "target   : Windows build via Proton/Wine (Lovely = version.dll)"

  if   have unzip;   then ZIP_TOOL=unzip
  elif have bsdtar;  then ZIP_TOOL=bsdtar
  elif have python3; then ZIP_TOOL=python3
  else
    fail "Need one of: unzip, bsdtar, or python3 to unpack Lovely's .zip."
    note "On SteamOS/Arch:  sudo pacman -S unzip   (python3 is usually present)"
    exit 1
  fi
  note "unzip    : $ZIP_TOOL"
}

# extract_zip ZIP DESTDIR  -> non-zero on failure (Linux only; GNU tar can't
# read .zip, so use whichever zip-capable tool preflight found)
extract_zip() {
  local zip="$1" dest="$2"
  case "${ZIP_TOOL:-}" in
    unzip)   unzip -o -q "$zip" -d "$dest" ;;
    bsdtar)  bsdtar -xf "$zip" -C "$dest" ;;
    python3) python3 -m zipfile -e "$zip" "$dest" ;;
    *)       return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Lovely injector  (release binary -> game directory, NOT the Mods folder)
# ---------------------------------------------------------------------------

# install_lovely_mac NAME TAG URL
install_lovely_mac() {
  local name="$1" tag="$2" url="$3"
  local dll="$GAME_DIR/liblovely.dylib" sh="$GAME_DIR/run_lovely_macos.sh"
  local cur installed_present=0

  cur="$(state_get "$name")"
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

  local tgz="$WORK_DIR/lovely.tar.gz"
  if ! download "$url" "$tgz"; then
    record_fail "$name: download failed ($url)"; return
  fi

  # Tarball holds exactly liblovely.dylib + run_lovely_macos.sh, no wrapper dir.
  if ! tar -xzf "$tgz" -C "$GAME_DIR"; then
    record_fail "$name: extraction failed"; return
  fi
  chmod +x "$sh" 2>/dev/null || true

  # The bundled launcher hardcodes the default Steam path. If this machine uses
  # a custom game dir, point the launcher at it so the relative dylib resolves.
  if [ "$GAME_DIR" != "$DEFAULT_GAME_DIR_MAC" ]; then
    sed -i '' "s|^defaultpath=.*|defaultpath=\"$GAME_DIR\"|" "$sh" 2>/dev/null \
      && note "patched run_lovely_macos.sh -> $GAME_DIR"
  fi

  state_set "$name" "$tag"
  if [ "$was_new" = 1 ]; then N_NEW=$((N_NEW+1)); else N_UPD=$((N_UPD+1)); fi
}

# install_lovely_deck NAME TAG URL
install_lovely_deck() {
  local name="$1" tag="$2" url="$3"
  local dll="$GAME_DIR/version.dll"
  local cur installed_present=0

  cur="$(state_get "$name")"
  [ -f "$dll" ] && installed_present=1

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

  local zip="$WORK_DIR/lovely.zip"
  if ! download "$url" "$zip"; then
    record_fail "$name: download failed ($url)"; return
  fi

  # The Windows archive holds exactly version.dll. Extract to a temp dir, then
  # drop version.dll next to Balatro.exe (so a stray archive layout can't
  # scatter files into the game folder).
  local ex="$WORK_DIR/lovely.extract"
  rm -rf "$ex"; mkdir -p "$ex"
  if ! extract_zip "$zip" "$ex"; then
    record_fail "$name: extraction failed (unzip tool: ${ZIP_TOOL:-none})"; return
  fi
  if [ ! -f "$ex/version.dll" ]; then
    record_fail "$name: version.dll not found inside $LOVELY_ASSET"; return
  fi
  if ! cp -f "$ex/version.dll" "$dll"; then
    record_fail "$name: could not write $dll"; return
  fi

  state_set "$name" "$tag"
  if [ "$was_new" = 1 ]; then N_NEW=$((N_NEW+1)); else N_UPD=$((N_UPD+1)); fi
}

# ---------------------------------------------------------------------------
# Source mods  (source tarball -> Mods/<folder>/)
# ---------------------------------------------------------------------------

# install_source_mod NAME FOLDER VERSION URL
install_source_mod() {
  local key="$1" folder="$2" ref="$3" url="$4"
  local target="$MODS_DIR/$folder" cur present=0

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
    record_fail "$key: download failed ($url)"; return
  fi

  rm -rf "$ex"; mkdir -p "$ex"
  # GitHub archives wrap everything in one top-level dir; strip it so the mod's
  # files (manifest / <name>.json / *.lua / lovely/) land at the folder root.
  if ! tar -xzf "$tgz" -C "$ex" --strip-components=1; then
    record_fail "$key: extraction failed"; rm -rf "$ex"; return
  fi

  # Atomic-ish replace within the same filesystem.
  rm -rf "$target"
  if ! mv "$ex" "$target"; then
    record_fail "$key: could not move into place ($target)"; return
  fi

  state_set "$key" "$ref"
  if [ "$was_new" = 1 ]; then N_NEW=$((N_NEW+1)); else N_UPD=$((N_UPD+1)); fi
}

# ---------------------------------------------------------------------------
# Per-row driver: resolve the ref, build the download URL, install
# ---------------------------------------------------------------------------

process_row() {
  local name="$1" type="$2" url="$3" ref="$4" folder="$5" dl

  if ! resolve_ref "$url" "$ref"; then
    local cur; cur="$(state_get "$name")"
    if [ -n "$cur" ]; then
      record_fail "$name: could not resolve $ref from $url — keeping installed $(dispv "$cur")"
    else
      record_fail "$name: could not resolve $ref from $url (offline? rate limit?)"
    fi
    return
  fi

  case "$type" in
    injector)
      if ! dl="$(release_asset_url "$url" "$R_VERSION" "$LOVELY_ASSET")"; then
        record_fail "$name: host $(host_of "$url") not supported — add it to release_asset_url()"; return
      fi
      if [ "$PLATFORM" = "mac" ]; then install_lovely_mac "$name" "$R_VERSION" "$dl"
      else install_lovely_deck "$name" "$R_VERSION" "$dl"; fi ;;
    mod)
      if ! dl="$(source_tarball_url "$url" "$R_KIND" "$R_VERSION")"; then
        record_fail "$name: host $(host_of "$url") not supported — add it to source_tarball_url()"; return
      fi
      install_source_mod "$name" "$folder" "$R_VERSION" "$dl" ;;
    *)
      record_fail "$name: unknown type '$type' in mod list" ;;
  esac
}

# ---------------------------------------------------------------------------
# Prune  (Mods/<folder>/ dirs no longer in the mod list)
# ---------------------------------------------------------------------------

# Remove any visible directory under MODS_DIR whose name isn't a `folder` in
# the mod list. Dotfiles/dot-dirs (installer state, temp dir) are skipped by
# the glob, and `lovely` is kept — the injector writes its logs/dumps there.
prune_unmanaged() {
  local managed d base
  managed="$(csv_rows | awk -F',' '$2 == "mod" { print $5 }')"

  for d in "$MODS_DIR"/*/; do
    [ -d "$d" ] || continue
    base="${d%/}"; base="${base##*/}"
    [ "$base" = "lovely" ] && continue
    printf '%s\n' "$managed" | grep -qxF "$base" && continue

    if [ "$MODE" = "status" ]; then
      del "$base (not in the mod list — would be removed)"
    elif [ "$KEEP_EXTRA" = 1 ]; then
      note "keeping unlisted folder: $base (--keep-extra)"
    else
      if rm -rf "$MODS_DIR/$base"; then
        del "$base (removed — not in the mod list)"
        N_DEL=$((N_DEL+1))
      else
        record_fail "$base: could not remove $MODS_DIR/$base"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

case "$(uname -s)" in
  Darwin) PLATFORM="mac" ;;
  Linux)  PLATFORM="deck" ;;
  *) echo "Unsupported OS: $(uname -s) (this installer supports macOS and Linux)" >&2; exit 1 ;;
esac

USE_GIT=0
have git && USE_GIT=1

resolve_list_source
if [ "$LIST_MODE" = "remote" ]; then
  if [ "$SELF_UPDATE" = 1 ] && [ -z "${BALATRO_SELF_UPDATED:-}" ] && [ -n "$RAW_BASE" ]; then
    self_update
  fi
  fetch_remote_list
fi

preflight

title "Lovely injector  (game directory)"
while IFS=',' read -r name type url ref folder; do
  [ "$type" = "injector" ] || continue
  process_row "$name" "$type" "$url" "$ref" "$folder"
done < <(csv_rows)
echo

title "Mods  (Mods directory)"
while IFS=',' read -r name type url ref folder; do
  [ "$type" = "injector" ] && continue
  process_row "$name" "$type" "$url" "$ref" "$folder"
done < <(csv_rows)
echo

title "Cleanup  (folders not in the mod list)"
prune_unmanaged
[ "$N_DEL" = 0 ] && [ "$MODE" != "status" ] && note "nothing to remove"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
hr
if [ "$MODE" = "status" ]; then
  title "Status check complete (no changes made)."
else
  title "Done."
  printf '  %sinstalled%s %d   %supdated%s %d   %sup-to-date%s %d   %sremoved%s %d   %sfailed%s %d\n' \
    "$C_YELLOW" "$C_RESET" "$N_NEW" \
    "$C_BLUE"   "$C_RESET" "$N_UPD" \
    "$C_GREEN"  "$C_RESET" "$N_OK" \
    "$C_RED"    "$C_RESET" "$N_DEL" \
    "$C_RED"    "$C_RESET" "$N_FAIL"
  [ -n "$FAILED_LIST" ] && note "failed:$FAILED_LIST"
fi
hr

if [ "$MODE" != "status" ] && [ "$N_FAIL" = 0 ]; then
  if [ "$PLATFORM" = "mac" ]; then
    cat <<EOF

${C_BOLD}How to launch (Steam launch is broken on macOS — you must use Lovely):${C_RESET}
  1. Open Terminal.
  2. Run:  ${C_BOLD}sh "$GAME_DIR/run_lovely_macos.sh"${C_RESET}
     (or drag run_lovely_macos.sh from that folder onto Terminal and press Enter)

${C_DIM}Notes:
  - Amulet replaces Talisman (big-number scaling). Don't also install Talisman.
  - Cryptid requires Steamodded + Amulet (both included above).
  - Versions are resolved fresh on every run; just re-run this script to pick
    up new releases.${C_RESET}
EOF
  else
    cat <<EOF

${C_BOLD}One-time Steam setup (REQUIRED — without it, mods will NOT load):${C_RESET}
  1. In Steam, right-click ${C_BOLD}Balatro${C_RESET} > ${C_BOLD}Properties${C_RESET} > ${C_BOLD}General${C_RESET}.
  2. In ${C_BOLD}Launch Options${C_RESET}, paste exactly:
       ${C_BOLD}WINEDLLOVERRIDES="version=n,b" %command%${C_RESET}
     This tells Proton to load Lovely's version.dll. You only set it once.
  3. Launch ${C_BOLD}Balatro${C_RESET} normally from Steam — Lovely injects automatically.

${C_DIM}Notes:
  - In Game Mode the launch option is set the same way (gear icon > Properties).
  - Amulet replaces Talisman (big-number scaling). Don't also install Talisman.
  - Cryptid requires Steamodded + Amulet (both included above).
  - Versions (and this script itself) refresh from the repo on every run;
    just run ./install.sh again to pick up anything new.${C_RESET}
EOF
  fi
fi

[ "$N_FAIL" = 0 ] || exit 1
exit 0
