# Renders rsync's output as one live status line and mirrors it to a status file.
# Usage: … | LC_ALL=C awk -f progress.awk -v label=home -v status=FILE -v changes=FILE -v tty=1 -v cols=120
#            [-v throttle=0]
# changes: every entry rsync created, updated or deleted is written there (up-to-date ones are not)
#
# Input lines (separated by \r or \n), rsync's stdout merged with a heartbeat by run_rsync:
#   " 123400 files..."                                                  – file list scan
#   "4139548 files to consider"                                         – scan finished
#   ".f          Documents/unchanged.txt"                               – one line per checked entry
#   ">f+++++++++ Documents/new.txt"                                       (--info=name2 --out-format='%i %n%L')
#   "  120.40G  42%  110.25MB/s  0:28:10 (xfr#123, to-chk=100/4139548)"   – transfer (time = elapsed;
#                                                                      the "(xfr#…)" part is often missing)
#   "@tick"                                                             – heartbeat: redraw, time moves on
# rsync prints progress only while it copies file contents. The per-entry lines keep counter and
# path moving while it checks files that are already up to date or only fixes metadata.
# Everything else (stats, messages) is passed through.

BEGIN {
  RS = "[\r\n]"
  start = now()
  phase = "scan"
  last_draw = 0; last_status = 0; last_plain = 0; drawn = 0
  have_progress = 0; total_files = 0; chk_done = 0; checked = 0
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
  if (code ~ /^\*deleting/) return "deleting"
  if (code ~ /^\.[fdLDS] *$/) return "checking"  # no change flags: already up to date
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

function render(force,   t, el_now, pct, line, act_s, age, room, p, drop, i, n, max, target, done) {
  t = now()
  if (phase == "scan") {
    show(sprintf("scanning… %s files found (%s)", count(scanned), hms(t - start)), force)
    return
  }
  if (phase != "transfer") return

  # rsync's elapsed time starts with the first copied file and only advances with its progress
  # output: extrapolate in between, and never show less than the time since the scan finished
  el_now = t - scan_done
  if (have_progress && el + (t - prog_time) > el_now) el_now = el + (t - prog_time)
  # the line (plus 4 spaces indent) must stay narrower than the terminal, or \r cannot redraw it
  max = cols - 5
  act_s = ""
  if (act != "") {
    age = t - act_time + fake_age  # fake_age: tests only
    act_s = act (age >= 10 ? " (" hms(age) " ago)" : "")
    # after the last entry rsync revisits every folder to set its date, without any output
    if (age >= 10 && total_files > 0 && (checked >= total_files || chk_done >= total_files)) {
      act_s = "finishing: setting folder dates (no progress info from rsync)"; act_path = ""
    }
  }
  # what rsync is doing right now matters more than bar and speed: keep room for it and ~20 columns
  # of its path
  target = max - (act_s != "" ? 3 + width(act_s) + 2 + 20 : 0)
  if (total_files > 0) {
    # Progress is measured in entries checked, not rsync's own percentage: that one only counts the
    # bytes transferred in this run, so a re-run over an existing backup would sit at 0% all the time.
    done = (checked > chk_done ? checked : chk_done)
    if (done > total_files) done = total_files
    pct = done * 100 / total_files
    part["bar"] = bar(pct)
    part["pct"] = sprintf("%5.1f%%", pct)
    part["files"] = count(done) "/" count(total_files)
    part["fps"] = el_now > 0 ? sprintf(" (%s/s)", count(int(done / el_now))) : ""
    part["size"] = (have_progress ? size : "0"); part["rate"] = (have_progress ? rate : "0.00kB/s")
    part["elapsed"] = hms(el_now)
    part["eta"] = (pct >= 0.5 && pct < 100 && el_now >= 10) ? " │ ETA " hms(el_now * (100 - pct) / pct) : ""
    # drop the least important parts until it fits
    n = split("bar fps copied rate size elapsed", drop, " ")
    for (i = 1; i <= n; i++) keep[drop[i]] = 1
    line = assemble()
    for (i = 1; i <= n && width(line) > target; i++) { keep[drop[i]] = 0; line = assemble() }
  } else if (have_progress) {
    line = sprintf("%s copied │ %s │ %s", size, rate, hms(el_now))
  } else {
    line = hms(el_now)
  }

  # append the activity with as much of the path as fits
  if (act_s != "") {
    room = max - width(line) - 3
    if (act_path == "" && room >= width(act_s)) {
      line = line " │ " act_s
    } else if (room >= width(act_s) + 2 + 12) {
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

# one entry checked: "%i %n%L" = 11 characters of change flags, a space, the path
/^([.<>ch][fdLDS]|\*deleting)/ && substr($0, 12, 1) == " " {
  code = substr($0, 1, 11)
  if (code !~ /^\*/) checked++  # deletions are not part of the file list
  act = describe(code); act_path = substr($0, 13); act_time = now()
  if (changes != "" && act != "checking") print $0 > changes
  if (phase == "scan") { phase = "transfer"; scan_done = act_time }
  render(0)
  next
}

/ files\.\.\.$/ {
  scanned = $1
  render(0)
  next
}

/^building file list/ { next }

/ files to consider$/ {
  total_files = $1; chk_done = 0; checked = 0
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
    total_files = fc[2]; chk_done = fc[2] - fc[1]
  }
  render(0)
  next
}

/^[[:space:]]*$/ { next }

{
  # rsync's final statistics: the transfer is over
  if ($0 ~ /^Number of files: /) phase = "done"
  clear_line()
  print "    " $0
  fflush()
}

END {
  if (changes != "") close(changes)
  if (last_draw) show(sprintf("%s finished after %s", label, hms(now() - start)), 1)
  clear_line()
}
