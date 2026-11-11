#!/bin/bash
# Chromium Keychain Rescue: recover Chromium-family browser passwords on macOS.
# The script NEVER replaces your active Keychain or modifies the source backup.

# Apple's system Bash 3.2 treats an initialized-but-empty array as unbound
# with `set -u`. Source/profile arrays start empty by design, so avoid nounset.
set -eo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash chromium-keychain-rescue.sh --backup-root "/path/to/ONE Time Machine snapshot/user folder"

  bash chromium-keychain-rescue.sh --backup-root "/path/to/extracted/browser" \
    --browser brave

  bash chromium-keychain-rescue.sh --profile "/path/to/Profile 4" \
    --keychain "/path/to/old-login.keychain-db" --browser brave

Options:
  --backup-root DIR  Find browser profiles and matching old Keychain under DIR.
                     Use a SINGLE snapshot or extracted backup, not a whole disk.
  --profile DIR      Restore just one profile (requires --keychain).
  --keychain FILE    Select the legacy .keychain-db explicitly.
  --browser NAME     Browser for an unrecognized/extracted folder or --profile:
                     brave, chrome, chromium, edge, vivaldi, opera, arc.
  --app PATH         Override the application for a single detected browser.
  --apps-dir DIR     Directory containing browser .app bundles (default /Applications).
  -h, --help         Print this message.

All profiles with saved logins are opened SEQUENTIALLY in isolated test sessions.
Quit each test browser with Cmd+Q to advance. The original Keychain search
order is restored after the final browser quits.
USAGE
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

backup_root=''
single_profile=''
old_keychain=''
browser_hint=''
app_override=''
apps_dir='/Applications'

while (( $# > 0 )); do
  case "$1" in
    --backup-root|--profile|--keychain|--browser|--app|--apps-dir)
      (( $# >= 2 )) || fail "Missing value for $1"
      case "$1" in
        --backup-root) backup_root=$2 ;;
        --profile) single_profile=$2 ;;
        --keychain) old_keychain=$2 ;;
        --browser) browser_hint=$2 ;;
        --app) app_override=$2 ;;
        --apps-dir) apps_dir=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || fail 'macOS is required.'
[[ -n "$backup_root" || -n "$single_profile" ]] || { usage >&2; fail 'Specify --backup-root or --profile.'; }
[[ -z "$backup_root" || -z "$single_profile" ]] || fail 'Use either --backup-root or --profile, not both.'

case "$browser_hint" in
  ''|brave|chrome|chromium|edge|vivaldi|opera|arc) ;;
  *) fail "Unknown browser: $browser_hint" ;;
esac

for executable in security sqlite3 open find mktemp cp pgrep; do
  command -v "$executable" >/dev/null || fail "Required macOS tool missing: $executable"
done

if [[ -n "$backup_root" ]]; then
  [[ -d "$backup_root" ]] || fail "Backup directory not found: $backup_root"
  # Only scan an explicitly selected backup/snapshot, not a live filesystem root.
  case "$backup_root" in
    /|/Users|/Volumes|/System|/Library|/Applications|/private|/private/var)
      fail 'Select a specific snapshot or extracted backup folder, not a broad system directory.' ;;
  esac
  backup_root=$(cd "$backup_root" && pwd -P)
  if [[ "$backup_root" == "$HOME" || "$backup_root" == "$HOME/Library" || \
        "${backup_root%/*}" == '/Volumes' ]]; then
    fail 'Point --backup-root to a specific backup/snapshot, not your live home or the entire backup disk.'
  fi
fi

if [[ -n "$single_profile" ]]; then
  [[ -f "$single_profile/Login Data" ]] || fail "No Login Data in $single_profile"
  [[ -n "$old_keychain" ]] || fail '--profile requires --keychain.'
  single_profile=$(cd "$single_profile" && pwd -P)
fi

# Return the installed browser application path for a recognized browser.
browser_app() {
  case "$1" in
    brave) printf '%s' "$apps_dir/Brave Browser.app" ;;
    chrome) printf '%s' "$apps_dir/Google Chrome.app" ;;
    chromium) printf '%s' "$apps_dir/Chromium.app" ;;
    edge) printf '%s' "$apps_dir/Microsoft Edge.app" ;;
    vivaldi) printf '%s' "$apps_dir/Vivaldi.app" ;;
    opera) printf '%s' "$apps_dir/Opera.app" ;;
    arc) printf '%s' "$apps_dir/Arc.app" ;;
    *) return 1 ;;
  esac
}

