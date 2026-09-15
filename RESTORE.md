# Restoring from a Mímir backup

Layout of `mimir/<computer-name>/`:

| Folder        | Content                                                                 |
|---------------|-------------------------------------------------------------------------|
| `home/`       | Your complete home folder, hidden files included (minus `excludes.txt`) |
| `system/`     | `/opt/homebrew/etc`, `/opt/homebrew/var`, `/etc/hosts`, … at their full path |
| `inventory/`  | What was installed and configured (plain text)                          |
| `secrets/`    | GPG key export, `~/.ssh` copy, optional keychain `.p12`                 |
| `_removed/`   | Files that `--delete` removed or overwrote, per run (safe to delete)     |
| `inventory.previous/` | The inventory of the run before the last one                    |
| `logs/`       | Run log, rsync log and error list per run                               |
| `last-run.txt`| Date, steps, warnings and duration of the last run                      |
| `_tool/`      | A copy of Mímir, runnable from the disk: `_tool/mimir --help`           |

> Do **not** restore the whole `home/Library` onto a new Mac or a different macOS version.
> Copy back only what you need (files, dotfiles, specific app folders).

## 1. Software

```sh
# Homebrew: https://brew.sh, then taps + formulae + casks + App Store apps (mas) + VS Code extensions
brew bundle install --file=inventory/homebrew/Brewfile

# Apps that came from neither Homebrew nor the App Store
cat inventory/apps/REINSTALL-MANUALLY.txt
```

Toolchains: `inventory/dev/` (npm -g, pipx, uv tools, pyenv/nvm/rvm/sdkman versions, cargo,
JDKs, JetBrains plugins, Docker images, Ollama models).

## 2. Files and dotfiles

```sh
B=/Volumes/<disk>/mimir/<computer-name>
rsync -a  "$B/home/Documents/" ~/Documents/        # same for Desktop, Downloads, projects …
cp -a "$B"/home/.zshrc "$B"/home/.gitconfig ~/     # dotfiles you want
rsync -a "$B/home/.config/" ~/.config/
```

## 3. SSH keys

```sh
rsync -a "$B/secrets/ssh/" ~/.ssh/
chmod 700 ~/.ssh && chmod 600 ~/.ssh/* && chmod 644 ~/.ssh/*.pub ~/.ssh/known_hosts
```

## 4. GPG keys

```sh
gpg --import "$B/secrets/gpg/public-keys.asc"
gpg --import "$B/secrets/gpg/secret-keys.asc"          # asks for each key's passphrase
gpg --import-ownertrust "$B/secrets/gpg/ownertrust.txt"
gpg --list-secret-keys --keyid-format long             # check
```

Also copy `home/.gnupg/gpg.conf` and `gpg-agent.conf` if you customised them (the `pinentry-program`
path may differ).

## 5. Passwords / keychain

* iCloud Keychain syncs by itself once you sign in with your Apple Account.
* Local-only items: open **Keychain Access → File → Import Items…** and pick
  `home/Library/Keychains/login.keychain-db` (a copy!). It unlocks with the *old* Mac login
  password. From there drag items or view passwords individually.
* Certificates with private keys: `secrets/keychain/login-identities.p12` (if exported) → double-click.

## 6. App data

* Browsers: the profile folders are in `home/Library/Application Support/Google/Chrome`,
  `…/Firefox/Profiles`, `home/Library/Safari` — easiest is to sign in to browser sync instead.
* JetBrains settings: `home/Library/Application Support/JetBrains/<IDE>` → or use Settings Sync.
* Mail: `home/Library/Mail` (import via Mail → File → Import Mailboxes).
* Homebrew databases (e.g. PostgreSQL): `system/opt/homebrew/var/postgresql@<v>` – only works with
  the same major version; copy back while the service is stopped.
* macOS settings: `inventory/config/defaults-read-all.txt` for reference.
