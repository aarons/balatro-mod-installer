#!/bin/bash
#
# install-balatro-mods-steamdeck.sh
#
# Installer / updater for a curated set of Balatro mods on a Steam Deck
# (or any Linux box where Balatro runs through Proton/Wine).
# The mod list — and the exact version + download URL of each component —
# lives in mods.csv next to this script. This script does no version
# discovery of its own; ./update-mods.sh (run on the machine that maintains
# the repo) refreshes mods.csv.
# Re-running is safe: it compares the installed version of each component
# against mods.csv and only downloads what is missing or stale.
#
#   ./install-balatro-mods-steamdeck.sh            # install/update everything in mods.csv
#   ./install-balatro-mods-steamdeck.sh --status   # report only, change nothing
#   ./install-balatro-mods-steamdeck.sh --force    # reinstall everything from scratch
#   ./install-balatro-mods-steamdeck.sh --help
#
# Requirements: Linux, curl, tar, one of {unzip, bsdtar, python3} (Lovely's
# Windows build ships as a .zip), and mods.csv in the same directory
# (override with --mods-file). All tools are stock on SteamOS; no jq/git needed.
#
# IMPORTANT — this is the Proton/Wine build. On Linux/Steam Deck, Balatro has no
# native build; Steam runs the *Windows* game through Proton. So:
#   - Lovely is installed as the Windows version.dll (NOT the Linux .so), placed
#     next to Balatro.exe in the game directory.
#   - Mods live inside Balatro's Proton prefix (the Windows %AppData% mapped into
#     compatdata/2379780/pfx/...), NOT a native Linux folder.
#   - You MUST set a Steam launch option for Lovely to load (see the end of a
#     successful run). The script tells you the exact string.
#
set -u

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Balatro's Steam application id (used to locate its Proton prefix / Mods folder).
APPID=2379780

# Balatro runs via Proton, so we want Lovely's Windows build (a version.dll
# proxy). The Steam Deck and virtually all Linux Proton setups are x86_64.
LOVELY_ASSET="lovely-x86_64-pc-windows-msvc.zip"

DEFAULT_STEAM_ROOT="$HOME/.local/share/Steam"
DEFAULT_GAME_DIR="$DEFAULT_STEAM_ROOT/steamapps/common/Balatro"

# Resolved in preflight if left empty. Override via env or flags.
GAME_DIR="${BALATRO_GAME_DIR:-}"
MODS_DIR="${BALATRO_MODS_DIR:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODS_FILE="${BALATRO_MODS_FILE:-$SCRIPT_DIR/mods.csv}"

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
    --mods-file) shift; MODS_FILE="${1:-}" ;;
    -h|--help)
      # Print the leading comment block (skip the shebang, stop at the first
      # non-comment line), stripping the leading "# ".
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
fail()  { printf '  %s[ERR]%s  %s\n'    "$C_RED"    "$C_RESET" "$*"; }
note()  { printf '         %s%s%s\n'    "$C_DIM"    "$*" "$C_RESET"; }

# Counters
N_OK=0; N_NEW=0; N_UPD=0; N_FAIL=0
FAILED_LIST=""

record_fail() { fail "$*"; N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST ${*%%:*}"; }

# ---------------------------------------------------------------------------
# Workspace + cleanup
# ---------------------------------------------------------------------------

WORK_DIR=""
cleanup() { [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null; }
trap cleanup EXIT INT TERM

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# download URL DEST
download() { curl -fsSL "$1" -o "$2"; }

# extract_zip ZIP DESTDIR  -> non-zero on failure
# GNU tar can't read .zip, so use whichever zip-capable tool we found (set in
# preflight as ZIP_TOOL): unzip, libarchive's bsdtar, or python3's zipfile.
extract_zip() {
  local zip="$1" dest="$2"
  case "${ZIP_TOOL:-}" in
    unzip)   unzip -o -q "$zip" -d "$dest" ;;
    bsdtar)  bsdtar -xf "$zip" -C "$dest" ;;
    python3) python3 -m zipfile -e "$zip" "$dest" ;;
    *)       return 1 ;;
  esac
}

