# Backup helpers. Meant to be sourced; defines functions only.
# Needs lib/log.sh. Reads HOME and DOTFILES_DIR; DF_DRY_RUN=1 only logs.
#
# Layout: ~/.dotfiles-backup/<YYYYmmdd-HHMMSS>/<path relative to $HOME>, plus
# a symlink ~/.dotfiles-backup/original -> the first backup directory of the
# current install cycle. uninstall.sh restores from "original" and every
# later directory, then retires the marker (original.restored-*) so the next
# install starts a new cycle. Directory names sort chronologically.

DF_BACKUP_DIR=""

# df_dir_managed: $DOTFILES_DIR carries the marker written by install.sh.
df_dir_managed() {
  [ -f "${DOTFILES_DIR:?}/.dotfiles-managed" ]
}

# df_is_ours <path>: a symlink into $DOTFILES_DIR that this installer made,
# which means it is listed in the manifest (~/.config/dotfiles/links). A link
# into that path that is not listed, dangling or not, belongs to the user.
df_is_ours() {
  local manifest="$HOME/.config/dotfiles/links"
  [ -L "$1" ] || return 1
  case "$(readlink "$1")" in
    "${DOTFILES_DIR:?}"/*) ;;
    *) return 1 ;;
  esac
  [ -f "$manifest" ] && grep -qxF -- "$1" "$manifest"
}

# df_backup_init: create this run's backup directory (once per process) and,
# when this cycle has no "original" yet, mark it as such.
df_backup_init() {
  [ -z "${DF_BACKUP_DIR:-}" ] || return 0
  [ "${DF_DRY_RUN:-0}" != 1 ] || return 0

  local root="$HOME/.dotfiles-backup" stamp dir n=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$root"
  dir="$stamp"
  # Two runs within one second must not share a directory: "-N" sorts right
  # after the plain stamp and before the next second.
  until mkdir "$root/$dir" 2>/dev/null; do
    n=$((n + 1))
    dir="$stamp-$n"
  done
  DF_BACKUP_DIR="$root/$dir"
  # A dangling marker (its directory was deleted) counts as no marker.
  if [ ! -e "$root/original" ]; then
    rm -f -- "$root/original"
    ln -s "$DF_BACKUP_DIR" "$root/original"
    log_info "first backup: $DF_BACKUP_DIR (marked as original)"
  fi
}

# df_backup_file <dest>: move an existing file, directory or symlink out of
# the way into the backup directory, keeping its path relative to $HOME.
# A symlink that this installer made is skipped.
df_backup_file() {
  local dest="$1" rel target

  [ -e "$dest" ] || [ -L "$dest" ] || return 0
  if df_is_ours "$dest"; then return 0; fi
  case "$dest" in
    "$HOME"/*) rel="${dest#"$HOME"/}" ;;
    *) die "refusing to back up a path outside \$HOME: $dest" ;;
  esac

  if [ "${DF_DRY_RUN:-0}" = 1 ]; then
    log_info "would back up $dest"
    return 0
  fi

  df_backup_init
  target="$DF_BACKUP_DIR/$rel"
  if [ -e "$target" ] || [ -L "$target" ]; then
    die "backup path already exists, refusing to overwrite it: $target"
  fi
  mkdir -p "$(dirname "$target")"
  mv -- "$dest" "$target"
  log_info "backed up $dest"
}
