# shellcheck shell=bash
# Steps "home", "system", "verify": incremental rsync mirror. Re-running only transfers the delta.

# Prefer rsync 3.x (Homebrew) over macOS' bundled openrsync: progress, log files, crtimes, ACLs.
detect_rsync() {
  local c
  if [ -n "$MIMIR_RSYNC" ]; then  # explicit override, e.g. MIMIR_RSYNC=/usr/bin/rsync to force openrsync
    RSYNC="$MIMIR_RSYNC"; RSYNC_VERSION=$("$RSYNC" --version 2>&1)
    case "$RSYNC_VERSION" in *"version 3."*) RSYNC_FLAVOR=samba ;; *) RSYNC_FLAVOR=openrsync ;; esac
    return 0
  fi
  for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync "$(command -v rsync)"; do
    [ -x "$c" ] || continue
    # read the full output first: with pipefail, "| head -1" would SIGPIPE rsync and fail the test
    RSYNC_VERSION=$("$c" --version 2>/dev/null)
    case "$RSYNC_VERSION" in
      *"version 3."*) RSYNC="$c"; RSYNC_FLAVOR=samba; return 0 ;;
    esac
  done
  RSYNC=/usr/bin/rsync; RSYNC_FLAVOR=openrsync
  RSYNC_VERSION=$("$RSYNC" --version 2>&1)
}

rsync_supports() {  # rsync_supports ACLs|xattrs|crtimes
  printf '%s\n' "$RSYNC_VERSION" | grep -E "(^|[ ,])$1(,|$| )" >/dev/null &&
    ! printf '%s\n' "$RSYNC_VERSION" | grep -E "no $1" >/dev/null
}

build_rsync_opts() {
  RSYNC_OPTS=(-a -H)
  local native=0
  case "$DEST_FS" in apfs|hfs) native=1 ;; esac
  if [ "$RSYNC_FLAVOR" = samba ]; then
    # --no-inc-recursive: scan everything first, so percentage, file count and ETA are real totals
    # shellcheck disable=SC2054  # the commas belong to --info
    RSYNC_OPTS+=(--no-specials --no-devices --human-readable --partial-dir=.rsync-partial
                 --no-inc-recursive --info=progress2,flist2,stats2,nonreg0)
    if [ "$native" = 1 ]; then
      # SIP/TCC-owned attributes can never be written by a normal user → would only produce errors
      rsync_supports xattrs && RSYNC_OPTS+=(-X --filter='-x com.apple.rootless' --filter='-x com.apple.macl')
      rsync_supports ACLs && RSYNC_OPTS+=(-A)
      rsync_supports crtimes && RSYNC_OPTS+=(-N)
    fi
  else
    # openrsync has no xattr/ACL support at all
    RSYNC_OPTS+=(--partial --stats)
  fi
  # FAT/exFAT have 2s timestamp resolution – without this every file looks changed on every run
  [ "$native" = 1 ] || RSYNC_OPTS+=(--modify-window=2)
  RSYNC_OPTS+=(--exclude=.rsync-partial/)
}

