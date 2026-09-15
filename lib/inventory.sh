# shellcheck shell=bash
# Step "inventory": record what is installed/configured so the new machine can be rebuilt.
# Everything lands as plain text in $INV_DIR; the previous run is kept in $INV_DIR.previous.
# shellcheck disable=SC2016  # single-quoted snippets are expanded by the child bash in cap_sh on purpose

# cap FILE cmd args... — run cmd (if it exists) and store stdout+stderr in $INV_DIR/FILE
cap() {
  local out="$INV_DIR/$1"; shift
  have "$1" || return 0
  mkdir -p "$(dirname "$out")"
  with_timeout "${CAP_TIMEOUT:-300}" "$@" >"$out" 2>&1
  [ -s "$out" ] || rm -f "$out"
}

# cap_sh FILE 'shell snippet' — same, for multi-command sections
cap_sh() {
  local out="$INV_DIR/$1"
  mkdir -p "$(dirname "$out")"
  with_timeout "${CAP_TIMEOUT:-300}" /bin/bash -c "$2" >"$out" 2>&1
  [ -s "$out" ] || rm -f "$out"
}

inv_system() {
  cap system/sw_vers.txt sw_vers
  cap system/hardware-software.txt system_profiler SPHardwareDataType SPSoftwareDataType SPStorageDataType SPDisplaysDataType
  cap_sh system/names.txt 'for k in ComputerName LocalHostName HostName; do printf "%s: " $k; scutil --get $k 2>&1; done'
  cap_sh system/security.txt 'echo "## FileVault"; fdesetup status; echo "## SIP"; csrutil status; echo "## Gatekeeper"; spctl --status'
  cap_sh system/user.txt 'id; echo; dscl . -read "/Users/$USER" UserShell RealName NFSHomeDirectory; echo; echo "## Local users"; dscl . -list /Users | grep -v "^_"'
  cap system/power.txt pmset -g custom
  cap system/timemachine.txt tmutil destinationinfo
}

inv_homebrew() {
  have brew || return 0
  mkdir -p "$INV_DIR/homebrew"
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
  # Brewfile includes taps, formulae, casks, mas apps and VS Code extensions (restore: brew bundle install)
  with_timeout 600 brew bundle dump --force --file="$INV_DIR/homebrew/Brewfile" \
    >"$INV_DIR/homebrew/bundle-dump.log" 2>&1 || warn "brew bundle dump failed, see inventory/homebrew/bundle-dump.log"
  cap homebrew/formulae-versions.txt brew list --formula --versions
  cap homebrew/casks-versions.txt brew list --cask --versions
  cap homebrew/formulae-installed-on-request.txt brew leaves --installed-on-request
  cap homebrew/taps.txt brew tap
  cap homebrew/services.txt brew services list
  cap homebrew/config.txt brew config
}

