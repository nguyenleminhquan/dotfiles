# Backup helpers. Meant to be sourced; defines functions only.
# Needs lib/log.sh. Reads HOME and DOTFILES_DIR; DF_DRY_RUN=1 only logs.
#
# Layout: ~/.dotfiles-backup/<YYYYmmdd-HHMMSS>/<path relative to $HOME>, plus
# a symlink ~/.dotfiles-backup/original -> the first backup directory ever
# made. uninstall.sh restores from "original".

DF_BACKUP_DIR=""

# df_backup_init: create this run's backup directory (once per process) and,
# when no backup exists yet, mark it as "original".
df_backup_init() {
  [ -z "${DF_BACKUP_DIR:-}" ] || return 0
  [ "${DF_DRY_RUN:-0}" != 1 ] || return 0

  local root="$HOME/.dotfiles-backup" stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$root/$stamp"
  DF_BACKUP_DIR="$root/$stamp"
  if [ ! -e "$root/original" ] && [ ! -L "$root/original" ]; then
    ln -s "$DF_BACKUP_DIR" "$root/original"
    log_info "first backup: $DF_BACKUP_DIR (marked as original)"
  fi
}

# df_backup_file <dest>: move an existing file, directory or symlink out of
# the way into the backup directory, keeping its path relative to $HOME.
# A symlink that already points into $DOTFILES_DIR is ours and is skipped.
df_backup_file() {
  local dest="$1" rel target n

  [ -e "$dest" ] || [ -L "$dest" ] || return 0
  if [ -L "$dest" ]; then
    case "$(readlink "$dest")" in
      "${DOTFILES_DIR:?}"/*) return 0 ;;
    esac
  fi
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
  # Two replacements of the same path within one second must not overwrite
  # the earlier backup.
  n=0
  while [ -e "$target" ] || [ -L "$target" ]; do
    n=$((n + 1))
    target="$DF_BACKUP_DIR/$rel.$n"
  done
  mkdir -p "$(dirname "$target")"
  mv -- "$dest" "$target"
  log_info "backed up $dest"
}
