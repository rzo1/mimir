# Renders rsync --info=progress2,flist2 output as one live status line and mirrors it to a status file.
# Usage: rsync ... | awk -f progress.awk -v label=home -v status=FILE -v tty=1 -v cols=120 [-v throttle=0]
#
# Input lines (separated by \r or \n):
#   " 123400 files..."                                               – file list scan
#   "4139548 files to consider"                                      – scan finished
#   "  120.40G  42%  110.25MB/s  0:28:10 (xfr#123, to-chk=100/4139548)" – transfer (time = elapsed;
#                                                                   the "(xfr#…)" part is often missing)
# Everything else (stats, messages) is passed through.

BEGIN {
  RS = "[\r\n]"
  start = now()
  last_draw = 0
  last_status = 0
  drawn = 0
  if (cols < 40) cols = 80
  if (throttle == "") throttle = 1  # redraw at most once per second; 0 draws every line (tests)
}

function now() { srand(); return srand() }

function hms(s,   h, m) {
  s = int(s); h = int(s / 3600); m = int((s % 3600) / 60)
  return (h > 0) ? sprintf("%dh%02dm", h, m) : sprintf("%dm%02ds", m, s % 60)
}

function seconds(t,   p, n) {  # "1:02:03" -> 3723
  n = split(t, p, ":")
  return (n == 3) ? p[1] * 3600 + p[2] * 60 + p[3] : (n == 2) ? p[1] * 60 + p[2] : t + 0
}

function count(n) {
  if (n >= 1000000) return sprintf("%.2fM", n / 1000000)
  if (n >= 10000) return sprintf("%.1fk", n / 1000)
  return n
}

function bar(pct,   w, f, s, i) {
  w = 20; f = int(pct * w / 100); s = ""
  for (i = 0; i < w; i++) s = s (i < f ? "█" : "░")
  return s
}

function show(line, force,   t) {
  t = now()
  if (!force && throttle && t == last_draw) return
  last_draw = t
  if (tty) {
    # no truncation: macOS awk counts bytes, and the bar/separators are multi-byte glyphs
    printf "\r\033[K    %s", line
    drawn = 1
  } else if (force || t - last_plain >= 60) {
    last_plain = t
    printf "    %s\n", line
  }
  if (status != "" && (force || t - last_status >= 3)) {
    last_status = t
    printf "%d\n%s\n%s\n", t, label, line > status
    close(status)
  }
  fflush()
}

function clear_line() {
  if (tty && drawn) { printf "\r\033[K"; drawn = 0 }
}

/ files\.\.\.$/ {
  scanned = $1
  show(sprintf("scanning… %s files found (%s)", count(scanned), hms(now() - start)), 0)
  next
}

/^building file list/ { next }

/ files to consider$/ {
  total_files = $1
  clear_line()
  printf "    found %s files in %s\n", count(total_files), hms(now() - start)
  scan_done = now()
  next
}

/^ *[0-9][0-9.,]*[KMGTP]? +[0-9]+% / {
  size = $1; pct = $2 + 0; rate = $3; el = seconds($4)
  gsub(/,/, ".", size); gsub(/,/, ".", rate)
  if (match($0, /-chk=[0-9]+\/[0-9]+/)) {
    split(substr($0, RSTART + 5, RLENGTH - 5), fc, "/")
    files = sprintf(" │ files %s/%s", count(fc[2] - fc[1]), count(fc[2]))
  }
  eta = (pct >= 1 && pct < 100 && el >= 10) ? " │ ETA " hms(el * (100 - pct) / pct) : ""
  # the line must fit the terminal, or \r cannot redraw it: the bar only on wide terminals
  show(sprintf("%s%3d%% │ %s │ %s │ %s%s%s", (cols >= 100 ? bar(pct) " " : ""), pct, size, rate, hms(el), files, eta), 0)
  next
}

/^[[:space:]]*$/ { next }

{
  clear_line()
  print "    " $0
  fflush()
}

END {
  if (last_draw) show(sprintf("%s finished after %s", label, hms(now() - start)), 1)
  clear_line()
}