# run_rsync LABEL DEST SRC... (extra options via the EXTRA_OPTS array)
run_rsync() {
  local label="$1" dst="$2"; shift 2
  local log="$LOG_DIR/rsync-$label-$TS.log" errlog="$LOG_DIR/rsync-$label-$TS.errors.log" rc=0
  local opts
  opts=("${RSYNC_OPTS[@]}" "${EXTRA_OPTS[@]}")
  [ "$DRY_RUN" = 1 ] && opts+=(--dry-run)
  if [ "$DELETE" = 1 ]; then
    # true mirror, but whatever gets deleted or overwritten in the backup is parked in _removed/
    opts+=(--delete --backup --backup-dir="$HOST_DIR/_removed/$TS/$label")
  fi
  [ "$DRY_RUN" = 1 ] || mkdir -p "$dst"

  info "log: $log"
  if [ "$RSYNC_FLAVOR" = samba ]; then
    local tty=0 cols=80
    if [ -t 1 ]; then tty=1; cols=$(stty size </dev/tty 2>/dev/null | awk '{ print $2 }'); fi
    "$RSYNC" "${opts[@]}" --log-file="$log" --log-file-format='%i %n%L' "$@" "$dst" 2>"$errlog" |
      awk -f "$SCRIPT_DIR/lib/progress.awk" -v label="$label" -v status="$STATUS_FILE" -v tty="$tty" -v cols="$cols"
    rc=${PIPESTATUS[0]}
  else
    spin_start "copying with openrsync (no progress available – brew install rsync)"
    "$RSYNC" "${opts[@]}" -i "$@" "$dst" >"$log" 2>"$errlog" || rc=$?
    spin_stop
    grep -E '^(Number of files|Total file size|Total transferred|sent |total size)' "$log" | sed 's/^/    /'
  fi

  local nerr
  nerr=$(grep -c '^rsync: ' "$errlog" 2>/dev/null | tr -d ' ')
  case "$rc" in
    0)  ok "$label done" ;;
    24) ok "$label done (some files vanished while copying – normal for a live system)" ;;
    23) warn "$label: $nerr file(s) could not be copied – details in $errlog"
        grep '^rsync: ' "$errlog" | head -15 | sed 's/^/      /' >&2 ;;
    20) err "$label interrupted – re-run the same command to continue"; return 1 ;;
    *)  err "$label: rsync exited with code $rc – see $errlog"; tail -5 "$errlog" | sed 's/^/      /' >&2; return 1 ;;
  esac
  [ -s "$errlog" ] || rm -f "$errlog"
  return 0
}

run_home() {
  step "Home folder  $SRC_HOME/  →  $HOST_DIR/home/"
  info "exclude list: $EXCLUDES ($(grep -cvE '^[[:space:]]*(#|$)' "$EXCLUDES") patterns)"
  EXTRA_OPTS=(--exclude-from="$EXCLUDES")
  # never copy the backup into itself (only possible with --allow-internal)
  case "$DEST/" in "$SRC_HOME"/*) EXTRA_OPTS+=(--exclude="/${DEST#"$SRC_HOME"/}/") ;; esac
  run_rsync home "$HOST_DIR/home/" "$SRC_HOME/"
}

run_system() {
  step "System-wide config  →  $HOST_DIR/system/"
  local paths=() p
  while IFS= read -r p || [ -n "$p" ]; do
    case "$p" in ''|'#'*) continue ;; esac
    if [ -e "$p" ]; then paths+=("$p"); else info "not present, skipping: $p"; fi
  done <"$SYSTEM_PATHS"
  [ "${#paths[@]}" -gt 0 ] || { info "nothing to copy"; return 0; }
  if pgrep -xq 'postgres|mysqld|mariadbd|mongod|redis-server'; then
    warn "a database server is running – for a consistent copy stop it first (brew services stop …) or dump it"
  fi
  # -R keeps the absolute path: /opt/homebrew/etc → system/opt/homebrew/etc
  # --no-implied-dirs: parent dirs like /etc carry SIP xattrs that rsync would try (and fail) to copy
  EXTRA_OPTS=(-R --no-implied-dirs --exclude='*.sock' --exclude='*.pid')
  run_rsync system "$HOST_DIR/system/" "${paths[@]}"
}

run_verify() {
  step "Verify home mirror by checksum (reads everything again – slow)"
  local out="$LOG_DIR/verify-$TS.txt" n
  [ -d "$HOST_DIR/home" ] || { err "no mirror yet at $HOST_DIR/home"; return 1; }
  info "differences are written to $out"
  spin_start "comparing checksums"
  "$RSYNC" -a -n -c -i --exclude-from="$EXCLUDES" --exclude=.rsync-partial/ \
    "$SRC_HOME/" "$HOST_DIR/home/" >"$out" 2>&1
  spin_stop
  # ignore pure directory metadata lines; everything else is a real difference
  n=$(grep -E '^[<>ch*]' "$out" | grep -vcE '^\.d')
  if [ "$n" = 0 ]; then
    ok "mirror matches the Mac byte-for-byte (excluding the exclude list)"
  else
    warn "$n difference(s) (files changed since the sync also count) – see $out"
    grep -E '^[<>ch*]' "$out" | head -20 | sed 's/^/      /' >&2
  fi
}
