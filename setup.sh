#!/usr/bin/env bash
# Checks that this machine is ready for the lab and offers to fix what's missing.
# Tested on Ubuntu 24.04, the only system where it also installs system packages (apt, Docker).
# Every change asks first: apt, sudo, your shell rc, mise installs.
#
#   ./setup.sh           check everything and offer to fix what's missing
#   ./setup.sh --yes     same, answering yes to every question
#   ./setup.sh --check   only check, change nothing (`just up` runs this first)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mode=setup
assume_yes=false
for arg in "$@"; do
  case $arg in
    --check) mode=check ;;
    -y | --yes) assume_yes=true ;;
    -h | --help) sed -n '2,8s/^# \{0,1\}//p' "$0" && exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2 && exit 2 ;;
  esac
done

lab_node=back-control-plane # kind's node container for the "back" cluster
ports=(80 443 4566)         # host ports mapped in cluster/kind.yaml
min_ram_gib=8
min_disk_gib=10
me=$(id -un)

# --- Output, prompts, privileges ---------------------------------------------

if [[ -t 1 ]]; then
  bold=$'\e[1m' green=$'\e[32m' yellow=$'\e[33m' red=$'\e[31m' reset=$'\e[0m'
else
  bold='' green='' yellow='' red='' reset=''
fi
problems=0
section() { printf '\n%s%s%s\n' "$bold" "$1" "$reset"; }
ok() { printf '  %sok%s    %s\n' "$green" "$reset" "$1"; }
warn() { printf '  %swarn%s  %s\n' "$yellow" "$reset" "$1"; }
fail() {
  printf '  %sfail%s  %s\n' "$red" "$reset" "$1"
  problems=$((problems + 1))
}
hint() { printf '        %s\n' "$1"; }

# Succeeds if the user agrees to a change. Never asks in --check mode or without a terminal.
ask() {
  [[ $mode == check ]] && return 1
  $assume_yes && return 0
  [[ -t 0 ]] || return 1
  local reply
  read -rp "        $1 [y/N] " reply
  [[ $reply == [yY]* ]]
}

# Runs a command as root: directly when already root, through sudo otherwise.
as_root() { if ((EUID == 0)); then "$@"; else sudo "$@"; fi; }
can_sudo() { ((EUID == 0)) || command -v sudo >/dev/null; }
apt_install() {
  as_root apt-get update -qq &&
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
}

# --- System ------------------------------------------------------------------

section "System"
# shellcheck source=/dev/null
if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
system_name=${PRETTY_NAME:-$(uname -sr)}
if [[ -z ${PRETTY_NAME:-} ]] && command -v sw_vers >/dev/null; then system_name="macOS $(sw_vers -productVersion)"; fi
is_ubuntu=false
if [[ ${ID:-} == ubuntu ]]; then is_ubuntu=true; fi
if $is_ubuntu && [[ ${VERSION_ID:-} == 24.04 ]]; then
  ok "$system_name"
elif $is_ubuntu; then
  warn "$system_name: the lab is tested on Ubuntu 24.04"
else
  warn "$system_name: the lab is tested on Ubuntu 24.04; install system packages (curl, git, Docker) yourself"
fi

# --- Base tools --------------------------------------------------------------

section "Base tools"
missing=()
for tool in curl git; do
  if command -v "$tool" >/dev/null; then ok "$tool"; else missing+=("$tool"); fi
