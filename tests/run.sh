#!/bin/bash
# Mímir test suite. Plain bash, no dependencies beyond what Mímir itself needs.
#
#   tests/run.sh              run all tests
#   tests/run.sh delete       run tests whose name contains "delete"
#
# Tests that need macOS tools (stat -f, diskutil, xattr, …) are skipped on other systems.
# MIMIR_TEST_KEEP=1 keeps the temporary directories for inspection.
# shellcheck disable=SC2012  # ls on our own, well-known file names
set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MIMIR="$ROOT/mimir"
# the tests' temp dirs sit on the internal disk, notifications would only spam the runner
export MIMIR_NO_NOTIFY=1

if [ -t 1 ]; then G=$'\033[32m' R=$'\033[31m' Y=$'\033[33m' D=$'\033[2m' O=$'\033[0m'; else G='' R='' Y='' D='' O=''; fi
# gpg-agent sockets must stay below 104 characters: keep the temp root short
TMP_ROOT=$(mktemp -d /tmp/mimir-tests.XXXXXX)
PASSED=0 FAILED=0 SKIPPED=0 FAILED_NAMES=""

cleanup() { [ -n "$MIMIR_TEST_KEEP" ] || rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# --- assertions (each returns 1 with a message; tests run under set -e) ------------------------------
fail() { printf '%s\n' "$*" >&2; return 1; }
skip() { printf 'SKIP: %s\n' "$*"; exit 77; }
assert_file()       { [ -f "$1" ] || fail "expected file: $1"; }
assert_dir()        { [ -d "$1" ] || fail "expected directory: $1"; }
assert_missing()    { if [ -e "$1" ] || [ -L "$1" ]; then fail "expected not to exist: $1"; fi; }
assert_eq()         { [ "$1" = "$2" ] || fail "expected '$2', got '$1'${3:+ ($3)}"; }
assert_contains()   { grep -q -- "$2" "$1" || { fail "'$1' should contain '$2'"; sed 's/^/  | /' "$1" >&2; return 1; }; }
assert_not_contains() { ! grep -q -- "$2" "$1" || { fail "'$1' should not contain '$2'"; return 1; }; }

require_macos() { [ "$(uname -s)" = Darwin ] || skip "needs macOS"; }
require_cmd()   { command -v "$1" >/dev/null 2>&1 || skip "needs $1"; }
rsync3() {
  local c
  for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
    # no "| grep -q": with pipefail the early exit would SIGPIPE rsync and fail the check
    [ -x "$c" ] && case "$("$c" --version 2>/dev/null)" in *"version 3."*) echo "$c"; return 0 ;; esac
  done
  return 1
}

# --- fixtures ----------------------------------------------------------------------------------------
# A small fake home folder with the tricky cases: hidden files, spaces, symlink, hard link, xattr,
# private key permissions, excluded caches/trash and the (included) Maven repository.
make_home() {
  local h="$1"
  mkdir -p "$h/.config/app" "$h/My Docs" "$h/Library/Caches/com.example" "$h/.Trash" "$h/.ssh/agent" \
    "$h/.m2/repository/org/example" "$h/Library/CloudStorage/OneDrive"
  echo 'export EDITOR=vim' >"$h/.zshrc"
  echo 'setting=1' >"$h/.config/app/app.conf"
  echo 'hello' >"$h/My Docs/file 1.txt"
  echo 'cache' >"$h/Library/Caches/com.example/blob"
  echo 'trash' >"$h/.Trash/old.txt"
  echo 'cloud' >"$h/Library/CloudStorage/OneDrive/doc.txt"
  echo 'jar' >"$h/.m2/repository/org/example/lib.jar"
  echo 'PRIVATE KEY' >"$h/.ssh/id_test" && chmod 600 "$h/.ssh/id_test"
  ln -s .zshrc "$h/zshrc-link"
  ln "$h/.zshrc" "$h/zshrc-hardlink"
  if command -v xattr >/dev/null 2>&1; then xattr -w com.example.tag blue "$h/My Docs/file 1.txt"; fi
}

# mimir_run [args…] — run Mímir non-interactively against $T/home → $T/dst
mimir_run() {
  MIMIR_SOURCE="$T/home" "$MIMIR" --allow-internal --yes "$@" "$T/dst"
}

backup_dir() { echo "$T/dst/mimir/$(printf '%s' "$(scutil --get ComputerName)" | tr -c 'A-Za-z0-9._-' '_')"; }

