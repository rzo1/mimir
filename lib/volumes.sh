# shellcheck shell=bash
# Interactive destination picker and --status viewer.

# Mounted, writable, Finder-visible volumes. Time Machine, snapshots and system volumes are all
# mounted "nobrowse", which filters them out. Prints one mount point per line.
list_volumes() {
  mount | sed -n 's|^.* on \(/Volumes/.*\) (\(.*\))$|\1	\2|p' |
    awk -F'\t' '$2 !~ /nobrowse/ && $2 !~ /read-only/ { print $1 }'
}

describe_volume() {  # describe_volume MOUNTPOINT → "size<TAB>free<TAB>fs<TAB>connection<TAB>encrypted<TAB>backup"
  local mp="$1" dinfo fs proto enc size free last=""
  dinfo=$(diskutil info "$mp" 2>/dev/null)
  fs=$(printf '%s\n' "$dinfo" | sed -n 's/^ *Type (Bundle): *//p')
  proto=$(printf '%s\n' "$dinfo" | sed -n 's/^ *Protocol: *//p')
  if [ -z "$dinfo" ]; then
    fs=$(mount | sed -n "s|^.* on $mp (\([^,)]*\).*|\1|p"); proto="network"
  fi
  if printf '%s\n' "$dinfo" | grep -Eq '^ *(FileVault|Encrypted): *Yes'; then enc="yes"; else enc="NO"; fi
  size=$(df -k "$mp" | awk 'NR == 2 { print $2 }')
  free=$(df -k "$mp" | awk 'NR == 2 { print $4 }')
  if ls "$mp"/mimir/*/last-run.txt >/dev/null 2>&1; then
    # shellcheck disable=SC2012  # our own, well-known file names
    last=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$(ls -t "$mp"/mimir/*/last-run.txt | head -1)")
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(human_kb "$size")" "$(human_kb "$free")" "${fs:-?}" "${proto:-?}" "$enc" "${last:--}"
}

# Sets DEST to the chosen mount point.
pick_volume() {
  local vols=() v i=0 choice
  while IFS= read -r v; do vols+=("$v"); done < <(list_volumes)
  [ "${#vols[@]}" -gt 0 ] || die "no external disk found under /Volumes – connect and mount the disk, or pass a path"

  printf '\n%sChoose the destination disk:%s\n\n' "$C_BLD" "$C_OFF"
  printf "    %s%-3s %-24s %9s %9s  %-6s %-11s %-9s %s%s\n" "$C_DIM" "#" "Volume" "Size" "Free" "FS" "Connection" "Encrypted" "Last Mímir run" "$C_OFF"
  for v in "${vols[@]}"; do
    i=$((i + 1))
    IFS=$'\t' read -r size free fs proto enc last <<EOF
$(describe_volume "$v")
EOF
    [ "$enc" = "NO" ] && enc="${C_YEL}no${C_OFF}       " || enc="yes      "
    printf "    %-3s %-24s %9s %9s  %-6s %-11s %s %s\n" "$i)" "$(basename "$v" | cut -c1-24)" "$size" "$free" "$fs" "$proto" "$enc" "$last"
  done
  printf '\n'

  while :; do
    if [ "${#vols[@]}" = 1 ]; then
      read -r -p "    Destination [1, q to quit] (Enter = 1): " choice || exit 1
      [ -n "$choice" ] || choice=1
    else
      read -r -p "    Destination [1-${#vols[@]}, q to quit]: " choice || exit 1
    fi
    case "$choice" in
      q|Q) exit 1 ;;
      *[!0-9]*|'') ;;
      *) if [ "$choice" -ge 1 ] && [ "$choice" -le "${#vols[@]}" ]; then
           # shellcheck disable=SC2034  # DEST is read by the main script
           DEST="${vols[choice-1]}"; return 0
         fi ;;
    esac
    printf '    please enter a number between 1 and %s\n' "${#vols[@]}"
  done
}

# --status: follow a running backup from another terminal
show_status() {
  local file="$STATUS_FILE" pid t label line age
  [ -f "$HOST_DIR/.lock" ] || { info "no Mímir run is active for $HOST_DIR"; [ -f "$HOST_DIR/last-run.txt" ] && cat "$HOST_DIR/last-run.txt"; return 0; }
  pid=$(cat "$HOST_DIR/.lock")
  printf 'Following Mímir (PID %s) → %s   (Ctrl-C stops watching, not the backup)\n\n' "$pid" "$HOST_DIR"
  while kill -0 "$pid" 2>/dev/null; do
    if [ -f "$file" ]; then
      { read -r t; read -r label; read -r line; } <"$file"
      age=$(( $(date +%s) - ${t:-0} ))
      printf '\r\033[K    [%s] %s  %s(%ss ago)%s' "$label" "$line" "$C_DIM" "$age" "$C_OFF"
    fi
    sleep 2
  done
  printf '\r\033[K'
  info "run finished"
  [ -f "$HOST_DIR/last-run.txt" ] && cat "$HOST_DIR/last-run.txt"
}