inv_apps() {
  mkdir -p "$INV_DIR/apps"
  local casks="$INV_DIR/apps/.cask-apps.tsv"
  : >"$casks"
  if have brew && have jq; then
    brew info --cask --installed --json=v2 2>/dev/null | jq -r '
      .casks[] | .token as $t | (.artifacts // [])[]
      | select(type == "object" and has("app")) | .app[]
      | (if type == "string" then . elif type == "object" then (.target // empty) else empty end)
      | "\(split("/") | last)\t\($t)"' >"$casks" 2>/dev/null
  fi

  local tsv="$INV_DIR/apps/apps.tsv" app name ver id src tok
  printf 'name\tversion\tbundle_id\tsource\tpath\n' >"$tsv"
  for app in /Applications/*.app /Applications/*/*.app "$SRC_HOME"/Applications/*.app; do
    [ -d "$app" ] || continue
    name=$(basename "$app")
    ver=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist" 2>/dev/null || echo '?')
    id=$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || echo '?')
    tok=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$casks")
    if [ -n "$tok" ]; then src="brew-cask:$tok"
    elif [ -e "$app/Contents/_MASReceipt/receipt" ]; then src="app-store"
    elif case "$id" in com.apple.*) true ;; *) false ;; esac; then src="apple"
    else src="manual"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$ver" "$id" "$src" "$app" >>"$tsv"
  done
  rm -f "$casks"
  awk -F'\t' 'NR > 1 && $4 == "manual" { printf "%-45s %s\n", $1, $2 }' "$tsv" >"$INV_DIR/apps/REINSTALL-MANUALLY.txt"
  awk -F'\t' 'NR > 1 && $4 == "app-store" { printf "%-45s %s\n", $1, $2 }' "$tsv" >"$INV_DIR/apps/app-store.txt"
  cap apps/mas-list.txt mas list
  cap apps/system_profiler-applications.txt system_profiler SPApplicationsDataType -detailLevel mini
  cap_sh apps/usr-local-bin.txt "ls -la /usr/local/bin '$SRC_HOME/.local/bin' '$SRC_HOME/bin' 2>/dev/null"
  cap_sh apps/system-extensions.txt 'systemextensionsctl list; echo; kmutil showloaded --list-only 2>/dev/null | grep -v com.apple'
  SECTION_RESULT="$(($(wc -l <"$tsv") - 1)) apps, $(wc -l <"$INV_DIR/apps/REINSTALL-MANUALLY.txt" | tr -d ' ') not from brew/App Store → apps/REINSTALL-MANUALLY.txt"
}

inv_dev() {
  local h="$SRC_HOME"
  cap dev/npm-global.txt npm ls -g --depth=0
  cap dev/pnpm-global.txt pnpm ls -g
  cap dev/pipx.txt pipx list --short
  cap dev/uv-tools.txt uv tool list
  cap dev/uv-python.txt uv python list --only-installed
  cap dev/cargo-install.txt cargo install --list
  cap dev/rustup.txt rustup toolchain list
  cap dev/gh-extensions.txt gh extension list
  cap_sh dev/version-managers.txt "
    echo '## pyenv';   ls '$h/.pyenv/versions' 2>/dev/null
    echo '## nvm';     ls '$h/.nvm/versions/node' 2>/dev/null
    echo '## rvm';     ls '$h/.rvm/rubies' 2>/dev/null
    echo '## rbenv';   ls '$h/.rbenv/versions' 2>/dev/null
    echo '## sdkman';  for c in '${SDKMAN_DIR:-$h/.sdkman}'/candidates/*; do [ -d \"\$c\" ] && echo \"\$(basename \"\$c\"): \$(ls \"\$c\" | grep -v current | tr '\n' ' ')\"; done
    echo '## asdf/mise'; ls '$h/.asdf/installs' '$h/.local/share/mise/installs' 2>/dev/null
    echo '## go bin';  ls '${GOPATH:-$h/go}/bin' 2>/dev/null
    true"
  cap_sh dev/java.txt '/usr/libexec/java_home -V 2>&1; echo; ls -1 /Library/Java/JavaVirtualMachines "$HOME/Library/Java/JavaVirtualMachines" 2>/dev/null; true'
  cap_sh dev/xcode.txt 'xcode-select -p; xcodebuild -version 2>&1; pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>&1'
  cap_sh dev/editor-extensions.txt '
    for c in code cursor codium windsurf; do command -v $c >/dev/null && { echo "## $c"; $c --list-extensions --show-versions; }; done; true'
  cap_sh dev/jetbrains.txt "
    cd '$h/Library/Application Support/JetBrains' 2>/dev/null || exit 0
    for ide in */; do echo \"## \$ide\"; ls \"\$ide/plugins\" 2>/dev/null | sed 's/^/  /'; done"
  CAP_TIMEOUT=30 cap_sh dev/docker.txt '
    docker version --format "{{.Server.Version}}" >/dev/null 2>&1 || { echo "docker daemon not running – start Docker Desktop and re-run to list images/volumes"; exit 0; }
    echo "## images";     docker image ls
    echo "## containers"; docker ps -a
    echo "## volumes";    docker volume ls
    echo "## contexts";   docker context ls'
  # read the manifests on disk: works without a running "ollama serve"
  # manifests/<registry>/<namespace>/<model>/<tag>
  cap_sh dev/ollama-models.txt "cd '$h/.ollama/models/manifests' 2>/dev/null || exit 0
    find . -type f ! -name '.*' | awk -F/ '{ ns = \$(NF-2); print (ns == \"library\" ? \"\" : ns \"/\") \$(NF-1) \":\" \$NF }' | sort"
}

# Commits on local branches that no remote-tracking branch contains. Without any remote-tracking
# refs (restored backups, bundles, never fetched) every commit would count, so report "?" instead.
unpushed_commits() {
  if [ -z "$(git -C "$1" for-each-ref --count=1 refs/remotes 2>/dev/null)" ]; then
    echo '?'
  else
    git -C "$1" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' '
  fi
}

# All git working copies with local-only work: uncommitted changes, unpushed commits, stashes, no remote.
inv_git_repos() {
  have git || return 0
  local h="$SRC_HOME" all="$INV_DIR/dev/git-repos.tsv" attn="$INV_DIR/dev/git-repos-ATTENTION.txt" gitdir r
  mkdir -p "$INV_DIR/dev"
  printf 'repo\tbranch\tuncommitted\tunpushed_commits\tstashes\torigin\n' >"$all"
  find "$h" -maxdepth 6 \( -path "$h/Library" -o -path "$h/.Trash" -o -path "$h/.cache" -o -path "$h/.m2" \
      -o -path "$h/.gradle" -o -path "$h/.npm" -o -path "$h/.nvm" -o -path "$h/.rvm" -o -path "$h/.pyenv" \
      -o -path "$h/.oh-my-zsh" -o -path "$h/.cargo" -o -path "$h/.rustup" -o -path "$h/go" -o -path "$h/.sdkman" \
      -o -name node_modules -o -name .venv \) -prune -o -name .git -print -prune 2>/dev/null |
  while IFS= read -r gitdir; do
    r=$(dirname "$gitdir")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${r#"$h"/}" \
      "$(git -C "$r" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)" \
      "$(git -C "$r" status --porcelain 2>/dev/null | wc -l | tr -d ' ')" \
      "$(unpushed_commits "$r")" \
      "$(git -C "$r" stash list 2>/dev/null | wc -l | tr -d ' ')" \
      "$(git -C "$r" remote get-url origin 2>/dev/null || echo '-')"
  done >>"$all"
  awk -F'\t' '
    NR > 1 && ($3 > 0 || ($4 != "?" && $4 > 0) || $5 > 0 || $6 == "-") {
      printf "%-60s uncommitted=%s unpushed=%s stashes=%s origin=%s\n", $1, $3, $4, $5, $6 }
    NR > 1 && $4 == "?" && $3 == 0 && $5 == 0 && $6 != "-" { unknown[++n] = $1 }
    END {
      if (n) {
        print "\n# clean, but without remote-tracking branches, so unpushed commits cannot be determined"
        print "# (e.g. restored from a backup); run \"git fetch\" there to check:"
        for (i = 1; i <= n; i++) print unknown[i]
      }
    }' "$all" >"$attn"
  SECTION_RESULT="$(($(wc -l <"$all") - 1)) repos, $(grep -c 'uncommitted=' "$attn") with local-only work → dev/git-repos-ATTENTION.txt"
}

inv_config() {
  cap_sh config/defaults-domains.txt 'defaults domains | tr "," "\n" | sed "s/^ *//" | sort'
  cap config/defaults-read-all.txt defaults read
  cap_sh config/defaults-currentHost.txt 'defaults -currentHost read'
  cap config/launchctl-user.txt launchctl list
  cap_sh config/launch-agents-daemons.txt "ls -la '$SRC_HOME/Library/LaunchAgents' /Library/LaunchAgents /Library/LaunchDaemons /Library/PrivilegedHelperTools 2>&1"
  cap_sh config/crontab.txt 'crontab -l 2>&1'
  cap_sh config/shells.txt 'echo "SHELL=$SHELL"; cat /etc/shells'
  cap_sh config/network.txt '
    echo "## services"; networksetup -listallnetworkservices
    echo "## hardware ports"; networksetup -listallhardwareports
    for dev in $(networksetup -listallhardwareports | awk "/Wi-Fi|AirPort/ { getline; print \$2 }"); do
      echo "## preferred Wi-Fi networks ($dev)"; networksetup -listpreferredwirelessnetworks "$dev"
    done
    echo "## proxies"; scutil --proxy
    echo "## DNS"; scutil --dns | head -60
    echo "## /etc/hosts"; cat /etc/hosts'
  cap_sh config/printers.txt 'lpstat -p -d -v 2>&1'
  cap_sh config/fonts-installed.txt "ls -1 '$SRC_HOME/Library/Fonts' /Library/Fonts 2>/dev/null"
  cap_sh config/profiles.txt 'profiles status -type enrollment 2>&1; profiles list 2>&1'
}

inv_crypto() {
  cap_sh crypto/gpg.txt 'gpg --list-keys --keyid-format long; echo "## SECRET KEYS"; gpg --list-secret-keys --keyid-format long; echo "## card"; gpg --card-status 2>&1 | head -5'
  cap_sh crypto/ssh.txt "
    ls -la '$SRC_HOME/.ssh'
    echo '## fingerprints'; for k in '$SRC_HOME'/.ssh/*.pub; do [ -f \"\$k\" ] && ssh-keygen -lf \"\$k\"; done
    echo '## agent'; ssh-add -l 2>&1; true"
  cap_sh crypto/keychain.txt '
    echo "## keychains"; security list-keychains
    echo "## identities (cert + private key)"; security find-identity 2>&1
    echo "## certificates in login keychain"; security find-certificate -a 2>/dev/null | awk -F\" "/\"labl\"/ { print \$4 }" | sort -u'
}

# run_section "title" function — spinner while it runs; the function may set SECTION_RESULT
run_section() {
  SECTION_RESULT=""
  spin_start "$1"
  "$2"
  if [ -n "$SPIN_PID" ]; then
    # shellcheck disable=SC2034  # read by spin_stop in common.sh
    SPIN_MSG="$1${SECTION_RESULT:+: $SECTION_RESULT}"
    spin_stop
  else
    spin_stop
    [ -z "$SECTION_RESULT" ] || ok "$SECTION_RESULT"
  fi
}

run_inventory() {
  step "Inventory → $INV_DIR"
  if [ "$DRY_RUN" = 1 ]; then info "(skipped in dry-run)"; return 0; fi
  if [ -d "$INV_DIR" ]; then
    rm -rf "$INV_DIR.previous" && mv "$INV_DIR" "$INV_DIR.previous"
  fi
  mkdir -p "$INV_DIR"
  printf 'Inventory of %s (%s), taken %s\n' "$HOST" "$(sw_vers -productVersion)" "$(date)" >"$INV_DIR/README.txt"
  run_section "system info" inv_system
  run_section "Homebrew (Brewfile, formulae, casks, taps, services)" inv_homebrew
  run_section "applications (source: brew cask / App Store / manual)" inv_apps
  run_section "developer toolchains (npm, pipx, uv, JDKs, IDE plugins, Docker, Ollama)" inv_dev
  run_section "git repositories (looking for unpushed work)" inv_git_repos
  run_section "macOS settings, launch agents, network, printers" inv_config
  run_section "keys & certificates (fingerprints only, no secrets)" inv_crypto
  ok "inventory written ($(du -sh "$INV_DIR" | cut -f1))"
}
