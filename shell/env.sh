# shellcheck shell=sh
# Environment shared by every shell: sourced from ~/.profile, ~/.bashrc and
# ~/.zshenv, and sometimes by /bin/sh (dash) for login shells. It must stay
# POSIX sh and must never print anything.

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
export DOTFILES_DIR

# _df_path_add front|back|drop <dir>[:<dir>...]: edit PATH, every directory of the colon-separated
# list exactly once (empty entries of the list are skipped, a repeated one counts once).
#   front  puts the list at the front, in its order (the first entry ends up first), and moves an
#          entry that is already on PATH there (an interactive shell started from a non-interactive
#          one inherits ours at the back);
#   back   appends the entries that are missing, in order, and never moves one that is there;
#   drop   takes every occurrence of the entries off PATH.
# Entries are compared as whole strings (a glob character or a space in a directory matches only
# itself, /usr/bin is not /usr/bin2). The other entries of PATH, empty ones too, keep their places.
#
# The cost is linear in the length of PATH: PATH is split once, by the shell's own field splitting
# on ":" (noglob, so a "*" in a directory stays a "*"), and each piece is looked up with `case` on
# a quoted, hence literal, pattern. The old way, ${p%%":$d:"*} in a loop, matched a pattern as long
# as the directory at every position of PATH: 32 of those on a WSL PATH of 2.8 KB took 1.2 s in bash
# and 3.4 s in zsh. Splitting with ${x%%:*} and ${x#*:} is no better in zsh (it re-tests the whole
# string at every position), which is why the split is a `for` over the expansion. No fork, no
# output; IFS and noglob are put back as the caller had them (zsh: `emulate -L sh` makes the
# function use sh's word splitting and restores the options by itself).
_df_path_add() {
  if [ -n "${ZSH_VERSION:-}" ]; then emulate -L sh; fi
  _df_pa_ifs_set="${IFS+x}"
  _df_pa_ifs="${IFS-}"
  case "$-" in
    *f*) _df_pa_noglob=1 ;;
    *) _df_pa_noglob= ;;
  esac
  set -f
  IFS=:
  # _df_pa_set holds the list as ":a:b:" (no empty and no repeated entry), so that a lookup is one
  # `case` on ":$entry:".
  _df_pa_set=:
  _df_pa_last=
  # shellcheck disable=SC2086  # split on ":" on purpose
  for _df_pa_e in ${2-}; do
    if [ -n "$_df_pa_e" ]; then
      _df_pa_last="$_df_pa_e"
      case "$_df_pa_set" in
        *":$_df_pa_e:"*) ;;
        *) _df_pa_set="$_df_pa_set$_df_pa_e:" ;;
      esac
    fi
  done
  case "$1" in
    front | drop)
      # Does PATH hold any of them? If not, there is nothing to take out.
      _df_pa_hit=
      # shellcheck disable=SC2086
      for _df_pa_e in $_df_pa_set; do
        if [ -n "$_df_pa_e" ]; then
          case ":$PATH:" in
            *":$_df_pa_e:"*)
              _df_pa_hit=1
              break
              ;;
          esac
        fi
      done
      if [ -n "$_df_pa_hit" ]; then
        # One pass over PATH. Shells disagree on whether a trailing ":" ends a field list or
        # starts an empty field, so ":x" is appended and the last field (that "x") is never kept:
        # each field is judged when the next one arrives.
        _df_pa_out=
        _df_pa_p="$PATH:x"
        _df_pa_n=0
        _df_pa_ne=0
        _df_pa_ee=0
        # shellcheck disable=SC2086
        for _df_pa_e in $_df_pa_p; do
          if [ "$_df_pa_n" = 1 ]; then
            # What a removal of the list's last entry alone would leave: counted for the rule below.
            if [ -z "$_df_pa_prev" ]; then
              _df_pa_ee=$((_df_pa_ee + 1))
            elif [ "$_df_pa_prev" != "$_df_pa_last" ]; then
              _df_pa_ne=$((_df_pa_ne + 1))
            fi
            _df_pa_keep=1
            if [ -n "$_df_pa_prev" ]; then
              case "$_df_pa_set" in
                *":$_df_pa_prev:"*) _df_pa_keep= ;;
              esac
            fi
            if [ -n "$_df_pa_keep" ]; then _df_pa_out="$_df_pa_out$_df_pa_prev:"; fi
          fi
          _df_pa_prev="$_df_pa_e"
          _df_pa_n=1
        done
        # A lone empty entry is dropped, as it always was: `drop` leaves ":" alone behind, and
        # `front` goes entry by entry from the list's end, so the first removal (of its last entry)
        # is the one that can leave the empty entry alone (later steps keep that entry in PATH).
        if [ "$1" = front ]; then
          if [ "$_df_pa_ne" = 0 ] && [ "$_df_pa_ee" = 1 ]; then _df_pa_out=; fi
        elif [ "$_df_pa_out" = : ]; then
          _df_pa_out=
        fi
      fi
      _df_pa_front="${_df_pa_set#:}"
      _df_pa_front="${_df_pa_front%:}"
      if [ -n "$_df_pa_hit" ]; then
        # _df_pa_out is "e1:e2:...:" (every entry with its colon), empty when nothing is left;
        # a lone empty entry is ":" and joins to "" (or to "front:" behind a front list).
        if [ "$1" = front ]; then
          if [ -n "$_df_pa_out" ]; then PATH="$_df_pa_front:${_df_pa_out%:}"; else PATH="$_df_pa_front"; fi
        else
          PATH="${_df_pa_out%:}"
        fi
      elif [ "$1" = front ] && [ -n "$_df_pa_front" ]; then
        PATH="$_df_pa_front${PATH:+:$PATH}"
      fi
      export PATH
      ;;
    *)
      # shellcheck disable=SC2086
      for _df_pa_e in $_df_pa_set; do
        if [ -n "$_df_pa_e" ]; then
          case ":$PATH:" in
            *":$_df_pa_e:"*) ;;
            *)
              PATH="${PATH:+$PATH:}$_df_pa_e"
              export PATH
              ;;
          esac
        fi
      done
      ;;
  esac
  if [ -n "$_df_pa_ifs_set" ]; then IFS="$_df_pa_ifs"; else unset IFS; fi
  if [ -z "$_df_pa_noglob" ]; then set +f; fi
  unset _df_pa_ifs_set _df_pa_ifs _df_pa_noglob _df_pa_set _df_pa_e _df_pa_out _df_pa_hit _df_pa_front _df_pa_p _df_pa_n _df_pa_ne _df_pa_ee _df_pa_last _df_pa_prev _df_pa_keep
}

# _df_path_add_list front|back|drop <a:b:c>: the same call under the name the callers of a list
# use; "front" keeps the list's order (the first entry ends up first), "back" too (the last entry
# ends up last).
_df_path_add_list() {
  _df_path_add "$@"
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
