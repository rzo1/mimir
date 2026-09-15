# Renders rsync's output as one live status line and mirrors it to a status file.
# Usage: … | LC_ALL=C awk -f progress.awk -v label=home -v status=FILE -v tty=1 -v cols=120 [-v throttle=0]
#
# Input lines (separated by \r or \n), merged from three sources by run_rsync:
#   rsync stdout
#     " 123400 files..."                                                – file list scan
#     "4139548 files to consider"                                       – scan finished
#     "  120.40G  42%  110.25MB/s  0:28:10 (xfr#123, to-chk=100/4139548)" – transfer (time = elapsed;
#                                                                    the "(xfr#…)" part is often missing)
#   the rsync log file, prefixed "@log "
#     "@log 2026/09/15 14:26:09 [90152] .d..t...... some/dir/"          – what rsync is doing right now
#   a heartbeat
#     "@tick"                                                           – redraw (elapsed time keeps moving)
# rsync prints progress only while it copies file contents; during long stretches of metadata work
# (e.g. fixing directory timestamps) the log and the heartbeat keep the line alive.
# Everything else (stats, messages) is passed through.

BEGIN {
  RS = "[\r\n]"
  start = now()
  phase = "scan"
  last_draw = 0; last_status = 0; last_plain = 0; drawn = 0
  have_progress = 0; total_files = 0; files_done = 0
  act = ""; act_path = ""; act_time = 0
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

# terminal columns of a UTF-8 string (awk runs with LC_ALL=C and counts bytes)
function width(s,   c) { c = s; return length(s) - gsub(/[\200-\277]/, "", c) }

# rsync itemize code (%i) → what is happening
function describe(code) {
  if (code == "*deleting") return "deleting"
  if (code ~ /^>f\+/) return "copying"
  if (code ~ /^>f/) return "updating"
  if (code ~ /^cd/) return "creating folder"
  if (code ~ /^c[LDS]/) return "creating link"
  if (code ~ /^h/) return "creating hard link"
  if (code ~ /^\.[dfL]..t/) return "fixing timestamps"
  if (code ~ /^\./) return "updating attributes"
  return "working"
}

function show(line, force,   t) {
  t = now()
  if (!force && throttle && t == last_draw) return
  last_draw = t
  if (tty) {
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

# join the parts of the status line that are switched on in keep[]
function assemble(   line) {
  line = (keep["bar"] ? part["bar"] " " : "") part["pct"] " │ files " part["files"] (keep["fps"] ? part["fps"] : "")
  if (keep["size"]) line = line " │ " part["size"] (keep["copied"] ? " copied" : "")
  if (keep["rate"]) line = line " │ " part["rate"]
  if (keep["elapsed"]) line = line " │ " part["elapsed"]
  return line part["eta"]
}

function render(force,   t, el_now, pct, line, act_s, age, room, p, drop, i, n, max, target) {
  t = now()
  if (phase == "scan") {
    show(sprintf("scanning… %s files found (%s)", count(scanned), hms(t - start)), force)
    return
  }
  if (phase != "transfer") return

  # rsync's elapsed time only advances with its progress output; extrapolate in between
  el_now = have_progress ? el + (t - prog_time) : t - scan_done
  # the line (plus 4 spaces indent) must stay narrower than the terminal, or \r cannot redraw it
  max = cols - 5
  act_s = ""
  if (act != "") {
    age = t - act_time
    act_s = act (age >= 10 ? " (" hms(age) " ago)" : "")
  }
  # what rsync is doing right now matters more than bar and speed: keep room for it and ~20 columns
  # of its path
  target = max - (act_s != "" ? 3 + width(act_s) + 2 + 20 : 0)
  if (have_progress && total_files > 0) {
    # Progress is measured in files, not rsync's own percentage: that one only counts the bytes
    # transferred in this run, so a re-run over an existing backup would sit at 0% all the time.
    pct = files_done * 100 / total_files
    part["bar"] = bar(pct)
    part["pct"] = sprintf("%5.1f%%", pct)
    part["files"] = count(files_done) "/" count(total_files)
    part["fps"] = el > 0 ? sprintf(" (%s/s)", count(int(files_done / el))) : ""
    part["size"] = size; part["rate"] = rate; part["elapsed"] = hms(el_now)
    part["eta"] = (pct >= 0.5 && pct < 100 && el_now >= 10) ? " │ ETA " hms(el_now * (100 - pct) / pct) : ""
    # drop the least important parts until it fits
    n = split("bar fps copied rate size elapsed", drop, " ")
    for (i = 1; i <= n; i++) keep[drop[i]] = 1
    line = assemble()
    for (i = 1; i <= n && width(line) > target; i++) { keep[drop[i]] = 0; line = assemble() }
  } else if (have_progress) {
    line = sprintf("%s copied │ %s │ %s", size, rate, hms(el_now))
  } else {
    line = sprintf("files 0/%s │ %s", count(total_files), hms(el_now))
  }

  # append the activity with as much of the path as fits
  if (act_s != "") {
    room = max - width(line) - 3
    if (room >= width(act_s) + 2 + 12) {
      p = act_path
      if (width(p) > room - width(act_s) - 2) {
        p = substr(p, length(p) - (room - width(act_s) - 2) + 2)
        sub(/^[\200-\277]+/, "", p)  # don't start in the middle of a multi-byte character
        p = "…" p
      }
      line = line " │ " act_s ": " p
    } else if (room >= width(act_s)) {
      line = line " │ " act_s
    }
  }
  show(line, force)
}

/^@tick$/ { render(0); next }

/^@log / {
  # "@log 2026/09/15 14:26:09 [90152] .d..t...... some/path"; skip non-item lines (errors, stats)
  if (($5 ~ /^[.<>ch][fdLDS]/ && length($5) == 11) || $5 == "*deleting") {
    p = $0
    sub(/^@log [^ ]+ [^ ]+ \[[0-9]+\] [^ ]+ +/, "", p)
    act = describe($5); act_path = p; act_time = now()
    render(0)
  }
  next
}

/ files\.\.\.$/ {
  scanned = $1
  render(0)
  next
}

/^building file list/ { next }

/ files to consider$/ {
  total_files = $1; files_done = 0
  clear_line()
  printf "    found %s files in %s\n", count(total_files), hms(now() - start)
  scan_done = now(); phase = "transfer"
  next
}

/^ *[0-9][0-9.,]*[KMGTP]? +[0-9]+% / {
  size = $1; rate = $3; el = seconds($4); prog_time = now(); have_progress = 1
  if (phase == "scan") { phase = "transfer"; scan_done = prog_time }
  gsub(/,/, ".", size); gsub(/,/, ".", rate)
  if (match($0, /-chk=[0-9]+\/[0-9]+/)) {
    split(substr($0, RSTART + 5, RLENGTH - 5), fc, "/")
    total_files = fc[2]; files_done = fc[2] - fc[1]
  }
  render(0)
  next
}

/^[[:space:]]*$/ { next }

{
  # rsync's final statistics: the transfer is over
  phase = "done"
  clear_line()
  print "    " $0
  fflush()
}

END {
  if (last_draw) show(sprintf("%s finished after %s", label, hms(now() - start)), 1)
  clear_line()
}