# --- CLI ---------------------------------------------------------------------------------------------
test_help() {
  "$MIMIR" --help >out.txt
  assert_contains out.txt "Usage: mimir"
  assert_contains out.txt "--status"
  assert_contains out.txt "--check"
}

test_unknown_option_fails() {
  if "$MIMIR" --bogus >out.txt 2>&1; then fail "expected failure"; fi
  assert_contains out.txt "unknown option --bogus"
}

test_unknown_step_fails() {
  if "$MIMIR" --only home,backup /tmp >out.txt 2>&1; then fail "expected failure"; fi
  assert_contains out.txt "unknown step 'backup'"
}

test_refuses_non_macos() {
  [ "$(uname -s)" != Darwin ] || skip "only meaningful on non-macOS systems"
  if "$MIMIR" /tmp >out.txt 2>&1; then fail "expected failure"; fi
  assert_contains out.txt "only runs on macOS"
}

test_without_destination_and_terminal_prints_usage() {
  require_macos
  if "$MIMIR" </dev/null >out.txt 2>&1; then fail "expected failure"; fi
  assert_contains out.txt "Usage: mimir"
}

test_missing_destination_fails() {
  require_macos
  if "$MIMIR" --yes "$T/does-not-exist" >out.txt 2>&1; then fail "expected failure"; fi
  assert_contains out.txt "does not exist"
}

test_internal_disk_is_refused() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  if MIMIR_SOURCE="$T/home" "$MIMIR" --yes --only home "$T/dst" >out.txt 2>&1; then fail "expected failure"; fi
  assert_contains out.txt "same disk as your home folder"
}

test_check_mode_copies_nothing() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mimir_run --check >out.txt 2>&1
  assert_contains out.txt "==> Requirements"
  assert_contains out.txt "==> Destination"
  assert_contains out.txt "nothing was copied"
  assert_missing "$T/dst/mimir"
}

test_check_mode_without_destination() {
  require_macos
  "$MIMIR" --check >out.txt 2>&1
  assert_contains out.txt "==> Requirements"
  assert_contains out.txt "requirements checked"
}

# --- home mirror -------------------------------------------------------------------------------------
test_home_mirror() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mimir_run --only home >out.txt 2>&1
  local b; b="$(backup_dir)"; local h="$b/home"

  assert_file "$h/.zshrc"
  assert_file "$h/.config/app/app.conf"
  assert_file "$h/My Docs/file 1.txt"
  assert_file "$h/.m2/repository/org/example/lib.jar"
  assert_missing "$h/Library/Caches/com.example"
  assert_missing "$h/.Trash"
  assert_missing "$h/Library/CloudStorage"
  assert_eq "$(readlink "$h/zshrc-link")" ".zshrc" "symlink kept"
  assert_eq "$(stat -f %i "$h/.zshrc")" "$(stat -f %i "$h/zshrc-hardlink")" "hard link kept"
  assert_eq "$(stat -f %Lp "$h/.ssh/id_test")" "600" "permissions kept"
  if [ -z "$MIMIR_RSYNC" ] && rsync3 >/dev/null; then
    assert_eq "$(xattr -p com.example.tag "$h/My Docs/file 1.txt")" "blue" "extended attribute kept"
  fi
  assert_file "$b/last-run.txt"
  assert_file "$b/RESTORE.md"
  assert_file "$b/_tool/mimir"
  assert_missing "$b/.lock"
  assert_contains out.txt "home done"
}

test_rerun_copies_only_the_delta() {
  require_macos
  rsync3 >/dev/null || skip "needs rsync 3 (per-file log)"
  mkdir -p home dst && make_home "$T/home"
  mimir_run --only home >>mimir.log 2>&1
  echo new >"$T/home/new.txt"
  sleep 1  # new run → new timestamp → new log file
  mimir_run --only home >>mimir.log 2>&1
  local log; log=$(ls -t "$(backup_dir)"/logs/rsync-home-*.log | head -1)
  assert_eq "$(grep -c ' >f' "$log")" "1" "files transferred in second run"
  assert_contains "$log" "new.txt"
}

