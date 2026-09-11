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
