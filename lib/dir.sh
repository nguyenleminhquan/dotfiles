# shellcheck shell=bash
# Where the checkout lives. Meant to be sourced; defines a function only.
# Used by install.sh, uninstall.sh and bin/dotfiles, so that all of them
# agree. The shell startup files (shell/bashrc, profile, zshenv) have to stay
# POSIX and cannot source this file; they repeat the same three steps inline.
# install.sh repeats them too when it is piped from curl and has no lib yet.
# Keep all of them in sync.

# df_resolve_dir: set and export DOTFILES_DIR: the environment wins, then the
# location the installer recorded in ~/.config/dotfiles/dir, then ~/.dotfiles.
# Dies unless the result is an absolute path other than / and $HOME itself.
df_resolve_dir() {
  local recorded=''
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set to an existing directory"
  if [ -z "${DOTFILES_DIR:-}" ] && [ -r "$HOME/.config/dotfiles/dir" ]; then
    read -r recorded <"$HOME/.config/dotfiles/dir" || :
    DOTFILES_DIR="$recorded"
  fi
  DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
  DOTFILES_DIR="${DOTFILES_DIR%/}"
  case "$DOTFILES_DIR" in
    /?*) ;;
    *) die "DOTFILES_DIR must be an absolute path other than /: '$DOTFILES_DIR'" ;;
  esac
  [ "$DOTFILES_DIR" != "$HOME" ] || die "DOTFILES_DIR must not be \$HOME itself"
  export DOTFILES_DIR
}