# macOS stamps com.apple.provenance on everything rsync creates; if the options don't ignore it,
# every re-run rewrites the attributes of every file and directory (days on a USB disk).
# rsync's log file omits attribute-only updates, so ask rsync itself, with Mímir's exact options.
test_rerun_does_not_rewrite_attributes() {
  require_macos
  rsync3 >/dev/null || skip "needs rsync 3 (xattr support)"
  mkdir -p home dst && make_home "$T/home"
  # like most files in a real home folder, the originals carry no provenance attribute
  # (per entry: "xattr -rd" stops at the first file that doesn't have the attribute)
  find "$T/home" ! -type l -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
  if xattr "$T/home/.zshrc" | grep -qx com.apple.provenance; then skip "cannot remove com.apple.provenance here"; fi
  mimir_run --only home >>mimir.log 2>&1
  local h; h="$(backup_dir)/home"
  # shellcheck source=../lib/common.sh
  . "$ROOT/lib/common.sh"
  # shellcheck source=../lib/mirror.sh
  . "$ROOT/lib/mirror.sh"
  detect_rsync; DEST_FS=apfs; build_rsync_opts
  "$RSYNC" "${RSYNC_OPTS[@]}" --info=progress0,flist0,stats0 -n -i --exclude-from="$ROOT/excludes.txt" \
    "$T/home/" "$h/" >itemized.txt
  assert_eq "$(grep -c . itemized.txt)" "0" "entries rsync would update on an unchanged re-run"
}

test_dry_run_copies_nothing() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mimir_run -n --only home >out.txt 2>&1
  assert_contains out.txt "DRY RUN"
  assert_missing "$(backup_dir)/home"
}

test_additive_by_default() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mimir_run --only home >>mimir.log 2>&1
  rm "$T/home/.zshrc"
  mimir_run --only home >>mimir.log 2>&1
  assert_file "$(backup_dir)/home/.zshrc"
}

test_delete_parks_removed_files() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mimir_run --only home >>mimir.log 2>&1
  local b; b="$(backup_dir)"
  rm "$T/home/.config/app/app.conf"
  mkdir -p "$b/home/.Trash" && echo keep >"$b/home/.Trash/excluded.txt"
  sleep 1
  mimir_run --delete --only home >out.txt 2>&1
  assert_missing "$b/home/.config/app/app.conf"
  assert_file "$(ls -d "$b"/_removed/*/home | head -1)/.config/app/app.conf"
  assert_file "$b/home/.Trash/excluded.txt"   # excluded paths are never deleted
}

test_verify_detects_difference() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mimir_run --verify --only home >out.txt 2>&1
  assert_contains out.txt "mirror matches"
  local f; f="$(backup_dir)/home/My Docs/file 1.txt"
  # same size and timestamp, different content: only a checksum comparison notices
  printf 'HELLO\n' >"$f" && touch -r "$T/home/My Docs/file 1.txt" "$f"
  mimir_run --only verify >out.txt 2>&1
  assert_contains out.txt "1 difference"
}

test_openrsync_fallback() {
  require_macos
  /usr/bin/rsync --version 2>&1 | grep -q openrsync || skip "/usr/bin/rsync is not openrsync"
  mkdir -p home dst && make_home "$T/home"
  MIMIR_RSYNC=/usr/bin/rsync mimir_run --only home >out.txt 2>&1
  assert_contains out.txt "openrsync"
  assert_file "$(backup_dir)/home/My Docs/file 1.txt"
  assert_missing "$(backup_dir)/home/Library/Caches/com.example"
}

test_system_paths() {
  require_macos
  mkdir -p home dst etc-fixture/sub && make_home "$T/home"
  echo 'conf' >"$T/etc-fixture/sub/tool.conf"
  printf '# comment\n%s\n/does/not/exist\n' "$T/etc-fixture" >paths.txt
  mimir_run --only system --system-paths "$T/paths.txt" >out.txt 2>&1
  assert_file "$(backup_dir)/system$T/etc-fixture/sub/tool.conf"
  assert_contains out.txt "not present, skipping: /does/not/exist"
}

# --- run control -------------------------------------------------------------------------------------
test_lock_prevents_concurrent_runs() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mimir_run --only home >>mimir.log 2>&1
  sleep 60 & local pid=$!
  echo "$pid" >"$(backup_dir)/.lock"
  if mimir_run --only home >out.txt 2>&1; then kill "$pid"; fail "expected failure"; fi
  kill "$pid"
  assert_contains out.txt "another Mímir run (PID $pid)"
}