# Classify a Login Data path. Unknown sources are never guessed silently.
detected_browser=''
detected_profile=''
classify_db() {
  local db=$1 folder root
  folder=${db%/Login Data}
  detected_profile=${folder##*/}
  if [[ "$detected_profile" == Default || "$detected_profile" == 'Profile '* ]]; then
    root=${folder%/*}
  else
    # Opera sometimes places Login Data directly in its profile root.
    root=$folder
    detected_profile=Default
  fi
  detected_browser=''
  case "$root" in
    */BraveSoftware/Brave-Browser|*/Brave-Browser) detected_browser=brave ;;
    */Google/Chrome) detected_browser=chrome ;;
    */Chromium) detected_browser=chromium ;;
    */Microsoft\ Edge) detected_browser=edge ;;
    */Vivaldi) detected_browser=vivaldi ;;
    */com.operasoftware.Opera) detected_browser=opera ;;
    */Arc/User\ Data) detected_browser=arc ;;
  esac
  if [[ -z "$detected_browser" && "$root" == "$backup_root" ]]; then
    # Common case: a user has extracted only a browser folder and renamed it.
    # Recognize suggestive names; otherwise require the explicit --browser hint.
    case "${root##*/}" in
      *Brave*|*brave*) detected_browser=brave ;;
      *Chrome*|*chrome*) detected_browser=chrome ;;
      *Chromium*|*chromium*) detected_browser=chromium ;;
      *Edge*|*edge*) detected_browser=edge ;;
      *Vivaldi*|*vivaldi*) detected_browser=vivaldi ;;
      *Opera*|*opera*) detected_browser=opera ;;
      *Arc*|*arc*) detected_browser=arc ;;
    esac
  fi
  if [[ -z "$detected_browser" && -n "$browser_hint" ]]; then
    # A hint applies to a single extracted root, or explicit --profile mode.
    if [[ -n "$single_profile" || "$root" == "$backup_root" ]]; then
      detected_browser=$browser_hint
    fi
  fi
}

source_dbs=()
source_labels=()
source_browsers=()
skipped_unknown=0

add_source_db() {
  local db=$1 existing
  classify_db "$db"
  if [[ -z "$detected_browser" ]]; then
    (( skipped_unknown += 1 ))
    return
  fi
  # Duplicate browser/profile combinations often indicate MULTIPLE snapshots or
  # users. Mixing them with one Keychain would give misleading results.
  for existing in "${source_labels[@]}"; do
    [[ "$existing" != "$detected_browser/$detected_profile" ]] || \
      fail "More than one $existing found. Narrow --backup-root to ONE snapshot/user."
  done
  source_dbs+=("$db")
  source_labels+=("$detected_browser/$detected_profile")
  source_browsers+=("$detected_browser")
}

if [[ -n "$single_profile" ]]; then
  [[ -n "$browser_hint" ]] || fail 'Specify --browser when using --profile.'
  add_source_db "$single_profile/Login Data"
else
  printf 'Scanning the selected backup for Chromium-family Login Data files...\n'
  while IFS= read -r -d '' db; do
    add_source_db "$db"
  done < <(find "$backup_root" -type f -name 'Login Data' -print0 2>/dev/null)
fi

