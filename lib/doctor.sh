# shellcheck shell=bash
# `dotfiles doctor`: checks that the install is healthy and says what is not.
# Meant to be sourced; defines functions only. Offline and fast: it never
# downloads anything, never runs `mise install` and never runs sudo.
#
# One line per check, "OK", "WARN" or "FAIL" first. FAIL is something that
# breaks sessions or leaves the profile incomplete; WARN is a missing
# convenience. df_doctor returns 1 when any line is a FAIL, else 0.
# DF_DOCTOR_SKIP_TOOLS=1 (set by install.sh --no-tools) means the tools were
# skipped on purpose: the tool check is then a WARN instead of a FAIL per tool.

_df_doctor_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# One definition of df_ping_group_ok: the one the shell helpers use.
# shellcheck source=shell/netdebug.sh
. "$_df_doctor_root/shell/netdebug.sh"

DF_DOCTOR_FAILS=0
_df_doc_line() { printf '%-4s %s\n' "$1" "$2"; }
_df_doc_ok() { _df_doc_line OK "$1"; }
_df_doc_warn() { _df_doc_line WARN "$1"; }
_df_doc_fail() {
  _df_doc_line FAIL "$1"
  DF_DOCTOR_FAILS=$((DF_DOCTOR_FAILS + 1))
}

# _df_doctor_tools <profile>: the commands the profile's mise tools provide, one
# per line (the command, not the mise name: trippy is `trip`). They come from
# config/mise/commands.<profile> next to the mise configs: minimal has none,
# server the server file, workstation the server file and its own.
_df_doctor_tools() {
  local dir="$_df_doctor_root/config/mise" file
  local -a files=()
  case "$1" in
    server) files=(server) ;;
    workstation) files=(server workstation) ;;
  esac
  for file in ${files[@]+"${files[@]}"}; do
    [ -r "$dir/commands.$file" ] || return 1
    awk '{ sub(/#.*/, "") } NF { print $1 }' "$dir/commands.$file"
  done
}

# Packages the dotfiles lean on but do not install: their absence is a WARN.
DF_DOCTOR_PACKAGES=(git screen curl ssh openssl ping)

# _df_doctor_clean <bash args...>: bash in the environment a bare ssh or cron
# session starts with (nothing inherited from the caller's shell), with stderr
# folded into stdout so that any noise at all shows up.
_df_doctor_clean() {
  local -a limit=()
  if command -v timeout >/dev/null 2>&1; then limit=(timeout 30); fi
  ${limit[@]+"${limit[@]}"} env -i HOME="$HOME" USER="${USER:-$(id -un)}" \
    PATH=/usr/local/bin:/usr/bin:/bin bash "$@" 2>&1 </dev/null
}

# _df_doctor_session <label> <bash args...>: the session must print exactly "ok".
_df_doctor_session() {
  local label="$1" out
  shift
  out="$(_df_doctor_clean "$@")" || :
  if [ "$out" = ok ]; then
    _df_doc_ok "$label: prints only ok"
  else
    _df_doc_fail "$label: expected exactly 'ok', got: $(printf '%s' "$out" | head -c 80 | tr -c '[:print:]' ' ')"
  fi
}

# _df_doctor_path_order <label> <bash args...>: ~/.local/bin must not come
# before /usr/bin in the session's PATH, or it would shadow system tools for
# scripts and ssh commands. The last line of output is the PATH.
_df_doctor_path_order() {
  local label="$1" out path part i=0 mine=-1 sys=-1
  local -a parts=()
  shift
  out="$(_df_doctor_clean "$@")" || :
  path="$(tail -n 1 <<<"$out")"
  IFS=: read -ra parts <<<"$path"
  for part in "${parts[@]}"; do
    if [ "$part" = "$HOME/.local/bin" ] && [ "$mine" -lt 0 ]; then mine=$i; fi
    if [ "$part" = /usr/bin ] && [ "$sys" -lt 0 ]; then sys=$i; fi
    i=$((i + 1))
  done
  if [ "$mine" -ge 0 ] && [ "$sys" -ge 0 ] && [ "$mine" -lt "$sys" ]; then
    _df_doc_fail "PATH order: $label: ~/.local/bin comes before /usr/bin"
  else
    _df_doc_ok "PATH order: $label: ~/.local/bin does not shadow /usr/bin"
  fi
}