test_stale_lock_is_ignored() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mkdir -p "$(backup_dir)" && echo 99999999 >"$(backup_dir)/.lock"
  mimir_run --only home >out.txt 2>&1
  assert_contains out.txt "home done"
}

test_status_without_active_run() {
  require_macos
  mkdir -p home dst && make_home "$T/home"
  mimir_run --only home >>mimir.log 2>&1
  MIMIR_SOURCE="$T/home" "$MIMIR" --status "$T/dst" >out.txt 2>&1
  assert_contains out.txt "no Mímir run is active"
  assert_contains out.txt "last run:"
}

# --- secrets -----------------------------------------------------------------------------------------
test_secrets_export_gpg_and_ssh() {
  require_macos
  require_cmd gpg
  mkdir -p home dst && make_home "$T/home"
  export GNUPGHOME="$T/gpg"; mkdir -m 700 "$GNUPGHOME"
  gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'Test <test@example.org>' ed25519 sign never >/dev/null 2>&1
  mimir_run --only secrets >out.txt 2>&1
  local s; s="$(backup_dir)/secrets"
  assert_contains "$s/gpg/secret-keys.asc" "BEGIN PGP PRIVATE KEY BLOCK"
  assert_contains "$s/gpg/public-keys.asc" "BEGIN PGP PUBLIC KEY BLOCK"
  assert_file "$s/gpg/ownertrust.txt"
  assert_eq "$(stat -f %Lp "$s")" "700" "secrets dir permissions"
  assert_eq "$(stat -f %Lp "$s/gpg/secret-keys.asc")" "600" "secret key file permissions"
  assert_file "$s/ssh/id_test"
  assert_missing "$s/ssh/agent"

  mimir_run --only secrets >out2.txt 2>&1
  assert_contains out2.txt "unchanged since last export"

  # the export can be imported into a fresh keyring
  mkdir -m 700 "$T/gpg2"
  GNUPGHOME="$T/gpg2" gpg --batch --pinentry-mode loopback --passphrase '' --import "$s/gpg/secret-keys.asc" >/dev/null 2>&1
  assert_eq "$(GNUPGHOME="$T/gpg2" gpg --list-secret-keys --with-colons | grep -c '^sec')" "1" "imported secret keys"
  gpgconf --kill gpg-agent; GNUPGHOME="$T/gpg2" gpgconf --kill gpg-agent
}

# --- inventory helpers (sourced directly) ------------------------------------------------------------
load_libs() {
  # shellcheck source=../lib/common.sh
  . "$ROOT/lib/common.sh"
  # shellcheck source=../lib/inventory.sh
  . "$ROOT/lib/inventory.sh"
}

test_git_repos_attention_report() {
  require_cmd git
  load_libs
  local h="$T/home" g="git -c user.name=t -c user.email=t@example.org -c init.defaultBranch=main"
  mkdir -p "$h/src"
  $g init -q --bare "$T/origin.git"
  commit() { echo "$2" >"$1/f.txt" && $g -C "$1" add f.txt && $g -C "$1" commit -qm "$2"; }

  $g init -q "$h/src/clean" && commit "$h/src/clean" one
  $g -C "$h/src/clean" remote add origin "$T/origin.git" && $g -C "$h/src/clean" push -q origin main
  $g clone -q "$T/origin.git" "$h/src/unpushed" 2>/dev/null && commit "$h/src/unpushed" two
  $g clone -q "$T/origin.git" "$h/src/dirty" 2>/dev/null && echo change >>"$h/src/dirty/f.txt"
  $g init -q "$h/src/no-remote" && commit "$h/src/no-remote" three
  $g init -q "$h/src/mirror" && commit "$h/src/mirror" four && $g -C "$h/src/mirror" remote add origin "$T/origin.git"
  mkdir -p "$h/Library/ignored" && $g init -q "$h/Library/ignored"

  INV_DIR="$T/inv" SRC_HOME="$h" inv_git_repos
  local a="$T/inv/dev/git-repos-ATTENTION.txt"
  assert_eq "$(($(wc -l <"$T/inv/dev/git-repos.tsv") - 1))" "5" "repositories found (Library is skipped)"
  assert_not_contains "$a" "src/clean "
  assert_contains "$a" "src/unpushed .*unpushed=1"
  assert_contains "$a" "src/dirty .*uncommitted=1"
  assert_contains "$a" "src/no-remote .*origin=-"
  assert_contains "$a" "cannot be determined"
  assert_eq "$(tail -1 "$a")" "src/mirror"
}

