#!/bin/bash
# Test harness: registration, assertions, logging and cleanup.
#
# Cases are `test_*` functions sourced from run.sh and run in declaration
# order, each in its own subshell so a `set -e` abort in one case cannot
# kill the runner.
#
# A case fails via an assert helper (exit 1) or non-zero return; `skip
# <reason>` exits 77 and is reported separately, not as a failure.

SKIP_RC=77

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_TESTS=()

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_BOLD=$'\033[1m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD=''
fi

log()  { printf '      %s\n' "$*"; }
info() { printf '      %s%s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
warn() { printf '      %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }

fail() {
  printf '      %sassertion failed:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

skip() {
  printf '      %sskipped:%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
  exit "$SKIP_RC"
}

# --- assertions --------------------------------------------------------

assert_eq() {
  # assert_eq <expected> <actual> <description>
  [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
  log "ok: $3"
}

assert_ne() {
  [ "$1" != "$2" ] || fail "$3: expected value to differ from '$1'"
  log "ok: $3"
}

assert_contains() {
  # assert_contains <haystack> <needle> <description>
  case "$1" in
    *"$2"*) log "ok: $3" ;;
    *) fail "$3: '$2' not found in: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3: '$2' unexpectedly present in: $1" ;;
    *) log "ok: $3" ;;
  esac
}

assert_matches() {
  # assert_matches <text> <extended-regex> <description>
  if printf '%s' "$1" | grep -Eq -- "$2"; then
    log "ok: $3"
  else
    fail "$3: no match for /$2/ in: $1"
  fi
}

assert_file() {
  [ -f "$1" ] || fail "${2:-file missing}: $1"
  log "ok: ${2:-file exists}: $1"
}

assert_executable() {
  [ -x "$1" ] || fail "${2:-not executable}: $1"
  log "ok: ${2:-executable}: $1"
}

assert_dir() {
  [ -d "$1" ] || fail "${2:-directory missing}: $1"
  log "ok: ${2:-directory exists}: $1"
}

assert_json() {
  # assert_json <file> <description>
  jq empty <"$1" 2>/dev/null || fail "$2: $1 is not valid JSON"
  log "ok: $2"
}

assert_cmd() {
  # assert_cmd <description> <command...>
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    log "ok: $desc"
  else
    fail "$desc: command failed (\`$*\`): $out"
  fi
}

assert_cmd_fails() {
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    fail "$desc: command unexpectedly succeeded (\`$*\`): $out"
  else
    log "ok: $desc"
  fi
}

assert_mountpoint() {
  # assert_mountpoint <path> <expected fstype>
  local path="$1" want="$2" got
  mountpoint -q "$path" || fail "$path is not a mountpoint"
  got="$(findmnt -n -o FSTYPE --target "$path" | head -1)"
  [ "$got" = "$want" ] || fail "$path: expected fstype '$want', got '$got'"
  log "ok: $path mounted as $want"
}

# retry_until <timeout-seconds> <description> <command...>
retry_until() {
  local timeout="$1" desc="$2"; shift 2
  local deadline=$((SECONDS + timeout)) last=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    if last="$("$@" 2>&1)"; then
      log "ok: $desc"
      return 0
    fi
    sleep 1
  done
  fail "$desc: still failing after ${timeout}s: $last"
}

# --- runner ------------------------------------------------------------

# run_case <function-name>
run_case() {
  local fn="$1" start elapsed rc
  printf '  %s%s%s\n' "$C_BOLD" "$fn" "$C_RESET"
  start=$SECONDS
  # Subshell: an abort inside the case must not kill the runner.
  ( set -eu; "$fn" )
  rc=$?
  elapsed=$((SECONDS - start))
  case "$rc" in
    0)
      PASS_COUNT=$((PASS_COUNT + 1))
      printf '  %sPASS%s %s (%ss)\n\n' "$C_GREEN" "$C_RESET" "$fn" "$elapsed"
      ;;
    "$SKIP_RC")
      SKIP_COUNT=$((SKIP_COUNT + 1))
      printf '  %sSKIP%s %s\n\n' "$C_YELLOW" "$C_RESET" "$fn"
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("$fn")
      printf '  %sFAIL%s %s (%ss)\n\n' "$C_RED" "$C_RESET" "$fn" "$elapsed"
      ;;
  esac
}

print_summary() {
  local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
  printf '%s=== summary ===%s\n' "$C_BOLD" "$C_RESET"
  printf '  total   %d\n' "$total"
  printf '  %spassed  %d%s\n' "$C_GREEN" "$PASS_COUNT" "$C_RESET"
  printf '  %sfailed  %d%s\n' "$C_RED" "$FAIL_COUNT" "$C_RESET"
  printf '  %sskipped %d%s\n' "$C_YELLOW" "$SKIP_COUNT" "$C_RESET"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '\n  failing cases:\n'
    printf '    - %s\n' "${FAILED_TESTS[@]}"
    return 1
  fi
  return 0
}
