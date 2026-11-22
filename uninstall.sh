#!/usr/bin/env bash
# Dotfiles uninstaller.
#
#   uninstall.sh [--purge [--force]]
#
# Removes the symlinks listed in ~/.config/dotfiles/links, restores the files
# saved in ~/.dotfiles-backup/original/ (never overwriting anything that exists
# now), drops the caches and the installer state.
# --purge also removes what install.sh installed (mise, the tools mise
# installed, zsh-bin; see lib/tools.sh), $DOTFILES_DIR itself and the empty
# directories that leaves behind in $HOME. The backups
# are kept either way. Without --purge the tools stay, and so does the record
# of them, so that a later --purge still knows what to remove.
# A checkout that is a git clone is not deleted while it holds uncommitted
# changes or commits that exist nowhere else: --purge refuses before it changes
# anything, and --force overrides the refusal.
set -euo pipefail

purge=0
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge)
      purge=1
      shift
      ;;
    --force)
      force=1
      shift
      ;;
    -h | --help)
      printf 'usage: uninstall.sh [--purge [--force]]\n' >&2
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
# shellcheck source=lib/dir.sh
. "$here/lib/dir.sh"
# shellcheck source=lib/backup.sh
. "$here/lib/backup.sh"
# shellcheck source=lib/link.sh
. "$here/lib/link.sh"
# shellcheck source=lib/tools.sh
. "$here/lib/tools.sh"

# The checkout, resolved like install.sh and bin/dotfiles do: DOTFILES_DIR, then
# the location install.sh recorded, then ~/.dotfiles.
df_resolve_dir

# purge_guard: --purge deletes $DOTFILES_DIR, so refuse (before anything has
# been changed) when it is a git clone whose uncommitted or unpushed work would
# be lost. A checkout that is not ours is never deleted anyway, and a mirror
# copy has no .git. A failed check counts as a reason: unsaved work cannot be
# ruled out.
purge_guard() {
  local status n upstream=1
  local -a reasons=()
  if ! df_dir_managed || [ -L "$DOTFILES_DIR" ] || [ ! -e "$DOTFILES_DIR/.git" ]; then return 0; fi
  if ! command -v git >/dev/null 2>&1; then
    reasons+=("$DOTFILES_DIR is a git clone but git is not installed, so unsaved work cannot be ruled out")
  elif ! status="$(git -C "$DOTFILES_DIR" status --porcelain 2>/dev/null)"; then
    reasons+=("git status failed in $DOTFILES_DIR, so unsaved work cannot be ruled out")
  else
    if [ -n "$status" ]; then
      reasons+=("uncommitted changes (git -C '$DOTFILES_DIR' status)")
    fi
    # Commits that are on no remote and carry no tag. With an upstream branch
    # that is the usual "@{u}.." question; without one (a local-only repository,
    # a detached or tag-pinned clone) everything not reachable from a remote ref
    # or a tag counts.
    git -C "$DOTFILES_DIR" rev-parse --verify --quiet '@{u}' >/dev/null 2>&1 || upstream=0
    if [ "$upstream" = 1 ]; then
      n="$(git -C "$DOTFILES_DIR" rev-list --count '@{u}..' 2>/dev/null || echo 1)"
    elif git -C "$DOTFILES_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
      n="$(git -C "$DOTFILES_DIR" rev-list --count HEAD --not --remotes --tags 2>/dev/null || echo 1)"
    else
      n=0
    fi
    if [ "$n" != 0 ]; then
      if [ "$upstream" = 1 ]; then
        reasons+=("$n commit(s) not pushed to the upstream branch (git -C '$DOTFILES_DIR' log '@{u}..')")
      else
        reasons+=("$n commit(s) that are on no remote and no tag (git -C '$DOTFILES_DIR' log --branches --not --remotes)")
      fi
    fi
  fi
  [ "${#reasons[@]}" -gt 0 ] || return 0
  log_error "refusing --purge: it would delete $DOTFILES_DIR, a git clone with work that exists nowhere else:"
  printf '  - %s\n' "${reasons[@]}" >&2
  log_error "commit and push (or copy) that work first, or run again with --force to delete the checkout anyway"
  exit 1
}
if [ "$purge" = 1 ] && [ "$force" != 1 ]; then purge_guard; fi

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

df_caches_remove
# Left empty by it (the doctor at the end of an install starts a zsh, which creates them): only empty ones go.
rmdir "$HOME/.cache/zsh" "$HOME/.cache/dotfiles" "$HOME/.cache" 2>/dev/null || true
rm -f -- "$HOME/.config/dotfiles/profile" "$HOME/.config/dotfiles/links" "$HOME/.config/dotfiles/generated" "$HOME/.config/dotfiles/dir" "$HOME/.config/dotfiles/repo"

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

if [ "$purge" = 1 ]; then
  # What the install created and nothing else uses any more: empty directories
  # only (rmdir never removes content), children before parents.
  for d in .config/git .config/micro .config/mise/conf.d .config/mise .cache/zsh .cache/dotfiles \
    .local/bin .local/share .local/state .local .cache .config; do
    rmdir "$HOME/$d" 2>/dev/null || true
  done
fi

log_info "uninstalled"
