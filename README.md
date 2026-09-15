# Mímir

[![CI](https://github.com/rzo1/mimir/actions/workflows/ci.yml/badge.svg)](https://github.com/rzo1/mimir/actions/workflows/ci.yml)

<img src="docs/logo.png" alt="Mímir logo" width="200" align="right">

> *Mímir, "the rememberer" — the wisest of the Æsir. When he was beheaded, Odin
> preserved his head with herbs and spells so that its knowledge would never be
> lost, and kept it at his side for counsel.*

Back up **everything important** of a Mac to an external disk — for the day the
machine goes away: returned to your employer, sold, or wiped for good. Mímir
mirrors your whole home folder including hidden files and configs, copies
system-wide configuration, exports your GPG and SSH keys, and writes an
inventory of everything installed, so you can rebuild the next machine.

No Time Machine: the result is plain files and folders you can open on any Mac.
Runs are **incremental**: run it again and only what changed is copied, so you
can back up today, keep working, and run it once more before you hand the
machine over.

Joins Odin's wolves [Freki](https://github.com/rzo1/freki) (back up
everything on GitLab) and [Geri](https://github.com/rzo1/geri) (clean it up
afterwards).

## What you get

```
/Volumes/<disk>/mimir/<computer-name>/
├── home/                   your home folder: dotfiles, ~/.config, ~/.ssh, projects, Library, …
├── system/                 /opt/homebrew/etc + var, /etc/hosts, /Library/LaunchDaemons, … at full path
├── inventory/
│   ├── homebrew/Brewfile   taps, formulae, casks, App Store apps → brew bundle install
│   ├── apps/               every app with version and source; REINSTALL-MANUALLY.txt
│   ├── dev/                npm, pipx, uv, JDKs, IDE plugins, Docker, Ollama; git-repos-ATTENTION.txt
│   ├── config/             defaults dump, launch agents, crontab, Wi-Fi, network, printers
│   ├── crypto/             GPG/SSH/keychain fingerprints (no secrets)
│   └── system/             macOS version, hardware, FileVault/SIP status
├── secrets/
│   ├── gpg/                secret + public keys (armored), ownertrust, revocation certificates
│   └── ssh/                copy of ~/.ssh
├── logs/                   run log, rsync log and error list per run
├── _removed/<timestamp>/   what --delete removed from the backup
├── RESTORE.md              how to get it all back
└── _tool/                  a copy of Mímir, runnable from the disk
```

## Requirements

- macOS (developed and tested on macOS 26, Apple Silicon); plain
  bash 3.2, nothing to build
- `rsync` 3 — `brew install rsync` (recommended; enables the progress display
  and preserves extended attributes, ACLs and creation dates. Without it
  macOS' built-in `openrsync` is used and Mímir offers to install rsync 3)
- optional: `gpg` (key export), `git` (unpushed-work report), `jq` (matching
  apps to Homebrew casks), Homebrew (Brewfile)
- **Full Disk Access** for the app you run Mímir from (Terminal, iTerm, your
  IDE): System Settings → Privacy & Security → Full Disk Access, then restart
  that app. Without it Mail, Messages, Safari, Notes and app containers are
  skipped
- an external disk, ideally formatted **APFS (Encrypted)**: the backup contains
  private keys, keychains and browser sessions
- **no sudo** — run it as the user whose data you want to keep

`mimir --check` verifies all of this (and the disk, if you pass one) without
copying anything; every run does the same checks first.

## Installation

```bash
git clone https://github.com/rzo1/mimir.git
cd mimir
brew install rsync      # recommended
./mimir --check
```

## Usage

```bash
./mimir
```

Without a destination Mímir lists the connected disks (Time Machine, snapshots
and system volumes are hidden) and asks which one to use:

```
Choose the destination disk:

    #   Volume                        Size      Free  FS     Connection  Encrypted Last Mímir run
    1)  data                      931,5 GB  931,3 GB  apfs   USB         no        -
    2)  Backup SSD                  2,0 TB    1,2 TB  apfs   Thunderbolt yes       2026-09-15 08:43

    Destination [1-2, q to quit]:
```

Then it checks requirements and the disk, shows the plan, asks once, and runs
all steps. Or pass the disk directly: `./mimir /Volumes/data`.

### Recommended workflow

```bash
./mimir -n /Volumes/data                 # 1. dry run: what would be copied, and how much
./mimir /Volumes/data                    # 2. first full run (hours for a full Mac)
./mimir /Volumes/data                    # 3. whenever you like: only the delta
./mimir --delete --verify /Volumes/data  # 4. last day: exact mirror + checksum comparison
```

- Keep using the Mac between runs; the next run picks up what changed.
- Interrupting is safe (Ctrl-C, closing the lid, unplugging the disk): run the
  same command again and it continues. Partially copied large files resume.
- Before the final run, quit what writes constantly (Docker, databases, IDEs,
  Mail, browsers), so their data is copied in a consistent state.
- The Mac is kept awake while Mímir runs. Plug in the power adapter.

### Progress

```
==> [3/4] Home folder  /Users/you/  →  /Volumes/data/mimir/MacBook_Pro/home/
    found 5.24M files in 5m42s
    ████████░░░░░░░░░░░░  40.2% │ files 2.11M/5.24M (1.3k/s) │ 115.20G copied │ 110.25MB/s │ 27m10s │ ETA 40m27s
```

- Steps are numbered; inventory sections and the checksum comparison show a
  spinner with elapsed time.
- The copy scans all files first; percentage, bar and ETA are based on files
  checked out of that total (rsync needs roughly 1–2 GB of RAM for millions of
  files). On a re-run most files are already there, so progress moves fast
  while little data is copied.
- Folders with many tiny files (`~/.m2`, `node_modules`, generated docs) are
  slow on external disks: every file costs several writes, whatever its size.
- `./mimir --status /Volumes/data` follows a running backup from another
  terminal.
- A macOS notification tells you when a run finished or failed.
- Only one run per backup at a time.

### Options

| Option                  | Description                                                                 |
|-------------------------|-----------------------------------------------------------------------------|
| `-n`, `--dry-run`       | Show what would be transferred; copy nothing                                |
| `--delete`              | Exact mirror: files gone from the Mac are removed from the backup (moved to `_removed/<timestamp>/`, not deleted) |
| `--verify`              | Compare the home mirror with the Mac by checksum after copying              |
| `--only STEPS`          | Run only these steps, e.g. `--only inventory,secrets`                       |
| `--skip STEPS`          | Skip steps, e.g. `--skip secrets`                                           |
| `--export-secrets`      | Re-export GPG keys even if they are unchanged since the last run            |
| `--keychain-identities` | Also export certificates with private keys from the login keychain (`.p12`) |
| `--excludes FILE`       | Exclude list for the home mirror (default: `excludes.txt`)                  |
| `--system-paths FILE`   | Paths for the system step (default: `system-paths.txt`)                     |
| `--status`              | Follow a running backup                                                     |
| `--check`               | Only check requirements and the destination                                 |
| `-y`, `--yes`           | Answer all questions with yes (never installs software)                     |
| `--allow-internal`      | Allow a destination on the internal disk (testing only)                     |

## What is backed up

| Step        | Default | Result                                                                   |
|-------------|---------|--------------------------------------------------------------------------|
| `inventory` | on      | `inventory/` — what is installed and configured, as plain text           |
| `secrets`   | on      | `secrets/` — GPG key export and a copy of `~/.ssh`                        |
| `home`      | on      | `home/` — your home folder with hidden files, symlinks, hard links, permissions, extended attributes, creation dates and ACLs |
| `system`    | on      | `system/` — the paths listed in `system-paths.txt`                        |
| `verify`    | off     | checksum comparison of `home/` with the Mac (`--verify`)                  |

### Inventory

| File                              | Content                                                            |
|-----------------------------------|--------------------------------------------------------------------|
| `homebrew/Brewfile`               | taps, formulae, casks, App Store apps, VS Code extensions          |
| `apps/apps.tsv`                   | all apps with version, bundle id and source (Homebrew cask, App Store, Apple, manual) |
| `apps/REINSTALL-MANUALLY.txt`     | apps that came from neither Homebrew nor the App Store             |
| `dev/`                            | npm -g, pnpm, pipx, uv, cargo, pyenv/nvm/rvm/sdkman versions, JDKs, Xcode, VS Code/Cursor and JetBrains plugins, Docker images/containers/volumes, Ollama models |
| `dev/git-repos-ATTENTION.txt`     | git repositories with uncommitted changes, unpushed commits, stashes or no remote |
| `config/`                         | `defaults` dump, launch agents and daemons, crontab, shells, network services, preferred Wi-Fi networks, proxies, DNS, printers, fonts, profiles |
| `crypto/`                         | GPG, SSH and keychain fingerprints and names                        |
| `system/`                         | macOS version, hardware, FileVault/SIP/Gatekeeper, users, power     |

The git repositories themselves are part of the home mirror;
`git-repos-ATTENTION.txt` tells you what to push before the Mac is gone.
Repositories without remote-tracking branches (e.g. mirrors restored from a
backup) show `unpushed=?` and are listed separately.

### Keys

- GPG secret keys are exported with `gpg --export-secret-keys` and stay
  protected by their passphrase; pinentry asks for it once per key. Later runs
  skip the export while your keys are unchanged.
- `~/.ssh`, `~/.gnupg` and `~/Library/Keychains` are also in the home mirror.
  Local keychain passwords can be imported from the mirrored
  `login.keychain-db` with your old login password (see `RESTORE.md`).

### Not backed up

Configured in [`excludes.txt`](excludes.txt) — comment a line out to include it:

- caches (`~/Library/Caches`, `~/.cache`, app container caches, Gradle and npm
  caches, Xcode DerivedData, Spotlight index)
- system-managed data that cannot be restored anyway
- `~/Library/CloudStorage` (OneDrive, Google Drive, Dropbox — the data lives in
  the cloud, and reading online-only files would download all of it)
- large and re-downloadable: the Trash, the Docker Desktop VM disk (**including
  Docker volumes** — export those first) and Ollama models

Files that iCloud has "optimized" away (Desktop & Documents sync, Photos with
*Optimize Mac Storage*) are placeholders on disk; reading them downloads them,
so the Mac needs free space and a network connection.

## Restoring

Everything is plain files. The backup contains a [`RESTORE.md`](RESTORE.md)
with the details; in short:

```bash
B=/Volumes/data/mimir/<computer-name>
brew bundle install --file="$B/inventory/homebrew/Brewfile"
rsync -a "$B/home/Documents/" ~/Documents/
rsync -a "$B/secrets/ssh/" ~/.ssh/ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/*
gpg --import "$B/secrets/gpg/secret-keys.asc"
gpg --import-ownertrust "$B/secrets/gpg/ownertrust.txt"
```

Don't copy the whole `home/Library` onto a new machine; take what you need.

## Before you hand the Mac over

1. Push what's listed in `inventory/dev/git-repos-ATTENTION.txt`.
2. Note licence keys for `inventory/apps/REINSTALL-MANUALLY.txt`.
3. Export Docker volumes you need
   (`docker run --rm -v VOL:/v -v "$PWD":/b alpine tar czf /b/VOL.tgz -C /v .`).
4. Stop or dump databases (`brew services stop postgresql@14`).
5. Final run: `./mimir --delete --verify /Volumes/data`; check `logs/*.errors.log`.
6. Spot-check the backup, ideally on another machine.
7. Deauthorize Music/TV and licence-bound apps.
8. Sign out of iMessage and FaceTime, then System Settings → *your name* →
   **Sign Out** (turns off Find My and Activation Lock).
9. System Settings → General → Transfer or Reset → **Erase All Content and
   Settings**.

## Troubleshooting

- **"N file(s) could not be copied"** — the first errors are printed, all of
  them are in `logs/rsync-<step>-<timestamp>.errors.log`. A few
  `Permission denied` entries for macOS internals (`FileProvider`,
  `secure-control-center-preferences`) are expected and harmless.
- **"some files vanished"** — files were deleted while being copied; normal on
  a running system.
- **Disk too small** — check `Total file size` in a dry run, then exclude more
  in `excludes.txt`.
- **"another Mímir run is writing to this backup"** — follow it with
  `--status`. A lock left behind by a crashed run is ignored automatically.

## Development

```
mimir                 entry point: options, checks, step loop, summary
lib/common.sh         output, confirmations, spinner, notifications
lib/requirements.sh   platform, tool and permission checks
lib/volumes.sh        destination picker, --status
lib/inventory.sh      inventory step
lib/secrets.sh        GPG / SSH / keychain export
lib/mirror.sh         rsync detection and options; home, system and verify steps
lib/progress.awk      rsync progress output → live progress line
tests/run.sh          test suite (plain bash)
```

```bash
tests/run.sh             # all tests; macOS-only tests are skipped elsewhere
tests/run.sh delete      # tests whose name contains "delete"
shellcheck -x mimir lib/*.sh tests/run.sh
pre-commit install       # shellcheck + whitespace hooks on commit
```

The tests build a small fake home folder and back it up into a temporary
directory (`MIMIR_SOURCE`, `--allow-internal`), covering the mirror, re-runs,
`--delete`, dry runs, verification, locking, the GPG export, the git report,
the volume filter and the progress renderer. CI runs them on macOS (with
rsync 3 and GnuPG) and Linux.

## License

[MIT](LICENSE)
