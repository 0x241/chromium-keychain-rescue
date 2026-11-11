#!/bin/bash
# Prevent accidental upload of browser databases, Keychains, or local user paths.
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$project_dir"

source_files=(
  .gitignore
  README.md LICENSE chromium-keychain-rescue.sh
  .github/workflows/shellcheck.yml
  .github/workflows/recovery-tests.yml
  .github/workflows/release.yml
  tests/unit_test.sh tests/refusal_test.sh tests/privacy_test.sh
  tests/mocks/uname tests/mocks/pgrep tests/mocks/sqlite3
  tests/mocks/security tests/mocks/open
)

# The maintainer-only publisher is present in the downloadable starter archive,
# but excluded from the public repository. Scan it when available.
if [[ -f publish.sh ]]; then
  source_files+=(publish.sh)
fi

for file in "${source_files[@]}"; do
  [[ -f "$file" ]] || { printf 'Missing expected source file: %s\n' "$file" >&2; exit 1; }
  [[ ! -L "$file" ]] || { printf 'Refusing symbolic link: %s\n' "$file" >&2; exit 1; }
done

grep -qx '/publish.sh' .gitignore || {
  printf 'ERROR: one-time publisher is not excluded from Git.\n' >&2
  exit 1
}
if grep -Rn 'publish\.sh' .github/workflows; then
  printf 'ERROR: published workflows still reference maintainer-only publisher.\n' >&2
  exit 1
fi

path_regex='(/User'
path_regex+='s/[^/[:space:]$]+/|/ho'
path_regex+='me/[^/[:space:]$]+/|/work'
path_regex+='space/scratch/|/private/var/'
path_regex+='folders/)'
if grep -nE "$path_regex" "${source_files[@]}"; then
  printf 'ERROR: possible private absolute home/build path in public source.\n' >&2
  exit 1
fi

if find . -type f \( -name 'Login Data' -o -name 'Login Data For Account' \
  -o -name '*.keychain' -o -name '*.keychain-db' -o -name '*.p12' \
  -o -name '*.pfx' -o -name '*.pem' -o -name '*.sqlite' \
  -o -name '*.sqlite3' -o -name '*.csv' \) -print | grep -q .; then
  printf 'ERROR: sensitive browser/Keychain files found in the project.\n' >&2
  exit 1
fi

printf 'PASS: no private absolute paths or sensitive backup files in the publication tree.\n'