# Pretty-print a version: shorten 40-char commit SHAs, show release tags whole.
dispv() {
  case "$1" in
    *[!0-9a-f]*) printf '%s' "$1" ;;                                  # has non-hex -> a tag
    *) if [ ${#1} -gt 12 ]; then printf '%s' "${1:0:8}"; else printf '%s' "$1"; fi ;;
  esac
}

# Emit mods.csv data rows (comments/blank lines stripped).
csv_rows() { grep -Ev '^[[:space:]]*(#|$)' "$MODS_FILE"; }

# ---------------------------------------------------------------------------
# Steam library / Proton prefix discovery
# ---------------------------------------------------------------------------

# Find the directory containing Balatro.exe by scanning the usual Steam library
# roots plus any extra libraries listed in libraryfolders.vdf (e.g. an SD card).
# Prints the game dir on stdout, non-zero if not found.
detect_game_dir() {
  local roots r vdf p
  roots=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.steam/root"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"
  )
  # Pull additional library roots (SD card, second drive, ...) from any
  # libraryfolders.vdf we can find. Each `"path"  "<root>"` points at a library
  # root that contains its own steamapps/.
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
derive_mods_dir() {
  local steamapps="$1"
  local pfx="$steamapps/compatdata/$APPID/pfx"
  local udir="$pfx/drive_c/users/steamuser" c
  # Modern Proton always uses the Windows user "steamuser"; older Wine prefixes
  # used the Linux login name. Prefer steamuser, else fall back to any real user
  # dir under the prefix.
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
# Version state (plain key=value file; portable, no jq)
# ---------------------------------------------------------------------------

# STATE_FILE depends on MODS_DIR, which is resolved in preflight; set it there.
STATE_FILE=""

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
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  title "Balatro mod installer  (Steam Deck / Proton)"
  hr

  if [ "$(uname -s)" != "Linux" ]; then
    note "warning  : this is the Linux/Proton installer; you're on $(uname -s)."
    note "           for macOS use install-balatro-mods.sh instead."
  fi

  if [ ! -f "$MODS_FILE" ]; then
    fail "mods.csv not found."
    note "Expected: $MODS_FILE"
    note "Download it next to this script (share.sh prints the exact commands),"
    note "or pass another list with --mods-file."
    exit 1
  fi
  note "mod list : $MODS_FILE"

  # --- Game directory -------------------------------------------------------
  if [ -z "$GAME_DIR" ]; then
    GAME_DIR="$(detect_game_dir || true)"
    [ -n "$GAME_DIR" ] && note "found    : auto-detected game install"
  fi
  [ -z "$GAME_DIR" ] && GAME_DIR="$DEFAULT_GAME_DIR"
  note "game dir : $GAME_DIR"

  if [ ! -e "$GAME_DIR/Balatro.exe" ]; then
    fail "Could not find Balatro.exe in the game directory."
    note "Expected: $GAME_DIR/Balatro.exe"
    note "In Steam: right-click Balatro > Manage > Browse local files,"
    note "then re-run with:  BALATRO_GAME_DIR=\"/that/path\" $0"
    note "(On Linux/Proton the install folder holds Balatro.exe, not Balatro.app.)"
    exit 1
  fi

  # --- Mods directory (inside Balatro's Proton prefix) ----------------------
  # Derive from the same Steam library the game lives in, so an SD-card install
  # finds its SD-card prefix.
  local steamapps prefix_ok=1
  case "$GAME_DIR" in
    */steamapps/common/Balatro) steamapps="${GAME_DIR%/common/Balatro}" ;;
    *) steamapps="" ;;
  esac

  if [ -z "$MODS_DIR" ]; then
    if [ -n "$steamapps" ]; then
      MODS_DIR="$(derive_mods_dir "$steamapps")" || prefix_ok=0
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

  STATE_FILE="$MODS_DIR/.balatro-mod-installer.state"

  note "target   : Windows build via Proton/Wine (Lovely = version.dll)"

  # --- Tools ----------------------------------------------------------------
  if   have unzip;   then ZIP_TOOL=unzip
  elif have bsdtar;  then ZIP_TOOL=bsdtar
  elif have python3; then ZIP_TOOL=python3
  else
    fail "Need one of: unzip, bsdtar, or python3 to unpack Lovely's .zip."
    note "On SteamOS/Arch:  sudo pacman -S unzip   (python3 is usually present)"
    exit 1
  fi
  note "unzip    : $ZIP_TOOL"

  mkdir -p "$MODS_DIR"
  WORK_DIR="$MODS_DIR/.balatro-mod-installer.tmp"
  rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
  hr
}

# ---------------------------------------------------------------------------
# Lovely injector  (Windows version.dll -> game directory, NOT the Mods folder)
# ---------------------------------------------------------------------------

# install_lovely NAME VERSION URL   (url contains an {asset} placeholder)
install_lovely() {
  local name="$1" tag="$2" url="$3"
  local dll="$GAME_DIR/version.dll"
  local cur installed_present=0

  url="${url//\{asset\}/$LOVELY_ASSET}"
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
# Run
# ---------------------------------------------------------------------------

preflight

title "Lovely injector  (game directory)"
while IFS=',' read -r name type repo ref folder version url; do
  [ "$type" = "injector" ] || continue
  if [ -z "$version" ] || [ -z "$url" ]; then
    record_fail "$name: no resolved version in mods.csv — run ./update-mods.sh first"
    continue
  fi
  install_lovely "$name" "$version" "$url"
done < <(csv_rows)
echo

title "Mods  (Mods directory)"
while IFS=',' read -r name type repo ref folder version url; do
  case "$type" in
    injector) continue ;;
    mod) ;;
    *) record_fail "$name: unknown type '$type' in mods.csv"; continue ;;
  esac
  if [ -z "$version" ] || [ -z "$url" ]; then
    record_fail "$name: no resolved version in mods.csv — run ./update-mods.sh first"
    continue
  fi
  install_source_mod "$name" "$folder" "$version" "$url"
done < <(csv_rows)

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

${C_BOLD}One-time Steam setup (REQUIRED — without it, mods will NOT load):${C_RESET}
  1. In Steam, right-click ${C_BOLD}Balatro${C_RESET} > ${C_BOLD}Properties${C_RESET} > ${C_BOLD}General${C_RESET}.
  2. In ${C_BOLD}Launch Options${C_RESET}, paste exactly:
       ${C_BOLD}WINEDLLOVERRIDES="version=n,b" %command%${C_RESET}
     This tells Proton to load Lovely's version.dll. You only set it once.
  3. Launch ${C_BOLD}Balatro${C_RESET} normally from Steam — Lovely injects automatically.

${C_DIM}Notes:
  - In Game Mode the launch option is set the same way (gear icon > Properties).
  - Balatro must have been launched once through Steam (Proton) for the Mods
    folder to exist; this run found it, so you're set.
  - Amulet replaces Talisman (big-number scaling). Don't also install Talisman.
  - Cryptid requires Steamodded + Amulet (both included above).
  - Versions come from mods.csv; refresh it with ./update-mods.sh (and re-copy
    both files to the Deck) to pick up new releases.${C_RESET}
EOF
fi

[ "$N_FAIL" = 0 ] || exit 1
exit 0
