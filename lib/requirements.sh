# shellcheck shell=bash
# Everything Mímir needs from the machine: platform, tools, permissions, power.

require_macos() {
  [ "$(uname -s)" = Darwin ] || die "Mímir backs up macOS machines and only runs on macOS (found $(uname -s))"
}

# tool_line NAME OK|MISSING "what it is used for" "how to get it"
tool_line() {
  case "$2" in
    OK)      ok "$1 – $3" ;;
    MISSING) warn "$1 missing – $3. Install: $4" ;;
  esac
}

check_requirements() {
  step "Requirements"

  # 1. tools that ship with macOS – if these are missing, PATH is broken
  local t missing=""
  for t in awk sed grep find stat df du tr wc diskutil mount caffeinate pmset plutil scutil sw_vers; do
    have "$t" || missing="$missing $t"
  done
  [ -z "$missing" ] || die "required macOS tools not found:$missing – check your PATH (it should contain /usr/bin:/bin:/usr/sbin:/sbin)"
  ok "macOS $(sw_vers -productVersion) with all built-in tools"

  # 2. rsync: required; version 3 strongly recommended
  detect_rsync
  if [ "$RSYNC_FLAVOR" = openrsync ]; then
    [ -x "$RSYNC" ] || die "no rsync found at all – install it with: brew install rsync"
    if has_any_step home system verify; then
      warn "rsync 3 not found, falling back to macOS' openrsync: no progress display, and extended" \
           "attributes (Finder tags, …), ACLs and creation dates are NOT preserved"
      # --yes accepts warnings but never installs software on its own
      if [ "$CHECK_ONLY" != 1 ] && have brew && [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ] &&
         confirm "Install rsync 3 now with 'brew install rsync'?"; then
        brew install rsync
        detect_rsync
      else
        info "install later with: brew install rsync"
      fi
    fi
  fi
  [ "$RSYNC_FLAVOR" = samba ] && ok "rsync $(printf '%s\n' "$RSYNC_VERSION" | sed -n '1s/^rsync *version \([^ ]*\).*/\1/p') ($RSYNC)"

  # 3. optional tools, only for the steps that use them
  if has_any_step secrets; then
    if have gpg; then ok "gpg – GPG key export"
    elif [ -d "$SRC_HOME/.gnupg" ]; then tool_line gpg MISSING "you have ~/.gnupg, but its keys cannot be exported (the folder itself is still mirrored)" "brew install gnupg"
    fi
  fi
  if has_any_step inventory; then
    if have git; then ok "git – report of unpushed work"
    else tool_line git MISSING "no report of repositories with unpushed work" "xcode-select --install"
    fi
    if have brew; then
      ok "brew – Brewfile and package lists"
      have jq || tool_line jq MISSING "apps cannot be matched to Homebrew casks" "brew install jq"
    else
      info "Homebrew not installed – no Brewfile (nothing to list)"
    fi
    have perl || tool_line perl MISSING "hanging tools (docker, ollama) cannot be timed out" "ships with macOS; check PATH"
  fi

  # 4. permissions and environment
  if head -c1 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; then
    ok "Full Disk Access granted"
  else
    warn "the app running Mímir has no Full Disk Access: Mail, Messages, Safari, Notes, Photos and" \
         "app containers will be skipped. Grant it in System Settings → Privacy & Security →" \
         "Full Disk Access (Terminal, iTerm, your IDE …), then restart that app."
    confirm "Continue without Full Disk Access?" || exit 1
  fi
  if pmset -g batt 2>/dev/null | grep -q "Battery Power"; then
    warn "running on battery – plug in the power adapter; the first run can take hours"
  fi
}

has_any_step() {
  local s
  for s in "$@"; do has_step "$s" && return 0; done
  return 1
}