done
if ((${#missing[@]} > 0)); then
  if $is_ubuntu && can_sudo && ask "Install ${missing[*]} with apt?" && apt_install "${missing[@]}"; then
    ok "${missing[*]} installed"
  else
    fail "missing: ${missing[*]}"
  fi
fi

# --- Docker ------------------------------------------------------------------

section "Docker"

# Docker Engine from Docker's own apt repository, as in https://docs.docker.com/engine/install/ubuntu/
install_docker() {
  apt_install ca-certificates curl &&
    as_root install -m 0755 -d /etc/apt/keyrings &&
    as_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc &&
    as_root chmod a+r /etc/apt/keyrings/docker.asc &&
    printf '%s\n' \
      "Types: deb" \
      "URIs: https://download.docker.com/linux/ubuntu" \
      "Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" \
      "Components: stable" \
      "Architectures: $(dpkg --print-architecture)" \
      "Signed-By: /etc/apt/keyrings/docker.asc" |
    as_root tee /etc/apt/sources.list.d/docker.sources >/dev/null &&
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin &&
    { ((EUID == 0)) || as_root usermod -aG docker "$me"; }
}

# Prints one of: missing, not-running, no-permission, ok
docker_state() {
  local err
  if ! command -v docker >/dev/null; then
    echo missing
  elif err=$(docker info 2>&1 >/dev/null); then
    echo ok
  elif [[ $err == *"permission denied"* ]]; then
    echo no-permission
  else
    echo not-running
  fi
}
in_docker_group() { id -nG "$me" | tr ' ' '\n' | grep -qx docker; }
has_systemd() { command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; }

state=$(docker_state)
if [[ $state == missing ]] && $is_ubuntu && can_sudo &&
  ask "Docker isn't installed. Install Docker Engine from Docker's apt repository and add $me to the docker group?"; then
  if install_docker; then ok "Docker Engine installed"; else fail "Docker Engine installation failed (see above)"; fi
  state=$(docker_state)
fi
if [[ $state == not-running ]] && has_systemd && can_sudo &&
  ask "The Docker daemon isn't running. Start it now and at boot (systemctl enable --now docker)?"; then
  as_root systemctl enable --now docker || true
  state=$(docker_state)
fi
if [[ $state == no-permission ]] && ! in_docker_group && can_sudo &&
  ask "Add $me to the docker group, so Docker works without sudo?"; then
  as_root usermod -aG docker "$me" || true
fi

docker_ok=false
case $state in
  ok)
    docker_ok=true
    ok "Docker $(docker version --format '{{.Server.Version}}') is running"
    ;;
  missing)
    fail "Docker isn't installed"
    if $is_ubuntu; then hint "https://docs.docker.com/engine/install/ubuntu/"; else hint "https://docs.docker.com/get-started/get-docker/"; fi
    ;;
  not-running)
    fail "the Docker daemon isn't running"
    if has_systemd; then hint "sudo systemctl enable --now docker"; else hint "start Docker, then run this again"; fi
    ;;
  no-permission)
    if in_docker_group; then
      fail "$me is in the docker group, but this session started before that"
      hint "log out and back in (or run: newgrp docker), then run ./setup.sh again"
    else
      fail "$me can't use Docker without sudo"
      hint "sudo usermod -aG docker $me, then log out and back in"
    fi
    ;;
esac

# --- Resources ---------------------------------------------------------------

section "Resources"
if [[ -r /proc/meminfo ]]; then
  ram_gib=$(awk '/^MemTotal:/ { printf "%.0f", $2 / 1048576 }' /proc/meminfo)
elif ram_bytes=$(sysctl -n hw.memsize 2>/dev/null); then
  ram_gib=$(awk -v bytes="$ram_bytes" 'BEGIN { printf "%.0f", bytes / 1073741824 }')
else
  ram_gib=''
fi
if [[ -z $ram_gib ]]; then
  warn "couldn't measure the RAM"
elif ((ram_gib >= min_ram_gib)); then
  ok "$ram_gib GiB of RAM"
else
  warn "$ram_gib GiB of RAM: the lab uses about 4 GiB and grows as components are added ($min_ram_gib GiB recommended)"
fi

docker_dir=/var/lib/docker
if $docker_ok; then docker_dir=$(docker info --format '{{.DockerRootDir}}'); fi
if [[ ! -d $docker_dir ]]; then docker_dir=/; fi
free_gib=$(df -Pk "$docker_dir" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }') || free_gib=''
if [[ -z $free_gib ]]; then
  warn "couldn't measure the free disk space"
elif ((free_gib >= min_disk_gib)); then
  ok "$free_gib GiB free for Docker"
else
  warn "$free_gib GiB free for Docker: the lab uses about 8 GiB and grows as components are added ($min_disk_gib GiB recommended)"
fi

# --- Ports -------------------------------------------------------------------

