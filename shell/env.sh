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

# Interactive shells let our tools win; non-interactive ones (ssh host cmd, CI)
# keep the system and pinned tools first and see ours only as a fallback.
case "$-" in
  *i*) _df_where=front ;;
  *) _df_where=back ;;
esac
_df_path_add "$_df_where" "$HOME/.local/bin"
_df_path_add "$_df_where" "$HOME/.local/share/mise/shims"
unset _df_where

# The workstation profile selects the mise environment with extra tools.
_df_profile=
if [ -r "$HOME/.config/dotfiles/profile" ]; then
  read -r _df_profile <"$HOME/.config/dotfiles/profile" || :
fi
if [ "$_df_profile" = workstation ]; then
  MISE_ENV=workstation
  export MISE_ENV
fi
unset _df_profile

# WSL hook (added with the WSL support): source "$DOTFILES_DIR/shell/wsl.sh"
# here when running under WSL.

# Per-machine overrides, kept out of git.
if [ -r "$HOME/.config/dotfiles/env.local" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.config/dotfiles/env.local"
fi
