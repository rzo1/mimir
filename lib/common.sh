# shellcheck shell=bash
# Shared helpers. Keep compatible with macOS /bin/bash 3.2 (no assoc arrays, no mapfile, no &>>).

# shellcheck disable=SC2034  # colours are used by all sourced files
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=; C_YEL=; C_GRN=; C_BLU=; C_BLD=; C_DIM=; C_OFF=
fi

WARNINGS=0

_to_log() {
  if [ -n "$RUN_LOG" ] && [ -d "$(dirname "$RUN_LOG")" ]; then
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$RUN_LOG"
  fi
}

# STEP_TAG ("[2/4] ") is set by the main loop while a step runs
step() { spin_interrupt; printf '\n%s==> %s%s%s\n' "$C_BLD$C_BLU" "$STEP_TAG" "$*" "$C_OFF"; _to_log "==> $STEP_TAG$*"; }
info() { spin_interrupt; printf '    %s\n' "$*"; _to_log "    $*"; }
ok()   { spin_interrupt; printf '    %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; _to_log "    OK $*"; }
# warn "line" ["more lines" …] — one warning, possibly spanning several lines
warn() {
  spin_interrupt
  local l pre="!"
  for l in "$@"; do
    printf '    %s%s %s%s\n' "$C_YEL" "$pre" "$l" "$C_OFF" >&2; _to_log "    WARN $l"; pre=" "
  done
  WARNINGS=$((WARNINGS + 1))
}
err()  { spin_interrupt; printf '    %s✗ %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; _to_log "    ERROR $*"; }
die()  { spin_interrupt; printf '%sError:%s %s\n' "$C_RED$C_BLD" "$C_OFF" "$*" >&2; _to_log "FATAL $*"; exit 1; }

# --- spinner for long silent tasks ----------------------------------------------------------------
# spin_start "message" … spin_stop  →  "⠋ message … 1m12s" while running, "✓ message (1m12s)" after.
# Any other output in between ends the spinner line cleanly (spin_interrupt).
SPIN_PID="" SPIN_MSG="" SPIN_START=0

spin_start() {
  SPIN_MSG="$1"; SPIN_START=$(date +%s)
  _to_log "    $1 …"
  if [ -t 1 ]; then
    (
      trap 'exit 0' TERM
      frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); i=0
      while :; do
        printf '\r\033[K    %s%s%s %s … %s' "$C_BLU" "${frames[i]}" "$C_OFF" "$SPIN_MSG" "$(elapsed_short "$SPIN_START")"
        i=$(( (i + 1) % 10 )); sleep 0.2
      done
    ) &
    SPIN_PID=$!
  else
    printf '    %s …\n' "$1"
  fi
}

# stop the animation; the message stays on screen as a plain line
spin_interrupt() {
  [ -n "$SPIN_PID" ] || return 0
  kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null
  SPIN_PID=""
  printf '\r\033[K    %s …\n' "$SPIN_MSG"
  SPIN_MSG=""
}

spin_stop() {
  if [ -n "$SPIN_PID" ]; then
    kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null
    SPIN_PID=""
    printf '\r\033[K'
    ok "$SPIN_MSG ($(elapsed_short "$SPIN_START"))"
  elif [ -n "$SPIN_MSG" ] && [ ! -t 1 ]; then
    _to_log "    OK $SPIN_MSG ($(elapsed_short "$SPIN_START"))"
  fi
  SPIN_MSG=""
}

notify() {  # macOS notification center; harmless if it fails. MIMIR_NO_NOTIFY=1 disables it.
  [ -z "$MIMIR_NO_NOTIFY" ] || return 0
  osascript -e "display notification \"$2\" with title \"Mímir\" subtitle \"$1\" sound name \"Glass\"" >/dev/null 2>&1 || true
}

have() { command -v "$1" >/dev/null 2>&1; }

# confirm "question" -> 0 if yes. Honors --yes; refuses when there is no terminal to ask.
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$CHECK_ONLY" = 1 ] && return 0  # --check only reports
  if [ ! -t 0 ]; then
    err "$1 (no terminal to confirm; pass --yes to accept)"
    return 1
  fi
  local ans
  read -r -p "    $1 [y/N] " ans
  case "$ans" in y|Y|yes|YES|j|J|ja) return 0 ;; *) return 1 ;; esac
}

# with_timeout SECONDS cmd args... — kill commands that hang (docker/ollama with a dead daemon etc.)
with_timeout() {
  local secs="$1"; shift
  if have perl; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  else
    "$@"
  fi
}

human_kb() {
  awk -v kb="$1" 'BEGIN { split("KB MB GB TB", u); i = 1; while (kb >= 1024 && i < 4) { kb /= 1024; i++ } printf "%.1f %s", kb, u[i] }'
}

elapsed_short() {
  local s=$(( $(date +%s) - $1 ))
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"
  fi
}

elapsed() {
  local s=$(( $(date +%s) - $1 ))
  printf '%dh %02dm %02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
}
