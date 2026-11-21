#!/usr/bin/env bash
# Dotfiles uninstaller.
#
#   uninstall.sh [--purge]
#
# Removes the symlinks listed in ~/.config/dotfiles/links, restores the files
# saved in ~/.dotfiles-backup/original/ (never overwriting anything that exists
# now), drops the completion and shell-init caches and the installer state.
# --purge also removes what install.sh installed (mise, the tools mise
# installed, zsh-bin; see lib/tools.sh) and $DOTFILES_DIR itself. The backups
# are kept either way. Without --purge the tools stay, and so does the record
# of them, so that a later --purge still knows what to remove.
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
# shellcheck source=lib/tools.sh
. "$here/lib/tools.sh"

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

# restore_original: put back, for every path, the EARLIEST backup of the
# current cycle: the "original" directory and every later one (a profile
# upgrade can back up a file after the first install). Paths that exist now
# are left alone. Afterwards "original" is retired so the next install starts
# a new cycle instead of restoring stale content.
restore_original() {
  local root="$HOME/.dotfiles-backup" orig orig_name started=0 dir file rel dest
  local -A seen=()
  # "original" is a symlink; resolve it to learn which directory it names.
  if ! orig="$(cd "$root/original" 2>/dev/null && pwd -P)"; then
    log_info "no original backup to restore"
    return 0
  fi
  orig_name="${orig##*/}"
  while IFS= read -r -d '' dir; do
    if [ "$started" = 0 ]; then
      [ "${dir##*/}" = "$orig_name" ] || continue
      started=1
    fi
    while IFS= read -r -d '' file; do
      rel="${file#"$dir"/}"
      [ -z "${seen[$rel]:-}" ] || continue
      seen[$rel]=1
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
    done < <(find "$dir" \( -type f -o -type l \) -print0)
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -print0 | LC_ALL=C sort -z)
  mv -- "$root/original" "$root/original.restored-$(date +%Y%m%d-%H%M%S)-$$"
}

df_unlink_all
df_gen_all_remove
restore_original

rm -rf -- "$HOME/.cache/zsh/completions" "$HOME/.cache/dotfiles/init"
rm -f -- "$HOME"/.cache/zsh/zcompdump*
rm -f -- "$HOME/.config/dotfiles/profile" "$HOME/.config/dotfiles/links" "$HOME/.config/dotfiles/generated" "$HOME/.config/dotfiles/dir"

if [ "$purge" = 1 ]; then
  df_tools_remove
  if df_dir_managed && [ ! -L "$DOTFILES_DIR" ]; then
    rm -rf -- "$DOTFILES_DIR"
    log_info "removed $DOTFILES_DIR"
  else
    log_warn "$DOTFILES_DIR was not created by this installer, not removing it"
  fi
fi

rmdir "$HOME/.config/dotfiles" 2>/dev/null || true

log_info "uninstalled"
