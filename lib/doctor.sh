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
#
# Commands and PATH are judged as a NEW terminal sees them (a login shell started
# with nothing inherited, see _df_doctor_clean), not as the shell that runs the
# doctor does: install.sh runs it from the old shell, whose PATH has more in it.
# DF_ETC_ENVIRONMENT_FILE (like DF_LINUXBREW_PREFIX and DF_LOGIN_SHELL, see
# lib/detect.sh) replaces /etc/environment and exists for tests only.

# The most an interactive zsh may take to start before the doctor warns, in ms.
# WSL1 starts processes slowly, which is what the budget is mostly about.
# DF_DOCTOR_ZSH_BUDGET_MS overrides it and exists for tests only.
DF_ZSH_STARTUP_BUDGET_MS="${DF_DOCTOR_ZSH_BUDGET_MS:-600}"
case "$DF_ZSH_STARTUP_BUDGET_MS" in
  '' | *[!0-9]*) DF_ZSH_STARTUP_BUDGET_MS=600 ;;
esac

_df_doctor_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# One definition of df_ping_group_ok: the one the shell helpers use.
# shellcheck source=shell/netdebug.sh
. "$_df_doctor_root/shell/netdebug.sh"
# df_linuxbrew_prefix and df_login_shell.
# shellcheck source=lib/detect.sh
. "$_df_doctor_root/lib/detect.sh"

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

# _df_doctor_start_path: the PATH a login starts with before any shell file runs. pam_env sets
# it from the PATH= line of /etc/environment for ssh and console logins, so the probe starts
# there too (the line is parsed, never sourced; one that needs a shell to evaluate, or that
# is not a plain value, is ignored); otherwise the usual default.
_df_doctor_start_path() {
  local file="${DF_ETC_ENVIRONMENT_FILE:-/etc/environment}" line v=""
  if [ -r "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?PATH=(.*)$ ]]; then v="${BASH_REMATCH[2]}"; fi
    done <"$file"
  fi
  v="${v#\"}"
  v="${v%\"}"
  v="${v#\'}"
  v="${v%\'}"
  case "$v" in
    '' | *'$'* | *'`'* | *'"'* | *"'"* | *[[:space:]]* | *\* | *\;* | *\&* | *\|* | *\(* | *\)* | *\<* | *\>* | *\** | *\?*) v="" ;;
  esac
  printf '%s' "${v:-/usr/local/bin:/usr/bin:/bin}"
}