test_ollama_models_from_manifests() {
  load_libs
  local m="$T/home/.ollama/models/manifests"
  mkdir -p "$m/registry.ollama.ai/library/llama3" "$m/registry.ollama.ai/someone/custom"
  touch "$m/registry.ollama.ai/library/llama3/8b" "$m/registry.ollama.ai/someone/custom/latest"
  # shellcheck disable=SC2034  # read by cap_sh in the evaluated snippet
  INV_DIR="$T/inv" SRC_HOME="$T/home"
  local h="$SRC_HOME"
  # the snippet from inv_dev, run in isolation
  eval "$(sed -n '/manifests\/<registry>/,/| sort"$/p' "$ROOT/lib/inventory.sh")"
  assert_eq "$(tr '\n' ' ' <"$T/inv/dev/ollama-models.txt")" "llama3:8b someone/custom:latest "
}

# --- volumes -----------------------------------------------------------------------------------------
test_volume_list_hides_system_and_time_machine() {
  # shellcheck source=../lib/common.sh
  . "$ROOT/lib/common.sh"
  # shellcheck source=../lib/volumes.sh
  . "$ROOT/lib/volumes.sh"
  mount() {
    cat <<'MOUNT'
/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, protect, root data)
/dev/disk5s1 on /Volumes/Backups of MacBook Pro 1 (apfs, local, nodev, nosuid, journaled, nobrowse)
com.apple.TimeMachine.2026-09-15.local@/dev/disk3s5 on /Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/x (apfs, local, read-only, journaled, nobrowse, protect)
/dev/disk7s1 on /Volumes/data (apfs, local, nodev, nosuid, journaled, noowners)
/dev/disk8s1 on /Volumes/My Disk (exfat, local, nodev, nosuid, noowners)
/dev/disk9s1 on /Volumes/Installer (hfs, local, nodev, nosuid, read-only, noowners)
MOUNT
  }
  list_volumes >vols.txt
  assert_eq "$(tr '\n' '|' <vols.txt)" "/Volumes/data|/Volumes/My Disk|"
}

# --- progress renderer -------------------------------------------------------------------------------
test_progress_renderer() {
  {
    printf 'building file list ... \n 0 files...\r 100 files...\r 200 files...\r12581 files to consider\n\n'
    printf '        303   0%%    0,00kB/s    0:00:00 (xfr#1, to-chk=12576/12581)\r'
    printf '     18,00M  10%%   15,05MB/s    0:00:10 (xfr#2000, to-chk=10136/12581)\r'
    printf '     90,21M  50%%   14,57MB/s    0:00:20\r'
    printf '\nNumber of files: 12.581 (reg: 10.313, dir: 2.268)\n'
  } >rsync.txt
  LC_ALL=C awk -f "$ROOT/lib/progress.awk" -v label=home -v status="$T/status" -v tty=1 -v cols=130 -v throttle=0 <rsync.txt |
    LC_ALL=C tr '\r' '\n' >out.txt
  assert_contains out.txt "found 12.6k files"
  assert_not_contains out.txt "building file list"
  # progress is files checked / files found – not rsync's byte percentage (10% / 50% in the input)
  assert_contains out.txt " 19.4% │ files 2445/12.6k (244/s) │ 18.00M copied │ 15.05MB/s │ 0m10s │ ETA 0m41s"
  assert_contains out.txt " 19.4% │ files 2445/12.6k (122/s) │ 90.21M copied │ 14.57MB/s │ 0m20s │ ETA 1m22s"
  assert_contains out.txt "███░"
  assert_contains out.txt "    Number of files: 12.581"
  assert_eq "$(sed -n 2p "$T/status")" "home"
  assert_contains "$T/status" "home finished"
}

