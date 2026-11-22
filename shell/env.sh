# shellcheck shell=sh
# Environment shared by every shell: sourced from ~/.profile, ~/.bashrc and
# ~/.zshenv, and sometimes by /bin/sh (dash) for login shells. It must stay
# POSIX sh and must never print anything.

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
export DOTFILES_DIR

# _df_path_add front|back <dir>: put <dir> on PATH exactly once. "front" also
# moves an entry that is already there (an interactive shell started from a
# non-interactive one inherits it at the back).
_df_path_add() {
  case ":$PATH:" in
    *":$2:"*)
      [ "$1" = front ] || return 0
      _df_rest=":$PATH:"
      while :; do
        case "$_df_rest" in
          *":$2:"*) _df_rest="${_df_rest%%":$2:"*}:${_df_rest#*":$2:"}" ;;
          *) break ;;
        esac
      done
      _df_rest="${_df_rest#:}"
      PATH="${_df_rest%:}"
      unset _df_rest
      ;;
  esac
  case "$1" in
    front) PATH="$2${PATH:+:$PATH}" ;;
    *) PATH="${PATH:+$PATH:}$2" ;;
  esac
  export PATH
}

# _df_path_add_list front|back <a:b:c>: _df_path_add for each directory of a
# colon-separated list; "front" keeps the list's order (the first entry ends up
# first), "back" too (the last entry ends up last).
_df_path_add_list() {
  _df_pl="$2"
  while [ -n "$_df_pl" ]; do
    if [ "$1" = front ]; then
      _df_pe="${_df_pl##*:}"
      case "$_df_pl" in *:*) _df_pl="${_df_pl%:*}" ;; *) _df_pl= ;; esac
    else
      _df_pe="${_df_pl%%:*}"
      case "$_df_pl" in *:*) _df_pl="${_df_pl#*:}" ;; *) _df_pl= ;; esac
    fi
    [ -z "$_df_pe" ] || _df_path_add "$1" "$_df_pe"
  done
  unset _df_pl _df_pe
}

# _df_wsl_detect: set _df_wsl to 0 (not WSL), 1 or 2. /proc/version names
# Microsoft under WSL; WSL2 kernels also say "WSL2" ("...-microsoft-standard-WSL2"),
# WSL1 reports a Windows build as "4.4.0-<build>-Microsoft" (the rule of
# lib/detect.sh). Read with the shell's own `read`, not grep, so a native host
# pays no fork for the question. DF_PROC_VERSION_FILE is the test override that
# lib/detect.sh knows too.
_df_wsl_detect() {
  _df_wsl=0
  if [ -r "${DF_PROC_VERSION_FILE:-/proc/version}" ]; then
    read -r _df_pv <"${DF_PROC_VERSION_FILE:-/proc/version}" || :
    case "${_df_pv:-}" in
      *[Mm][Ii][Cc][Rr][Oo][Ss][Oo][Ff][Tt]*)
        case "$_df_pv" in
          *[Ww][Ss][Ll]2*) _df_wsl=2 ;;
          *) _df_wsl=1 ;;
        esac
        ;;
    esac
    unset _df_pv
  fi
}

