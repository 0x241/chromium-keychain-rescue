#!/bin/bash
# Verify the script refuses unsafe inputs before touching the real search list.
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd -P)
temp_parent=${TMPDIR:-/tmp}
[[ -d "$temp_parent" && -w "$temp_parent" ]] || temp_parent=$project_dir
fixture_root=$(mktemp -d "${temp_parent%/}/keychain-rescue-refusal.XXXXXX")
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf -- "$fixture_root"' EXIT
mock_bin="$project_dir/tests/mocks"
export MOCK_CURRENT_KEYCHAIN="$fixture_root/current.keychain-db"
export MOCK_SECURITY_LOG="$fixture_root/security.log"
export MOCK_OPEN_LOG="$fixture_root/open.log"
export TMPDIR="$fixture_root/temp"
mkdir -p "$TMPDIR" "$fixture_root/Applications/Brave Browser.app"

profile="$fixture_root/backup/Brave-Browser/Profile 4"
mkdir -p "$profile"
printf 'SIMULATED DATA\n' > "$profile/Login Data"
old_keychain="$fixture_root/backup/old-login.keychain-db"
printf 'SIMULATED KEYCHAIN\n' > "$old_keychain"

assert_rejected() {
  local label=$1 output
  shift
  : > "$MOCK_SECURITY_LOG"
  : > "$MOCK_OPEN_LOG"
  if output=$(printf 'YES\n' | env PATH="$mock_bin:$PATH" \
    bash "$project_dir/chromium-keychain-rescue.sh" "$@" 2>&1); then
    printf 'FAIL: %s unexpectedly succeeded.\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  [[ ! -s "$MOCK_SECURITY_LOG" && ! -s "$MOCK_OPEN_LOG" ]] || {
    printf 'FAIL: %s modified Keychain state or opened a browser.\n' "$label" >&2
    exit 1
  }
}

assert_rejected 'no arguments'
assert_rejected 'broad filesystem root' --backup-root /
assert_rejected 'missing Keychain' --profile "$profile" \
  --keychain "$fixture_root/nonexistent.keychain-db" --browser brave

export MOCK_RUNNING_PROCESS='Brave Browser'
assert_rejected 'existing browser running' --profile "$profile" \
  --keychain "$old_keychain" --browser brave
unset MOCK_RUNNING_PROCESS

# Two users with the same browser/profile must not be silently mixed.
duplicates="$fixture_root/two users"
for user in one two; do
  candidate="$duplicates/$user/Library/Application Support/Google/Chrome/Default"
  mkdir -p "$candidate"
  printf 'SIMULATED DATA\n' > "$candidate/Login Data"
done
assert_rejected 'duplicate browser profiles' --backup-root "$duplicates" \
  --keychain "$old_keychain"

# An empty profile must never open a session or change Keychain search order.
printf 'EMPTY\n' > "$profile/Login Data"
assert_rejected 'no saved logins' --profile "$profile" \
  --keychain "$old_keychain" --browser brave \
  --apps-dir "$fixture_root/Applications"

printf 'PASS: refuses unsafe roots, missing Keychains, running browsers, duplicates and empty logins.\n'
