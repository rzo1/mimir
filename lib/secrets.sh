# shellcheck shell=bash
# Step "secrets": portable exports of private key material into $SECRETS_DIR (chmod 700).
# ~/.ssh, ~/.gnupg and ~/Library/Keychains are also part of the home mirror; these exports
# are the version-independent way to re-import them on another machine.

secrets_gpg() {
  have gpg || { info "gpg not installed, skipping"; return 0; }
  local dir="$SECRETS_DIR/gpg" fprs
  fprs=$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' | sort)
  if [ -z "$fprs" ]; then info "no GPG secret keys"; return 0; fi

  if [ "$FORCE_SECRETS" != 1 ] && [ -s "$dir/secret-keys.asc" ] && [ "$fprs" = "$(cat "$dir/fingerprints.txt" 2>/dev/null)" ]; then
    ok "GPG secret keys unchanged since last export (use --export-secrets to force)"
    return 0
  fi

  mkdir -p "$dir" && chmod 700 "$dir"
  info "exporting GPG keys – pinentry will ask for the passphrase of each secret key"
  gpg --armor --export >"$dir/public-keys.asc" 2>/dev/null
  gpg --export-ownertrust >"$dir/ownertrust.txt" 2>/dev/null
  if gpg --armor --export-secret-keys >"$dir/secret-keys.asc.tmp" && grep -q 'BEGIN PGP PRIVATE KEY BLOCK' "$dir/secret-keys.asc.tmp"; then
    mv "$dir/secret-keys.asc.tmp" "$dir/secret-keys.asc"
    printf '%s\n' "$fprs" >"$dir/fingerprints.txt"
    chmod 600 "$dir"/*
    ok "GPG: public-keys.asc, secret-keys.asc (still passphrase-protected), ownertrust.txt"
    # a revocation certificate per primary key, in case the passphrase is ever lost
    if [ -d "$SRC_HOME/.gnupg/openpgp-revocs.d" ]; then
      "$RSYNC" -a "$SRC_HOME/.gnupg/openpgp-revocs.d/" "$dir/revocation-certificates/" && ok "GPG revocation certificates copied"
    fi
  else
    rm -f "$dir/secret-keys.asc.tmp"
    err "GPG secret key export failed or was cancelled – re-run with --only secrets"
  fi
}

secrets_ssh() {
  [ -d "$SRC_HOME/.ssh" ] || return 0
  mkdir -p "$SECRETS_DIR/ssh" && chmod 700 "$SECRETS_DIR/ssh"
  # skip the agent socket dir, just keys/config/known_hosts
  if "$RSYNC" -a --exclude="agent/" --exclude="*.sock" "$SRC_HOME/.ssh/" "$SECRETS_DIR/ssh/" && chmod 700 "$SECRETS_DIR/ssh"; then
    ok "SSH: ~/.ssh copied ($(find "$SECRETS_DIR/ssh" -type f | wc -l | tr -d ' ') files)"
  else
    err "copying ~/.ssh failed"
  fi
}

# Certificates + private keys (e.g. code signing, client certs) as PKCS#12. macOS asks for an
# export passphrase and per-key permission in dialogs, hence opt-in only.
secrets_keychain_identities() {
  [ "$KEYCHAIN_IDENTITIES" = 1 ] || return 0
  local out="$SECRETS_DIR/keychain/login-identities.p12"
  mkdir -p "$SECRETS_DIR/keychain" && chmod 700 "$SECRETS_DIR/keychain"
  info "exporting keychain identities – confirm the macOS dialogs (choose an export password)"
  if security export -k login.keychain-db -t identities -f pkcs12 -o "$out"; then
    chmod 600 "$out"; ok "keychain identities → keychain/login-identities.p12"
  else
    err "keychain identity export failed"
  fi
}

run_secrets() {
  step "Secrets → $SECRETS_DIR"
  if [ "$DRY_RUN" = 1 ]; then info "(skipped in dry-run)"; return 0; fi
  mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
  secrets_gpg
  secrets_ssh
  secrets_keychain_identities
  info "login keychain (passwords) is mirrored as ~/Library/Keychains/login.keychain-db – see RESTORE.md"
}
