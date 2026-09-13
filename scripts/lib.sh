# Output helpers for the lab's scripts, in setup.sh's style. Colors only on a terminal, and never with NO_COLOR set.
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

# Everything the commands below print, one run appended after the last.
lab_log=.logs/lab.log

# The command behind a step, dim and wrapped over as many lines as it takes: a step is worth reading
# as the thing it actually runs, and cutting it short would leave out the flags that say what it does.
command_line() { # command...
  local width i marker='$' continuation lines=()
  width=$(($(tput cols 2>/dev/null || echo 80) - 10))
  # Only ever break between arguments: a URL split down the middle reads like a typo.
  mapfile -t lines < <(printf '%q ' "$@" | awk -v width="$width" '
    { for (i = 1; i <= NF; i++) {
        if (line == "") { line = $i }
        else if (length(line) + 1 + length($i) <= width) { line = line " " $i }
        else { print line; line = $i }
      } }
    END { if (line != "") print line }')
  for i in "${!lines[@]}"; do
    continuation=''
    if ((i < ${#lines[@]} - 1)); then continuation=" \\"; fi
    printf '      %s%s %s%s%s\n' "$dim" "$marker" "${lines[i]}" "$continuation" "$reset"
    marker=' '
  done
}

# A noisy command, reported like everything else: the command it runs, then a line that spins so a
# slow step doesn't look like a stuck one. The output goes to the log, and to the screen if it fails.
run() { # label command...
  local label=$1 log status=0 pid frames='-\|/' i=0
  shift
  log=$(mktemp)
  command_line "$@"
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
  mkdir -p "${lab_log%/*}"
  { printf '\n=== %s  %s\n$ %s\n' "$(date -u +%FT%TZ)" "$label" "$(printf '%q ' "$@")"
    cat "$log"; } >>"$lab_log"
  if ((status == 0)); then
    ok "$label"
  else
    fail "$label"
    while IFS= read -r line || [[ -n $line ]]; do hint "$line"; done <"$log"
    hint "this run, and the ones before it: $lab_log"
  fi
  rm -f "$log"
  return $status
}

# Which command stopped the script, functions included (-E). Failures inside a condition stop nothing.
crashed() { printf '  %sfail%s  %s\n' "$red" "$reset" "$1" >&2; }
trap '((BASH_SUBSHELL)) || crashed "${BASH_SOURCE[0]##*/}:$LINENO: $BASH_COMMAND"' ERR