(( ${#source_dbs[@]} > 0 )) || \
  fail 'No recognized browser profiles found. Try a narrower backup folder or --browser NAME for an extracted browser root.'

# Discover legacy login Keychains only within the user-selected backup tree.
if [[ -z "$old_keychain" ]]; then
  keychain_candidates=()
  while IFS= read -r -d '' item; do
    case "$item" in
      */old-login.keychain-db|*/Library/Keychains/login.keychain-db|*/login.keychain-db)
        keychain_candidates+=("$item") ;;
    esac
  done < <(find "$backup_root" -type f \( -name 'old-login.keychain-db' -o -name 'login.keychain-db' \) -print0 2>/dev/null)

  (( ${#keychain_candidates[@]} > 0 )) || \
    fail 'No legacy login.keychain-db found in backup. Specify --keychain FILE or restore that file from Time Machine.'
  if (( ${#keychain_candidates[@]} == 1 )); then
    old_keychain=${keychain_candidates[0]}
  else
    printf '\nSeveral legacy Keychains found. Choose the one from the SAME user/snapshot:\n'
    for (( i=0; i<${#keychain_candidates[@]}; i++ )); do
      printf '  %d) %s\n' "$((i+1))" "${keychain_candidates[i]}"
    done
    printf 'Number (or 0 to cancel): '
    IFS= read -r answer
    [[ "$answer" =~ ^[0-9]+$ ]] || fail 'Invalid selection.'
    (( answer >= 1 && answer <= ${#keychain_candidates[@]} )) || fail 'Cancelled or invalid selection.'
    old_keychain=${keychain_candidates[answer-1]}
  fi
fi

[[ -f "$old_keychain" ]] || fail "Legacy Keychain not found: $old_keychain"

# Never change search order while a normal Chromium-family browser is running.
for process_name in 'Brave Browser' 'Google Chrome' 'Chromium' 'Microsoft Edge' 'Vivaldi' 'Opera' 'Arc'; do
  if pgrep -x "$process_name" >/dev/null; then
    fail "Quit ALL browsers first (still running: $process_name)."
  fi
done

raw_search_list=$(security list-keychains -d user) || fail 'Could not read Keychain search list.'
[[ -n "$raw_search_list" ]] || fail 'User Keychain search list is empty.'
original_keychains=()
while IFS= read -r row; do
  row=${row#"${row%%[![:space:]]*}"}
  [[ "${row:0:1}" == '"' && "${row: -1}" == '"' ]] || fail 'Unexpected Keychain list format.'
  row=${row:1:${#row}-2}
  [[ -n "$row" ]] || fail 'Empty Keychain path.'
  original_keychains+=("$row")
done <<< "$raw_search_list"

test_keychains=("$old_keychain")
for item in "${original_keychains[@]}"; do
  [[ "$item" == "$old_keychain" ]] || test_keychains+=("$item")
done

tmp_base=${TMPDIR:-/tmp}
[[ -d "$tmp_base" ]] || fail "Temporary directory missing: $tmp_base"
test_dir=$(mktemp -d "${tmp_base%/}/chromium-keychain-rescue.XXXXXX") || fail 'Cannot make test directory.'

ready_labels=()
ready_apps=()
ready_dirs=()

for (( i=0; i<${#source_dbs[@]}; i++ )); do
  browser=${source_browsers[i]}
  app=$(browser_app "$browser") || fail "No application definition for $browser"
  if [[ -n "$app_override" ]]; then
    (( ${#source_dbs[@]} == 1 )) || fail '--app can only be used when exactly one profile is selected.'
    app=$app_override
  fi
  if [[ ! -d "$app" ]]; then
    printf 'SKIP %-24s app not installed: %s\n' "${source_labels[i]}" "$app"
    continue
  fi
  dest="$test_dir/session-$((i+1))/Default"
  mkdir -p "$dest"
  for suffix in '' '-wal' '-shm'; do
    if [[ -f "${source_dbs[i]}$suffix" ]]; then
      cp -p "${source_dbs[i]}$suffix" "$dest/"
    fi
  done
  count=$(sqlite3 -readonly -csv -noheader "$dest/Login Data" \
    'SELECT COUNT(*) FROM logins WHERE blacklisted_by_user = 0;' 2>/dev/null) || \
    fail "Cannot read copied database for ${source_labels[i]}"
  [[ "$count" =~ ^[0-9]+$ ]] || fail "Unexpected password count: $count"
  if (( count == 0 )); then
    printf 'SKIP %-24s no saved logins\n' "${source_labels[i]}"
    continue
  fi
  printf 'FOUND %-24s %d saved login(s)\n' "${source_labels[i]}" "$count"
  ready_labels+=("${source_labels[i]}")
  ready_apps+=("$app")
  ready_dirs+=("${dest%/Default}")
done

(( ${#ready_labels[@]} > 0 )) || \
  fail 'No installed browser with saved logins in the selected backup.'

printf '\nLegacy Keychain: %s\n' "$old_keychain"
printf 'Test copies: %s\n' "$test_dir"
printf 'The old Keychain will be searched first only DURING these recovery sessions.\n'
printf 'Your default Keychain and original backups will NOT be replaced.\n'
printf 'Launch %d isolated browser session(s)? Type YES: ' "${#ready_labels[@]}"
IFS= read -r confirmation
[[ "$confirmation" == YES ]] || { printf 'Cancelled without changing Keychain settings.\n'; exit 0; }

changed=0
restore() {
  if (( changed )); then
    if security list-keychains -d user -s "${original_keychains[@]}"; then
      printf '\nOriginal Keychain search order RESTORED.\n'
    else
      printf '\nWARNING: restore failed! Run this manually:\nsecurity list-keychains -d user -s' >&2
      printf ' %q' "${original_keychains[@]}" >&2
      printf '\n' >&2
    fi
  fi
  printf 'Isolated copies containing encrypted browser data remain in: %s\n' "$test_dir"
  printf 'Delete only these copies once you have securely saved recovered passwords.\n'
}
trap restore EXIT

# The original search list is snapshotted above. Mark before attempting write.
changed=1
security list-keychains -d user -s "${test_keychains[@]}"

for (( i=0; i<${#ready_labels[@]}; i++ )); do
  printf '\n[%d/%d] Recover %s\n' "$((i+1))" "${#ready_labels[@]}" "${ready_labels[i]}"
  printf 'Open the password manager in the test browser. Quit it with Cmd+Q to continue.\n'
  open -W -n -a "${ready_apps[i]}" --args \
    --user-data-dir="${ready_dirs[i]}" --no-first-run --disable-sync
done
