#!/bin/bash
#
# update-mods.sh
#
# Resolve the latest version of every entry in mods.csv and rewrite its
# version/url columns. This is the ONLY place version discovery happens —
# the installers just read mods.csv and download. Typical flow:
#
#   ./update-mods.sh           # resolve latest versions, rewrite mods.csv
#   ./update-mods.sh --check   # report what would change, write nothing
#   git diff mods.csv          # review, then commit
#
# Resolution per record (see mods.csv for the record format):
#   ref = <branch>  -> latest commit SHA of that branch; url = source tarball
#   ref = @release  -> latest GitHub release tag;
#                      type "mod":      url = release source tarball
#                      type "injector": url = release-asset endpoint with an
#                                       {asset} placeholder the installers
#                                       fill per-platform
#
# Requirements: curl (stock). git is preferred for branch resolution
# (git ls-remote is not subject to GitHub's REST rate limit); without it the
# script falls back to the REST API (anonymous: 60 req/hr — set GITHUB_TOKEN
# to raise it).
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODS_FILE="$SCRIPT_DIR/mods.csv"

MODE="write"   # write | check

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --file) shift; MODS_FILE="${1:-}" ;;
    -h|--help)
      awk 'NR==1{next} /^#/{s=$0; sub(/^# ?/,"",s); print s; next} {exit}' "$0"
      exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Pretty output (mirrors the installers' style)
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
fail()  { printf '  %s[ERR]%s  %s\n'    "$C_RED"    "$C_RESET" "$*"; }
note()  { printf '         %s%s%s\n'    "$C_DIM"    "$*" "$C_RESET"; }

N_OK=0; N_UPD=0; N_FAIL=0
FAILED_LIST=""

# ---------------------------------------------------------------------------
# Resolution helpers (curl only, git preferred for branches)
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
    '') printf '%s' "(unset)" ;;
    *[!0-9a-f]*) printf '%s' "$1" ;;
    *) if [ ${#1} -gt 12 ]; then printf '%s' "${1:0:8}"; else printf '%s' "$1"; fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

[ -f "$MODS_FILE" ] || { fail "mods file not found: $MODS_FILE"; exit 1; }

USE_GIT=0
command -v git >/dev/null 2>&1 && USE_GIT=1

title "Resolving latest mod versions"
hr
note "mods file : $MODS_FILE"
if [ "$USE_GIT" = 1 ]; then
  note "resolve   : git ls-remote (not rate-limited)"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  note "resolve   : GitHub REST API (authenticated)"
else
  note "resolve   : GitHub REST API (anonymous, 60/hr — install git or set GITHUB_TOKEN if limited)"
fi
[ "$MODE" = "check" ] && note "mode      : check only (file will not be modified)"
hr

TMP="$MODS_FILE.tmp.$$"
: > "$TMP"
trap 'rm -f "$TMP"' EXIT INT TERM

while IFS= read -r line; do
  # Pass comments and blank lines through untouched.
  case "$line" in ''|\#*) printf '%s\n' "$line" >> "$TMP"; continue ;; esac

  IFS=',' read -r name type repo ref folder version url <<< "$line"

  new_version=""; new_url=""
  if [ "$ref" = "@release" ]; then
    new_version="$(resolve_release_tag "$repo")"
    if [ "$type" = "injector" ]; then
      new_url="https://github.com/$repo/releases/download/$new_version/{asset}"
    else
      new_url="https://github.com/$repo/archive/refs/tags/$new_version.tar.gz"
    fi
  else
    new_version="$(resolve_sha "$repo" "$ref")"
    new_url="https://github.com/$repo/archive/$new_version.tar.gz"
  fi

  if [ -z "$new_version" ]; then
    fail "$name: could not resolve $repo@$ref — network / rate limit? (keeping old value)"
    N_FAIL=$((N_FAIL+1)); FAILED_LIST="$FAILED_LIST $name"
    printf '%s\n' "$line" >> "$TMP"
    continue
  fi

  if [ "$new_version" = "$version" ] && [ "$new_url" = "$url" ]; then
    ok "$name ($(dispv "$version")) unchanged"
    N_OK=$((N_OK+1))
  else
    upd "$name $(dispv "$version") -> $(dispv "$new_version")"
    N_UPD=$((N_UPD+1))
  fi

  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$name" "$type" "$repo" "$ref" "$folder" "$new_version" "$new_url" >> "$TMP"
done < "$MODS_FILE"

echo
hr
if [ "$MODE" = "check" ]; then
  title "Check complete (mods.csv not modified)."
else
  mv "$TMP" "$MODS_FILE"
  trap - EXIT INT TERM
  title "Done — mods.csv updated."
fi
printf '  %sunchanged%s %d   %supdated%s %d   %sfailed%s %d\n' \
  "$C_GREEN" "$C_RESET" "$N_OK" \
  "$C_BLUE"  "$C_RESET" "$N_UPD" \
  "$C_RED"   "$C_RESET" "$N_FAIL"
[ -n "$FAILED_LIST" ] && note "failed:$FAILED_LIST"
if [ "$MODE" != "check" ] && [ "$N_UPD" -gt 0 ]; then
  note "review with:  git diff mods.csv   then commit."
fi
hr

[ "$N_FAIL" = 0 ] || exit 1
exit 0
