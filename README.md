# Chromium Keychain Rescue

**Recover saved passwords from macOS Time Machine backups of Chromium-family browsers using the original login Keychain — without replacing your current Keychain.**

> **Version 1.0.2.** The original procedure succeeded in a real-world **Brave / macOS Ventura → Tahoe** recovery (two encrypted passwords). Support for additional browsers and automatic discovery is still experimental and has only been exercised with simulated macOS tools. This is not affiliated with Apple, Google, Microsoft, Brave, Vivaldi, Opera, or Arc.

## Supported browser discovery

| Browser | Typical macOS backup directory | Application | Status |
| --- | --- | --- | --- |
| Brave | `Library/Application Support/BraveSoftware/Brave-Browser` | Brave Browser.app | **Recovery method verified once** |
| Google Chrome | `Library/Application Support/Google/Chrome` | Google Chrome.app | Experimental |
| Chromium | `Library/Application Support/Chromium` | Chromium.app | Experimental |
| Microsoft Edge | `Library/Application Support/Microsoft Edge` | Microsoft Edge.app | Experimental |
| Vivaldi | `Library/Application Support/Vivaldi` | Vivaldi.app | Experimental |
| Opera | `Library/Application Support/com.operasoftware.Opera` | Opera.app | Experimental; password layout may differ |
| Arc | `Library/Application Support/Arc/User Data` | Arc.app | Experimental; password layout may differ |

Chromium-based browsers share many profile/database conventions, **but are not identical**: they may use differently named Keychain secrets, permissions, profile layouts, or encryption versions. The tool only opens each browser's **own** application against **its own** copied `Login Data` database. It does not try to decrypt with a different browser's key, guess secrets, or bypass Keychain permissions.

Other Chromium forks can be tried with explicit `--profile`, `--keychain`, `--browser`, and `--app` options; the listed `--browser` identifiers are used to select the app. Compatibility is not guaranteed.

## Requirements

- macOS with the browser(s) to be recovered **installed** under `/Applications` (or specify `--app` in single-profile mode).
- An old Time Machine snapshot or extracted backup containing browser profile directories with `Login Data`.
- The original `login.keychain-db` **from that same macOS user and backup era**, opened as a separate Keychain in the **Keychain Access** application. It must be unlocked, and each browser must be permitted to access its old `… Safe Storage` item under **Access Control**.
- All regular Chromium-family browsers fully quit (`Cmd+Q`) before starting. No `sudo`.

**Never overwrite `~/Library/Keychains/login.keychain-db` with the old file.** Restore the old Keychain to a separate location and add/open it in Keychain Access first.

## Automatic recovery: one selected backup

Point `--backup-root` to **one particular snapshot's user-home folder** or to a folder containing extracted browser files and the legacy Keychain. Do not select the entire Time Machine disk with many snapshots and users.

```bash
bash chromium-keychain-rescue.sh \
  --backup-root "/Volumes/Time Machine/selected-snapshot/user-home-folder"
```

For a manually extracted folder such as `BraveBackup`, containing `Default`, `Profile 1`, and `old-login.keychain-db`:

```bash
bash chromium-keychain-rescue.sh \
  --backup-root "$HOME/Desktop/BraveBackup"
```

If the extracted folder name does not identify the browser, add `--browser brave` (or the appropriate browser). If multiple Keychains are found, the tool **asks you to select** the one from the same user/snapshot.

The script:

1. Searches only **inside your chosen backup folder** for the known Chromium profile `Login Data` databases and an old `login.keychain-db`.
2. Identifies each known browser/profile. If duplicate browser/profile names indicate multiple snapshots, it **stops** rather than silently combining them.
3. Creates isolated copies of databases (`Login Data` and its SQLite `-wal`/`-shm` sidecars). **No `Local State`, sync seed, preferences, extensions, or browsing history are imported.**
4. Counts saved logins and skips empty profiles or missing applications.
5. Shows the plan and asks for `YES` before changing any settings.
6. Saves the current **user Keychain search list**, then temporarily puts the old Keychain first. The default Keychain remains unchanged.
7. Opens each nonempty browser/profile **one at a time**. In each test window, open the browser's password manager and recover the needed logins. Close the test browser with `Cmd+Q` to advance to the next profile.
8. After all sessions finish (or on an ordinary script error), **restores the original Keychain search list**.

It does **not** automatically export passwords to a plaintext CSV.

## Single-profile mode

You can recover one known profile directly:

```bash
bash chromium-keychain-rescue.sh \
  --profile "/path/to/Brave-Browser/Profile 4" \
  --keychain "/path/to/old-login.keychain-db" \
  --browser brave
```

For a non-standard application location, also set `--app "/path/to/Browser.app"`.
For several browsers installed under a nonstandard parent directory, set `--apps-dir "/path/to/Applications"`.

## Safety notes — please read

- The recovery script is local: it contains no credential exfiltration or network upload logic. The launched browser itself may still make ordinary network requests; do not enable Sync in its test profile.
- The source Time Machine snapshot is **read only** for this script. Browsers modify only their isolated **copies**, which are retained temporarily to avoid accidental data loss.
- The Keychain search order is a **shared per-user setting**. Avoid opening other browsers or applications that use these Safe Storage entries until the script finishes and prints `Original Keychain search order RESTORED`.
- **Never close Terminal, reboot, or forcibly terminate the script while an isolated browser is running.** Forced termination, power loss, or logout may prevent the cleanup trap from running. To recover, use `security list-keychains -d user` and restore **your original** order with `security list-keychains -d user -s ...`.
- A prompt for your **current** macOS account password when revealing a saved login in the browser's UI is normal and separate from permissions for the **old** Keychain item.
- If an old Keychain refuses to unlock or a browser lacks permission to access its item, **stop and cancel**. The tool cannot and will not break the encryption or alter Keychain access controls.
- After recovery, use the printed test-folder path to delete **only that specific test copy** once you have safely saved the recovered credentials. Do not delete your original backups.
- If you manually export passwords as CSV, remember the resulting CSV contains **plaintext passwords**. Protect and remove it when no longer needed.

## Troubleshooting

**No browser profiles found.** Point `--backup-root` to a narrower **single user** folder within the Time Machine snapshot. For extracted folders with generic names, add `--browser brave`, etc. The tool deliberately ignores unrecognized folders.

**No old Keychain found.** Restore `~/Library/Keychains/login.keychain-db` from the same snapshot into a separate file, open it in Keychain Access, and pass `--keychain /path/to/old-login.keychain-db`.

**A browser was skipped.** Its corresponding `.app` may not be installed, or its database had no ordinary saved logins. The tool does not install applications.

**Passwords are still missing.** Some browsers and encryption versions use different storage mechanisms. Confirm the old Safe Storage item exists and trusts the same browser application. The tool cannot decrypt a database using a different Safe Storage key.

**Why sequential browser windows?** Running many browsers simultaneously while changing a shared Keychain search list increases the chance of accessing the wrong secret. Opening isolated sessions one at a time keeps the change scoped to a controlled recovery window.

## License

MIT — see [LICENSE](LICENSE).