# rsync stays silent while it only fixes metadata: the log follower and the heartbeat keep the line
# alive and show what is going on
test_progress_renderer_shows_current_activity() {
  {
    printf '12581 files to consider\n'
    printf '     18,00M  10%%   15,05MB/s    0:00:10 (xfr#2000, to-chk=10136/12581)\n'
    printf '@log 2026/09/15 14:26:09 [90152] .d..t...... IdeaProjects/app/node_modules/@scope/pkg/dist/\n'
    printf '@log 2026/09/15 14:26:09 [90152] rsync: [sender] something went wrong\n'
    printf '@tick\n'
    printf '@log 2026/09/15 14:26:10 [90152] >f+++++++++ Documents/Übersicht Ärzte.pdf\n'
    printf '@log 2026/09/15 14:26:11 [90152] *deleting   old stuff/file.txt\n'
  } | LC_ALL=C awk -f "$ROOT/lib/progress.awk" -v label=home -v tty=1 -v cols=200 -v throttle=0 |
    LC_ALL=C tr '\r' '\n' >out.txt
  assert_contains out.txt "files 2445/12.6k .* │ fixing timestamps: IdeaProjects/app/node_modules/@scope/pkg/dist/"
  assert_not_contains out.txt "something went wrong"
  assert_contains out.txt "│ copying: Documents/Übersicht Ärzte.pdf"
  assert_contains out.txt "│ deleting: old stuff/file.txt"
}

test_progress_renderer_fits_the_terminal() {
  local cols
  for cols in 80 100 125 160; do
    {
      printf '5240000 files to consider\n'
      printf '    115,20G  40%%  110,25MB/s    0:27:10 (xfr#2000, to-chk=3130000/5240000)\n'
      printf '@log 2026/09/15 14:26:09 [90152] .d..t...... Documents/Überordner/%s/\n' "$(printf 'sehr-langer-ordnername-%.0s' 1 2 3 4 5 6 7 8)"
    } | LC_ALL=C awk -f "$ROOT/lib/progress.awk" -v label=home -v tty=1 -v cols="$cols" -v throttle=0 |
      LC_ALL=C tr '\r' '\n' | sed 's/\x1b\[K//g' | grep '│' >"lines-$cols.txt"
    # every drawn line (4 spaces indent included) must fit, counting characters, not bytes
    local widest
    widest=$(LC_ALL=C awk '{ c = $0; n = length($0) - gsub(/[\200-\277]/, "", c); if (n > w) w = n } END { print w + 0 }' "lines-$cols.txt")
    [ "$widest" -lt "$cols" ] || fail "line of $widest columns on a $cols-column terminal: $(tail -1 "lines-$cols.txt")"
  done
  assert_contains lines-160.txt "fixing timestamps: …"
  assert_contains lines-80.txt "fixing timestamps"
}

test_progress_renderer_narrow_terminal_has_no_bar() {
  printf '     18,00M  10%%   15,05MB/s    0:00:10 (xfr#2000, to-chk=10136/12581)\n' |
    LC_ALL=C awk -f "$ROOT/lib/progress.awk" -v label=home -v tty=1 -v cols=80 | LC_ALL=C tr '\r' '\n' >out.txt
  assert_not_contains out.txt "█"
  assert_not_contains out.txt "/s)"
  assert_contains out.txt " 19.4% │ files 2445/12.6k │ 18.00M copied │ 15.05MB/s │ 0m10s │ ETA 0m41s"
}

# --- runner ------------------------------------------------------------------------------------------
run_all() {
  local filter="$1" t rc
  for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    case "$t" in *"$filter"*) ;; *) continue ;; esac
    T="$TMP_ROOT/$t"; mkdir -p "$T"
    # plain commands only: set -e is ignored inside functions called from && / || / if
    ( set -e; cd "$T"; "$t" ) >"$T.log" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then
      PASSED=$((PASSED + 1)); printf '  %s✓%s %s\n' "$G" "$O" "${t#test_}"
    elif [ "$rc" = 77 ]; then
      SKIPPED=$((SKIPPED + 1)); printf '  %s-%s %s %s(%s)%s\n' "$Y" "$O" "${t#test_}" "$D" "$(sed -n 's/^SKIP: //p' "$T.log" | head -1)" "$O"
    else
      FAILED=$((FAILED + 1)); FAILED_NAMES="$FAILED_NAMES ${t#test_}"
      printf '  %s✗ %s%s\n' "$R" "${t#test_}" "$O"
      tail -25 "$T.log" | sed 's/^/      /'
      for f in "$T/out.txt" "$T/mimir.log"; do
        [ -s "$f" ] && { printf '      --- %s\n' "${f##*/}"; tail -15 "$f" | sed 's/^/      /'; }
      done
    fi
  done
}

printf 'Mímir tests (%s, %s)\n' "$(uname -s)" "$(rsync3 || echo "no rsync 3")"
run_all "$1"
printf '\n%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" = 0 ] || { printf 'failed:%s\n' "$FAILED_NAMES"; exit 1; }