# Run in a login shell, the way a real session finds its tools: one line
# "missing <tool>" per absent command, and "trip <real path>" when trippy is
# there (for the capability hint; mise shims cannot take a capability).
# shellcheck disable=SC2016  # expanded by the inner bash
_DF_DOCTOR_SCAN='
for t in "$@"; do
  command -v "$t" >/dev/null 2>&1 || echo "missing $t"
done
if command -v trip >/dev/null 2>&1; then
  p="$(cd / && mise which trip 2>/dev/null)" || p=""
  [ -n "$p" ] || p="$(command -v trip)"
  echo "trip $p"
fi'

_df_doctor_check_tools() {
  local profile="$1" out kind rest trip_path='' missing=0
  local -a tools=()
  if [ "$profile" != minimal ] && [ -n "${DF_DOCTOR_SKIP_TOOLS:-}" ]; then
    _df_doc_warn "tools: not checked, they were skipped on purpose (--no-tools); run install.sh again without it"
    return 0
  fi
  # A missing command list is a broken checkout, not a profile without tools.
  mapfile -t tools < <(_df_doctor_tools "$profile" || echo __broken__)
  if [ "${#tools[@]}" -gt 0 ] && [ "${tools[${#tools[@]} - 1]}" = __broken__ ]; then
    _df_doc_fail "tools: no command list for $profile in $_df_doctor_root/config/mise (broken checkout)"
    return 0
  fi
  if [ "${#tools[@]}" -eq 0 ]; then
    if [ "$profile" = minimal ]; then
      _df_doc_ok "tools: none expected for $profile"
    else
      _df_doc_fail "tools: no command list for $profile in $_df_doctor_root/config/mise (broken checkout)"
    fi
    return 0
  fi
  out="$(_df_doctor_clean -lc "$_DF_DOCTOR_SCAN" _ "${tools[@]}")" || :
  while read -r kind rest; do
    case "$kind" in
      missing)
        _df_doc_fail "tool: $rest not found in a login shell (run install.sh again)"
        missing=1
        ;;
      trip) trip_path="$rest" ;;
    esac
  done <<<"$out"
  if [ "$missing" -eq 0 ]; then _df_doc_ok "tools: all ${#tools[@]} found"; fi
  # trippy 0.13 has no unprivileged mode on Linux, whatever ping_group_range says.
  if [ -n "$trip_path" ] && [ "$(id -u)" != 0 ]; then
    if command -v getcap >/dev/null 2>&1 && getcap "$trip_path" 2>/dev/null | grep -q cap_net_raw; then
      _df_doc_ok "trip: $trip_path has cap_net_raw"
    else
      _df_doc_warn "trip: needs CAP_NET_RAW, run it with sudo or give the real binary the capability: sudo setcap cap_net_raw+ep $trip_path"
    fi
  fi
}

