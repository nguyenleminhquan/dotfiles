#!/usr/bin/env bash
# Dotfiles uninstaller.
#
#   uninstall.sh [--purge]
#
# Removes the symlinks listed in ~/.config/dotfiles/links, restores the files
# saved in ~/.dotfiles-backup/original/ (never overwriting anything that exists
# now), drops the completion cache and the installer state. --purge also
# deletes $DOTFILES_DIR itself. The backups are kept either way.
set -euo pipefail

purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge)
      purge=1
      shift
      ;;
    -h | --help)
      printf 'usage: uninstall.sh [--purge]\n' >&2
      exit 0
      ;;
    *)
      printf '[error] unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/log.sh
. "$here/lib/log.sh"
# shellcheck source=lib/backup.sh
. "$here/lib/backup.sh"
# shellcheck source=lib/link.sh
. "$here/lib/link.sh"

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set to an existing directory"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
DOTFILES_DIR="${DOTFILES_DIR%/}"
case "$DOTFILES_DIR" in
  /?*) ;;
  *) die "DOTFILES_DIR must be an absolute path other than /: '$DOTFILES_DIR'" ;;
esac
[ "$DOTFILES_DIR" != "$HOME" ] || die "DOTFILES_DIR must not be \$HOME itself"

# _same_content <a> <b>: identical bytes (cmp is not in every minimal image).
_same_content() {
  [ "$(sha256sum <"$1")" = "$(sha256sum <"$2")" ]
}

# restore_original: copy everything under ~/.dotfiles-backup/original/ back to
# its place in $HOME, skipping paths that exist now.
restore_original() {
  local orig file rel dest
  # "original" is a symlink; resolve it so find and the prefix strip agree.
  if ! orig="$(cd "$HOME/.dotfiles-backup/original" 2>/dev/null && pwd -P)"; then
    log_info "no original backup to restore"
    return 0
  fi
  while IFS= read -r -d '' file; do
    rel="${file#"$orig"/}"
    dest="$HOME/$rel"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if [ -L "$dest" ] && [ -L "$file" ] && [ "$(readlink "$dest")" = "$(readlink "$file")" ]; then
        continue
      fi
      if [ ! -L "$dest" ] && [ ! -L "$file" ] && _same_content "$file" "$dest"; then
        continue
      fi
      log_warn "exists, not restoring: $dest"
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    cp -a -- "$file" "$dest"
    log_info "restored $dest"
  done < <(find "$orig" \( -type f -o -type l \) -print0)
}

df_unlink_all
restore_original

rm -rf -- "$HOME/.cache/zsh/completions"
rm -f -- "$HOME/.config/dotfiles/profile" "$HOME/.config/dotfiles/links"
rmdir "$HOME/.config/dotfiles" 2>/dev/null || true

if [ "$purge" = 1 ]; then
  if [ -f "$DOTFILES_DIR/lib/log.sh" ]; then
    rm -rf -- "$DOTFILES_DIR"
    log_info "removed $DOTFILES_DIR"
  else
    log_warn "$DOTFILES_DIR does not look like a dotfiles checkout, not removing it"
  fi
fi

log_info "uninstalled"
