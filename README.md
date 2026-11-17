# Git Tag Sync

[日本語](README.ja.md)

A small macOS tool that keeps a Finder tag named **Git** on every folder that is a Git repository, and removes it from folders that no longer are. It runs every day from launchd, and a small app shows the result.

Select the "Git" tag in the Finder sidebar to see every repository on your Mac.

> The app's interface and the messages are in Japanese.

## How it works

- Searches your home folder for folders that contain `.git` (a directory or a file) and adds the "Git" tag to them.
- Removes the tag from tagged folders that no longer contain `.git`.
- Never searches, tags or untags inside the excluded folders (`excludes.txt`) or inside folders whose names start with `.` (tools keep many internal repositories there, such as editor or AI tool history and `~/.nvm`).
- Uses the [tag](https://github.com/jdberry/tag) command to change Finder tags.

## Requirements

- macOS 14 or later
- Command Line Tools (`swiftc`; `xcode-select --install`)
- `tag` (`brew install tag`)
- Xcode, only if you edit the icon

## Install

```bash
git clone https://github.com/zerollpaper/git-tag-sync.git
cd git-tag-sync
zsh install.sh                       # sync every day at 10:00
zsh install.sh --hour 9 --minute 30  # or choose the time
```

`install.sh`:

1. builds `~/Applications/Git Tag Sync.app`,
2. (re)creates the launchd job `local.git-tag-sync` (`~/Library/LaunchAgents/local.git-tag-sync.plist`),
3. creates `excludes.txt` from `excludes.example.txt` if it does not exist (it excludes only `~/Library` at first).

Then open System Settings > Privacy & Security > **Full Disk Access** and add `~/Applications/Git Tag Sync.app` with the "+" button. Without it, folders such as Documents, Desktop and Downloads cannot be searched.

The script runs from the folder you cloned, so run `install.sh` again if you move it.

### Why an app

A shell started directly by launchd has nothing to grant Full Disk Access to, so it cannot read protected folders. When Git Tag Sync.app starts the script, the permission given to the app also applies to its child processes (`zsh`, `find`).

### Code signing

macOS records Full Disk Access against the app's code signature.

- **If your keychain has a code signing certificate** (named "Local Code Signing" by default; set `GIT_TAG_SYNC_SIGN_ID` to use another), the app is signed with it. macOS then identifies the app by its identifier and certificate, so the permission survives reinstalls.
- **Otherwise the app is signed ad hoc.** macOS then identifies it by a hash of its contents, so after every reinstall you have to remove the app from the Full Disk Access list with "−" and add it again with "+" (an entry that is still switched on belongs to the old signature).

To create a self-signed certificate (valid for 10 years):

```bash
D=$(mktemp -d) && cd "$D"
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Local Code Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cert.cnf
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf -keyout key.pem -out cert.pem
PW=$(openssl rand -hex 16)
openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -inkey key.pem -in cert.pem -name "Local Code Signing" -out id.p12 -passout "pass:$PW"
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
cd / && rm -rf "$D"
```

The legacy `-certpbe`/`-keypbe`/`-macalg` options are needed because the keychain cannot import the default format of OpenSSL 3 and later. `security find-identity -p codesigning` lists the certificate with `CSSMERR_TP_NOT_TRUSTED`; that does not matter for signing or for Full Disk Access.

## Usage

The app has three tabs:

- **前回の結果 (Last run)**: status, time, counts (kept, tagged, untagged), the folders that changed, warnings and the log of that run. If some folders could not be read, it points you to Full Disk Access.
- **タグ付きのフォルダ (Tagged folders)**: every folder that currently has the "Git" tag (found with Spotlight). Reveal it in Finder or exclude it.
- **除外するフォルダ (Excluded folders)**: the search scope and the excluded folders. Add folders with "フォルダを追加…" and remove them with "−". **Excluding a folder removes the "Git" tag from it and from everything inside it.** After you remove an exclusion, the repositories inside are tagged at the next sync.

At the bottom: the next scheduled run, "ログ全体を開く" (open the full log in Console) and "今すぐ同期" (sync now).

### `excludes.txt`

One folder per line (`~` is allowed). Blank lines and lines starting with `#` are ignored. You can edit it by hand; tags inside a folder you add by hand are not removed, so run `git-tag-sync.sh --untag <folder>` if you want that.

`~/Library` contains a very large number of folders and takes most of the search time. Keep it excluded unless you keep repositories there.

### Command line

```bash
zsh git-tag-sync.sh --dry-run        # show what would change
zsh git-tag-sync.sh                  # sync
zsh git-tag-sync.sh --quiet          # do not print unchanged (KEEP) folders
zsh git-tag-sync.sh --untag ~/foo    # only remove the tag from ~/foo and everything inside
launchctl kickstart gui/$(id -u)/local.git-tag-sync   # run the scheduled job now
```

The log is appended to `~/Library/Logs/git-tag-sync.log`. The last result is saved to `~/Library/Application Support/Git Tag Sync/last-run.json`.

## Uninstall

```bash
zsh uninstall.sh
```

This removes the launchd job, the app and the saved result. It keeps this folder, the log and the tags. To remove the tags as well, run `zsh git-tag-sync.sh --untag ~` first. Remove the app from the Full Disk Access list with "−".

## Files

| File | Purpose |
|---|---|
| `git-tag-sync.sh` | The sync script (zsh) |
| `excludes.example.txt` | Example exclusions, copied to `excludes.txt` by `install.sh` |
| `Sources/main.swift` | The app. With `--run` it runs the script without a window and saves the result; opened normally it shows the result window |
| `install.sh` / `uninstall.sh` | Install and uninstall |
| `VERSION` / `CHANGELOG.md` | The version (shown by `git-tag-sync.sh --version` and in the app) and the changes |
| `GitTagSync.icon` | The icon (Icon Composer format), with dark, clear and tinted variants |
| `Resources/` | The compiled icon. Run `tools/build-icon.sh` (needs Xcode) after editing `GitTagSync.icon` |

## License

MIT
