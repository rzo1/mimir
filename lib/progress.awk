# Renders rsync --info=progress2,flist2 output as one live status line and mirrors it to a status file.
# Usage: rsync ... | LC_ALL=C awk -f progress.awk -v label=home -v status=FILE -v tty=1 -v cols=120 [-v throttle=0]
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
  total_files = $1; files_done = 0
  clear_line()
  printf "    found %s files in %s\n", count(total_files), hms(now() - start)
  scan_done = now()
  next
}

/^ *[0-9][0-9.,]*[KMGTP]? +[0-9]+% / {
  size = $1; rate = $3; el = seconds($4)
  gsub(/,/, ".", size); gsub(/,/, ".", rate)
  if (match($0, /-chk=[0-9]+\/[0-9]+/)) {
    split(substr($0, RSTART + 5, RLENGTH - 5), fc, "/")
    total_files = fc[2]; files_done = fc[2] - fc[1]
  }
  if (total_files <= 0) {
    show(sprintf("%s copied │ %s │ %s", size, rate, hms(el)), 0)
    next
  }
  # Progress is measured in files, not rsync's own percentage: that one only counts the bytes
  # transferred in this run, so a re-run over an existing backup would sit at 0% all the time.
  pct = files_done * 100 / total_files
  eta = (pct >= 0.5 && pct < 100 && el >= 10) ? " │ ETA " hms(el * (100 - pct) / pct) : ""
  # the line must fit the terminal, or \r cannot redraw it: bar and files/s only on wide ones
  wide = (cols >= 125)
  show(sprintf("%s%5.1f%% │ files %s/%s%s │ %s%s │ %s │ %s%s",
               (wide ? bar(pct) " " : ""), pct, count(files_done), count(total_files),
               (wide && el > 0 ? sprintf(" (%s/s)", count(int(files_done / el))) : ""),
               size, (wide ? " copied" : ""), rate, hms(el), eta), 0)
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