# _df_doctor_check_mise_config <profile>: our mise config is a conf.d fragment
# (mise writes into ~/.config/mise/config.toml, which must stay the user's). A
# link at config.toml that points into the checkout is the old layout.
_df_doctor_check_mise_config() {
  local frag="$HOME/.config/mise/conf.d/dotfiles.toml" old="$HOME/.config/mise/config.toml"
  if [ "$1" != minimal ]; then
    if [ -e "$frag" ]; then
      _df_doc_ok "mise config: $frag"
    else
      _df_doc_fail "mise config: $frag is missing (run install.sh again)"
    fi
  fi
  if [ -L "$old" ]; then
    case "$(readlink "$old")" in
      "$_df_doctor_root"/*) _df_doc_warn "mise config: $old still links into the checkout, so mise writes into the repo; run: dotfiles update" ;;
    esac
  fi
}

# _df_doctor_check_path: the old setup put Homebrew on PATH (sometimes through
# /etc/environment, which user scope cannot undo).
_df_doctor_check_path() {
  case ":$PATH:" in
    *:/home/linuxbrew*)
      _df_doc_warn "PATH contains /home/linuxbrew: the old setup may have added it in /etc/environment, which this install cannot undo (as root, remove it there)"
      ;;
    *) _df_doc_ok "PATH: no /home/linuxbrew" ;;
  esac
}

_df_doctor_check_packages() {
  local p
  for p in "${DF_DOCTOR_PACKAGES[@]}"; do
    if command -v "$p" >/dev/null 2>&1; then
      _df_doc_ok "package: $p"
    else
      _df_doc_warn "package: $p is not installed (install it with the system package manager)"
    fi
  done
}

_df_doctor_check_ping() {
  if [ "$(id -u)" = 0 ]; then
    _df_doc_ok "rootless ping: not needed as root"
  elif df_ping_group_ok; then
    _df_doc_ok "rootless ping: allowed by net.ipv4.ping_group_range"
  else
    _df_doc_warn "rootless ping: net.ipv4.ping_group_range excludes your groups, so ping needs root or a setuid ping"
  fi
}

# _df_doctor_check_zsh <profile>: median of three `zsh -i -c exit` runs, as
# information. The profiles with tools expect a zsh; minimal makes do without.
_df_doctor_check_zsh() {
  local zsh i t0 t1 median
  local -a ms=() limit=() sorted=()
  if ! zsh="$(command -v zsh 2>/dev/null)"; then
    if [ "$1" = minimal ]; then
      _df_doc_ok "zsh: not installed (bash is used)"
    else
      _df_doc_warn "zsh: not installed, so interactive shells stay in bash"
    fi
    return 0
  fi
  if command -v timeout >/dev/null 2>&1; then limit=(timeout 30); fi
  for i in 1 2 3; do
    t0="${EPOCHREALTIME/[.,]/}"
    if ! ${limit[@]+"${limit[@]}"} "$zsh" -i -c exit >/dev/null 2>&1 </dev/null; then
      _df_doc_warn "zsh startup: 'zsh -i -c exit' failed"
      return 0
    fi
    t1="${EPOCHREALTIME/[.,]/}"
    ms+=($(((t1 - t0) / 1000)))
  done
  mapfile -t sorted < <(printf '%s\n' "${ms[@]}" | sort -n)
  median="${sorted[1]}"
  _df_doc_ok "zsh startup: $median ms (median of 3)"
}

df_doctor() {
  local profile=''
  DF_DOCTOR_FAILS=0
  if [ -r "$HOME/.config/dotfiles/profile" ]; then
    read -r profile <"$HOME/.config/dotfiles/profile" || :
  fi
  case "$profile" in
    minimal | server | workstation) _df_doc_ok "profile: $profile" ;;
    *)
      _df_doc_fail "profile: none saved in ~/.config/dotfiles/profile (run install.sh --profile ...)"
      profile=''
      ;;
  esac

  # `bash -c` reads no startup file; sshd makes bash source ~/.bashrc, which
  # `. ~/.bashrc` reproduces; a login shell reads ~/.bash_profile.
  _df_doctor_session "bash -c" -c 'echo ok'
  _df_doctor_session "bash -lc" -lc 'echo ok'
  _df_doctor_session "ssh-like bash (. ~/.bashrc)" -c '. ~/.bashrc; echo ok'
  # shellcheck disable=SC2016  # expanded by the inner bash
  _df_doctor_path_order "ssh-like" -c '. ~/.bashrc; printf "%s\n" "$PATH"'
  # shellcheck disable=SC2016
  _df_doctor_path_order "login" -lc 'printf "%s\n" "$PATH"'

  if [ -n "$profile" ]; then
    _df_doctor_check_tools "$profile"
    _df_doctor_check_mise_config "$profile"
  fi
  _df_doctor_check_path
  _df_doctor_check_packages
  _df_doctor_check_ping
  _df_doctor_check_zsh "${profile:-minimal}"

  [ "$DF_DOCTOR_FAILS" -eq 0 ]
}
