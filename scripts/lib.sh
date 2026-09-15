# Output helpers for the lab's scripts.
# shellcheck shell=bash disable=SC2034
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  bold=$'\e[1m' dim=$'\e[2m' green=$'\e[32m' yellow=$'\e[33m' red=$'\e[31m' reset=$'\e[0m'
else
  bold='' dim='' green='' yellow='' red='' reset=''
fi
problems=0
section() { printf '\n%s%s%s\n' "$bold" "$1" "$reset"; }
ok() { printf '  %sok%s    %s\n' "$green" "$reset" "$1"; }
waiting() { printf '  %swait%s  %s\n' "$dim" "$reset" "$1"; }
warn() { printf '  %swarn%s  %s\n' "$yellow" "$reset" "$1"; }
fail() {
  printf '  %sfail%s  %s\n' "$red" "$reset" "$1"
  problems=$((problems + 1))
}
hint() { printf '        %s\n' "$1"; }
# A tool's last line may not end with a newline.
details() { while IFS= read -r line || [[ -n $line ]]; do hint "$line"; done; }

lab_log=.logs/lab.log

command_line() { # command...
  local width i arg marker='$' continuation lines=() quoted=()
  width=$(($(tput cols 2>/dev/null || echo 80) - 10))
  for arg in "$@"; do quoted+=("$(printf '%q' "$arg")"); done
  # Lines break only between arguments, so each one stays pasteable.
  mapfile -t lines < <(printf '%s\n' "${quoted[@]}" | awk -v width="$width" '
    { if (line == "") { line = $0 }
      else if (length(line) + 1 + length($0) <= width) { line = line " " $0 }
      else { print line; line = $0 } }
    END { if (line != "") print line }')
  for i in "${!lines[@]}"; do
    continuation=''
    if ((i < ${#lines[@]} - 1)); then continuation=" \\"; fi
    printf '      %s%s %s%s%s\n' "$dim" "$marker" "${lines[i]}" "$continuation" "$reset"
    marker=' '
  done
}

# What the command printed is left in $spun.
spun=''
spin() { # label command...
  local label=$1 log status=0 pid frames='-\|/' i=0
  shift
  log=$(mktemp)
  if [[ -t 1 ]]; then
    "$@" >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s     %s' "$dim" "${frames:i++%4:1}" "$reset" "$label"
      sleep 0.2
    done
    wait "$pid" || status=$?
    printf '\r\e[K'
  else
    "$@" >"$log" 2>&1 || status=$?
  fi
  spun=$(cat "$log")
  rm -f "$log"
  return $status
}

run() { # label command...
  local label=$1 status=0
  shift
  command_line "$@"
  spin "$label" "$@" || status=$?
  mkdir -p "${lab_log%/*}"
  { printf '\n=== %s  %s\n$ %s\n' "$(date -u +%FT%TZ)" "$label" "$(printf '%q ' "$@")"
    printf '%s\n' "$spun"; } >>"$lab_log"
  if ((status == 0)); then
    ok "$label"
  else
    fail "$label"
    if [[ -n $spun ]]; then details <<<"$spun"; fi
    hint "this run, and the ones before it: $lab_log"
  fi
  return $status
}

# Names the command that stopped the script; a subshell's failure reaches its parent instead.
crashed() { printf '  %sfail%s  %s\n' "$red" "$reset" "$1" >&2; }
trap '((BASH_SUBSHELL)) || crashed "${BASH_SOURCE[0]##*/}:$LINENO: $BASH_COMMAND"' ERR
