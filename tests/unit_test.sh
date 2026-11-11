#!/bin/bash
# Simulated macOS tests; fixtures contain no genuine passwords or Keychains.
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd -P)
temp_parent=${TMPDIR:-/tmp}
[[ -d "$temp_parent" && -w "$temp_parent" ]] || temp_parent=$project_dir
fixture_root=$(mktemp -d "${temp_parent%/}/keychain-rescue-unit.XXXXXX")
# On macOS, TMPDIR commonly uses /var, which resolves to /private/var.
# The recovery script canonicalizes --backup-root with pwd -P; do likewise
# here or our mock asserts that two spellings of the same path differ.
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf -- "$fixture_root"' EXIT

backup="$fixture_root/one snapshot"
apps="$fixture_root/Applications"
mock_bin="$project_dir/tests/mocks"
export MOCK_CURRENT_KEYCHAIN="$fixture_root/current.keychain-db"
export MOCK_EXTRA_KEYCHAIN="$fixture_root/another.keychain-db"
export MOCK_SECURITY_LOG="$fixture_root/security.log"
export MOCK_OPEN_LOG="$fixture_root/open.log"
export MOCK_OPEN_COUNT="$fixture_root/open-count"
export TMPDIR="$fixture_root/temp"
mkdir -p "$TMPDIR" "$backup/Library/Keychains"

old_keychain="$backup/Library/Keychains/login.keychain-db"
printf 'SIMULATED KEYCHAIN\n' > "$old_keychain"

make_profile() {
  local profile=$1 contents=$2
  mkdir -p "${profile%/*}"
  mkdir -p "$profile"
  printf '%s\n' "$contents" > "$profile/Login Data"
}

make_profile "$backup/Library/Application Support/BraveSoftware/Brave-Browser/Default" DATA
make_profile "$backup/Library/Application Support/BraveSoftware/Brave-Browser/Profile 4" DATA
make_profile "$backup/Library/Application Support/Google/Chrome/Profile 1" DATA
make_profile "$backup/Library/Application Support/Google/Chrome/Profile 2" EMPTY
mkdir -p "$apps/Brave Browser.app" "$apps/Google Chrome.app"

: > "$MOCK_SECURITY_LOG"
: > "$MOCK_OPEN_LOG"

if ! output=$(printf 'YES\n' | env PATH="$mock_bin:$PATH" \
  bash "$project_dir/chromium-keychain-rescue.sh" \
  --backup-root "$backup" --apps-dir "$apps" 2>&1); then
  printf 'FAILED normal recovery:\n%s\n' "$output" >&2
  exit 1
fi

[[ "$(grep -c '^OPEN' "$MOCK_OPEN_LOG")" == 3 ]] || {
  printf 'Expected three isolated browser sessions.\n' >&2
  exit 1
}
[[ "$(grep -c '^SET' "$MOCK_SECURITY_LOG")" == 2 ]] || {
  printf 'Expected one Keychain search change and one restore.\n' >&2
  exit 1
}

expected_first=$(printf 'SET\t%s\t%s\t%s' \
  "$old_keychain" "$MOCK_CURRENT_KEYCHAIN" "$MOCK_EXTRA_KEYCHAIN")
expected_last=$(printf 'SET\t%s\t%s' \
  "$MOCK_CURRENT_KEYCHAIN" "$MOCK_EXTRA_KEYCHAIN")
[[ "$(sed -n '1p' "$MOCK_SECURITY_LOG")" == "$expected_first" ]] || {
  printf 'Old Keychain was not prepended in correct order.\n' >&2
  exit 1
}
[[ "$(sed -n '2p' "$MOCK_SECURITY_LOG")" == "$expected_last" ]] || {
  printf 'Original Keychain search order was not restored.\n' >&2
  exit 1
}

# A failure in the second browser must still restore the exact search order.
: > "$MOCK_SECURITY_LOG"
: > "$MOCK_OPEN_LOG"
export MOCK_FAIL_OPEN_NUMBER=2
if output=$(printf 'YES\n' | env PATH="$mock_bin:$PATH" \
  bash "$project_dir/chromium-keychain-rescue.sh" \
  --backup-root "$backup" --apps-dir "$apps" 2>&1); then
  printf 'Expected simulated second-browser failure, got success.\n' >&2
  exit 1
fi
[[ "$(grep -c '^OPEN' "$MOCK_OPEN_LOG")" == 2 ]] || exit 1
[[ "$(sed -n '2p' "$MOCK_SECURITY_LOG")" == "$expected_last" ]] || {
  printf 'Original Keychain order not restored after browser error.\n' >&2
  exit 1
}

printf 'PASS: multi-profile recovery, empty profile skip, isolated sessions, restore on error.\n'