# _df_mise_cache_read: succeed when ~/.cache/dotfiles/mise-env.sh (the cached
# mise environment of WSL1 mode, written by shell/mise-cache.sh) exists and is
# fresh, setting _df_mise_dirs (the directories to put in front of PATH) and
# _df_mise_bin (the mise that wrote it) from its two header lines. Shell
# builtins only, not a single fork: it is stale when its mise binary is gone or
# any input is newer, namely the mise configs (the profile uses the fragments
# in conf.d and config*.toml, also through symlinks into the checkout; the
# directories catch a link that is replaced), the mise binaries, the saved
# profile and the installs (the directory and each tool's directory, where a
# new version shows up). Leaves _df_mc (the cache path) set for the caller.
_df_mise_cache_read() {
  _df_mise_cache_check
  _df_mrc=$?
  unset _df_mf _df_mh1 _df_mh2 _df_mh3 _df_mh4
  if [ "$_df_mrc" != 0 ]; then
    _df_mise_dirs=
    _df_mise_bin=
  fi
  return "$_df_mrc"
}
_df_mise_cache_check() {
  _df_mc="$HOME/.cache/dotfiles/mise-env.sh"
  _df_mise_dirs=
  _df_mise_bin=
  [ -r "$_df_mc" ] || return 1
  { IFS=' ' read -r _df_mh1 _df_mh2 _df_mise_dirs && IFS=' ' read -r _df_mh3 _df_mh4 _df_mise_bin; } <"$_df_mc" || return 1
  [ "$_df_mh1 $_df_mh2 $_df_mh3 $_df_mh4" = "# df-mise-dirs # df-mise-bin" ] || return 1
  [ -n "$_df_mise_bin" ] && [ -x "$_df_mise_bin" ] || return 1
  # zsh would stop on a pattern that matches nothing.
  if [ -n "${ZSH_VERSION:-}" ]; then setopt local_options null_glob 2>/dev/null; fi
  for _df_mf in "$_df_mise_bin" "$HOME/.local/bin/mise" "$HOME/.config/dotfiles/profile" \
    "$HOME/.config/mise" "$HOME/.config/mise/conf.d" "$HOME/.local/share/mise/installs" \
    "$HOME"/.config/mise/config*.toml "$HOME"/.config/mise/conf.d/*.toml "$HOME"/.local/share/mise/installs/*; do
    [ "$_df_mf" -nt "$_df_mc" ] && return 1
  done
  return 0
}

_df_profile=
if [ -r "$HOME/.config/dotfiles/profile" ]; then
  read -r _df_profile <"$HOME/.config/dotfiles/profile" || :
fi

_df_wsl_detect

# Interactive shells let our tools win; non-interactive ones (ssh host cmd, CI)
# keep the system and pinned tools first and see ours only as a fallback.
case "$-" in
  *i*) _df_where=front ;;
  *) _df_where=back ;;
esac
# ~/bin is where the distributions' skeleton profiles put user scripts, but only
# when it exists. ~/.local/bin gets the same treatment (and, in an interactive
# shell, ends up in front of it).
if [ -d "$HOME/bin" ]; then _df_path_add "$_df_where" "$HOME/bin"; fi
_df_path_add "$_df_where" "$HOME/.local/bin"
# The mise shims belong to the profiles that install tools; a minimal host
# never resolves a command through them. A shim starts mise, which costs a
# process of its own (about 0.8 s on WSL1), so a non-interactive shell on WSL1
# with a fresh cache of the mise environment gets the real tool directories
# instead, still at the back. Interactive shells put the shims in front as
# always; shell/tools.sh then applies the cache (or activates mise).
case "$_df_profile" in
  server | workstation)
    if [ "$_df_where" = back ] && [ "$_df_wsl" = 1 ] && _df_mise_cache_read; then
      _df_path_add_list back "$_df_mise_dirs"
    else
      _df_path_add "$_df_where" "$HOME/.local/share/mise/shims"
    fi
    ;;
esac
unset _df_where _df_mise_dirs _df_mise_bin _df_mc _df_mrc

# The workstation profile selects the mise environment with extra tools.
if [ "$_df_profile" = workstation ]; then
  MISE_ENV=workstation
  export MISE_ENV
fi
unset _df_profile

# WSL (1 and 2) tweaks.
if [ "$_df_wsl" != 0 ] && [ -r "$DOTFILES_DIR/shell/wsl.sh" ]; then
  # shellcheck source=shell/wsl.sh
  . "$DOTFILES_DIR/shell/wsl.sh"
fi
unset _df_wsl

# The helpers above are for this file and shell/tools.sh; a non-interactive
# shell has no other use for them.
case "$-" in
  *i*) ;;
  *) unset -f _df_path_add_list _df_wsl_detect _df_mise_cache_read _df_mise_cache_check ;;
esac

# Per-machine overrides, kept out of git.
if [ -r "$HOME/.config/dotfiles/env.local" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.config/dotfiles/env.local"
fi