# _df_doctor_clean <bash args...>: bash in the environment a bare ssh or cron
# session starts with (nothing inherited from the caller's shell, PATH from
# _df_doctor_start_path), with stderr folded into stdout so that any noise at all
# shows up.
_df_doctor_clean() {
  local -a limit=()
  if command -v timeout >/dev/null 2>&1; then limit=(timeout 30); fi
  ${limit[@]+"${limit[@]}"} env -i HOME="$HOME" USER="${USER:-$(id -un)}" \
    PATH="$(_df_doctor_start_path)" bash "$@" 2>&1 </dev/null
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
# "missing <tool>" per absent command (_DF_DOCTOR_FIND), and "trip <real path>"
# when trippy is there (for the capability hint; mise shims cannot take a
# capability).
# shellcheck disable=SC2016  # expanded by the inner bash
_DF_DOCTOR_FIND='
for t in "$@"; do
  command -v "$t" >/dev/null 2>&1 || echo "missing $t"
done'
# shellcheck disable=SC2016
_DF_DOCTOR_SCAN="$_DF_DOCTOR_FIND"'
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

# _df_doctor_check_path: linuxbrew in the PATH of a fresh login session. The old
# setup loaded it from its shell files; the migration keeps brew-only commands
# reachable through a marked block in env.local that appends it last. That block
# is fine (system tools still win); brew anywhere else, or in front of /usr/bin,
# is not what this install put there. A login shell inside the brew prefix while
# a fresh session has no brew means `zsh` and friends are gone from PATH.
_df_doctor_check_path() {
  local prefix out path part i=0 brew=-1 sys=-1 login where msg env_file etc_has
  local -a parts=()
  prefix="$(df_linuxbrew_prefix)"
  out="$(_df_doctor_clean -lc 'printf "%s\n" "$PATH"')" || :
  path="$(tail -n 1 <<<"$out")"
  IFS=: read -ra parts <<<"$path"
  for part in "${parts[@]}"; do
    case "$part" in
      "$prefix" | "$prefix"/*)
        if [ "$brew" -lt 0 ]; then brew=$i; fi
        ;;
      /usr/bin)
        if [ "$sys" -lt 0 ]; then sys=$i; fi
        ;;
    esac
    i=$((i + 1))
  done
  # A brew that /etc/environment holds reaches every ssh and console login through pam_env, and
  # the marked block of env.local does not account for it. Some distributions reset PATH in
  # /etc/profile, which hides it from this login probe; the file is looked at too.
  env_file="${DF_ETC_ENVIRONMENT_FILE:-/etc/environment}"
  etc_has=0
  if grep -sv '^[[:space:]]*#' "$env_file" | grep -qF -e linuxbrew -e "$prefix"; then etc_has=1; fi
  if [ "$brew" -lt 0 ]; then
    if [ "$etc_has" = 1 ]; then
      _df_doc_warn "PATH: linuxbrew ($prefix) is on the PATH of ssh and console logins through /etc/environment (pam_env), which this install cannot undo (as root, remove it there)"
      return 0
    fi
    login="$(df_login_shell)"
    case "$login" in
      "$prefix"/*)
        _df_doc_warn "PATH: login shell $login lives in linuxbrew, which a fresh login session does not have on PATH, so zsh and the other brew commands are not found by name; keep brew on PATH (the dotfiles migration does it through env.local) or change the login shell to a system one"
        ;;
      *) _df_doc_ok "PATH: no linuxbrew in a fresh login session" ;;
    esac
    return 0
  fi
  if [ "$sys" -lt 0 ] || [ "$brew" -gt "$sys" ]; then where=after; else where=before; fi
  if [ "$where" = after ] && [ "$etc_has" = 0 ] && grep -qxF -- "$DF_LINUXBREW_BEGIN" "$HOME/.config/dotfiles/env.local" 2>/dev/null; then
    _df_doc_ok "PATH: linuxbrew on PATH (appended last) through env.local; remove the block when brew is gone"
    return 0
  fi
  if [ "$where" = before ]; then
    msg="PATH: linuxbrew ($prefix) comes before /usr/bin in a fresh login session, so its tools shadow the system's; look in ~/.config/dotfiles/env.local, ~/.profile and ~/.bash_profile"
  else
    msg="PATH: linuxbrew ($prefix) is on a fresh login session's PATH, but not through the marked block of the dotfiles migration in env.local; find where it is set (~/.profile, ~/.bash_profile, /etc/profile.d) or replace that with the block"
  fi
  if [ "$etc_has" = 1 ]; then
    msg="$msg; /etc/environment sets it, which this install cannot undo (as root, remove it there)"
  fi
  _df_doc_warn "$msg"
}

# _df_doctor_check_packages: one fresh login session answers for all of them. A package that
# only this shell's PATH has is not there for a new terminal, and the line says where it is.
_df_doctor_check_packages() {
  local p out here
  out="$(_df_doctor_clean -lc "$_DF_DOCTOR_FIND" _ "${DF_DOCTOR_PACKAGES[@]}")" || :
  for p in "${DF_DOCTOR_PACKAGES[@]}"; do
    case $'\n'"$out"$'\n' in
      *$'\nmissing '"$p"$'\n'*)
        if here="$(command -v "$p" 2>/dev/null)"; then
          _df_doc_warn "package: $p is not in the PATH of a fresh login session (only in this shell: $here); install it with the system package manager"
        else
          _df_doc_warn "package: $p is not installed (install it with the system package manager)"
        fi
        ;;
      *) _df_doc_ok "package: $p" ;;
    esac
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

# _df_doctor_check_zsh <profile>: median of three `zsh -i -c exit` runs; over
# DF_ZSH_STARTUP_BUDGET_MS it is a WARN. The profiles with tools expect a zsh;
# minimal makes do without.
# The zsh is the one a fresh login session finds (a login shell run with the
# environment cleared), not one that only this shell's PATH has.
_df_doctor_check_zsh() {
  local zsh i t0 t1 median hint
  local -a ms=() limit=() sorted=()
  zsh="$(_df_doctor_clean -lc 'command -v zsh' | tail -n 1)" || zsh=""
  case "$zsh" in
    /*) ;;
    *) zsh="" ;;
  esac
  if [ -z "$zsh" ]; then
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
  if [ "$median" -le "$DF_ZSH_STARTUP_BUDGET_MS" ]; then
    _df_doc_ok "zsh startup: $median ms (median of 3)"
    return 0
  fi
  hint=""
  df_detect
  if [ "$DF_WSL" = 1 ]; then
    hint="; on WSL1 starting a process is slow, and the usual causes are mise activate and ~/.localrc (yours); WSL2 starts processes natively"
  fi
  _df_doc_warn "zsh startup: $median ms (median of 3), over the $DF_ZSH_STARTUP_BUDGET_MS ms budget$hint"
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