section "Ports"
port_in_use() {
  if command -v ss >/dev/null; then
    [[ -n $(ss -Hltn "sport = :$1") ]]
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}
if $docker_ok && [[ -n $(docker ps --quiet --filter "name=^${lab_node}\$") ]]; then
  port_list=$(printf '%s, ' "${ports[@]}")
  ok "ports ${port_list%, } are held by the running lab cluster"
else
  for port in "${ports[@]}"; do
    if ! port_in_use "$port"; then
      ok "port $port is free"
      continue
    fi
    fail "port $port is already in use"
    if command -v ss >/dev/null; then
      hint "see by what: sudo ss -ltnp 'sport = :$port'"
    else
      hint "see by what: sudo lsof -nP -iTCP:$port -sTCP:LISTEN"
    fi
  done
fi

# --- mise and the toolchain --------------------------------------------------

section "mise"
mise_bin=$(command -v mise || true)
if [[ -z $mise_bin && -x $HOME/.local/bin/mise ]]; then mise_bin=$HOME/.local/bin/mise; fi
if [[ -z $mise_bin ]] && command -v curl >/dev/null &&
  ask "mise isn't installed. Install it with its official installer (no sudo, into ~/.local/bin)?"; then
  if curl -fsSL https://mise.run | sh; then mise_bin=$HOME/.local/bin/mise; fi
fi

if [[ -z $mise_bin ]]; then
  fail "mise isn't installed"
  hint "https://mise.jdx.dev/getting-started.html"
else
  ok "mise $("$mise_bin" --version 2>/dev/null | cut -d' ' -f1)"

  # The versions pinned in mise.toml. No stdin, so mise can't prompt on its own.
  toolchain_status() { "$mise_bin" ls --local --missing </dev/null 2>&1; }
  if ! status=$(toolchain_status) || [[ -n $status ]]; then
    if ask "Install the toolchain pinned in mise.toml (trusts the file; tools go under ~/.local/share/mise)?"; then
      if "$mise_bin" trust --quiet; then "$mise_bin" install || true; fi
    fi
  fi
  if ! status=$(toolchain_status); then
    if [[ $status == *"not trusted"* ]]; then
      fail "mise.toml isn't trusted yet"
      hint "run ./setup.sh"
    else
      fail "mise can't use mise.toml:"
      while IFS= read -r line; do hint "$line"; done <<<"$status"
    fi
  elif [[ -n $status ]]; then
    fail "not installed yet: $(awk '{ print $1 }' <<<"$status" | paste -sd ' ' -)"
    hint "run ./setup.sh"
  else
    ok "toolchain from mise.toml installed"
  fi

  # Activation puts the pinned tools and mise.toml's [env] into your shell.
  if [[ -n ${MISE_SHELL:-} ]]; then
    ok "mise is active in this shell"
  else
    shell_name=$(basename "${SHELL:-bash}")
    rc_file=''
    if [[ $shell_name == bash || $shell_name == zsh ]]; then rc_file=$HOME/.${shell_name}rc; fi
    activate_line="eval \"\$($mise_bin activate $shell_name)\""
    if [[ -n $rc_file ]] && grep -qs 'mise activate' "$rc_file"; then
      warn "mise is activated in $rc_file, but not in this shell: open a new terminal"
    elif [[ -n $rc_file ]] && ask "Activate mise in $rc_file (appends one line)?"; then
      printf '\n# mise: pinned tools and per-directory env (added by the BACK lab setup.sh)\n%s\n' \
        "$activate_line" >>"$rc_file"
      warn "mise activation added to $rc_file: open a new terminal to use it"
    else
      warn "mise isn't active in this shell: use 'mise exec -- just up', or activate it with:"
      hint "$activate_line"
    fi
  fi
fi

# --- Summary -----------------------------------------------------------------

section "Summary"
if ((problems > 0)); then
  printf '  %sProblems found: %d. See above.%s\n' "$red" "$problems" "$reset"
  if [[ $mode == check ]] && $is_ubuntu; then hint "./setup.sh can fix most of them"; fi
  exit 1
fi
if [[ $mode == check ]]; then
  echo "  All checks passed."
elif [[ -n ${MISE_SHELL:-} ]]; then
  echo "  Ready. Next: just up"
else
  echo "  Ready. Next: mise exec -- just up (or plain 'just up' in a shell where mise is active)"
fi
