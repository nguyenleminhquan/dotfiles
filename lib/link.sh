# Symlink management. Meant to be sourced; defines functions only.
# Needs lib/log.sh and lib/backup.sh. Reads HOME and DOTFILES_DIR (and, in a
# dry run, DF_REPO_ROOT: where the repo files are before they are copied);
# DF_DRY_RUN=1 only logs what would change.
#
# State lives in ~/.config/dotfiles/: "profile" (one word) and "links" (the
# manifest: one destination path per line, every link this installer made).

# Link table: <lowest profile that gets it>|<dest relative to $HOME>|<src in repo>
DF_LINK_TABLE=(
  "minimal|.profile|shell/profile"
  "minimal|.bash_profile|shell/bash_profile"
  "minimal|.bashrc|shell/bashrc"
  "minimal|.zshenv|shell/zshenv"
  "minimal|.zshrc|shell/zshrc"
  "minimal|.screenrc|config/screen/screenrc"
  "minimal|.config/git/config|config/git/config"
  "minimal|.config/micro/settings.json|config/micro/settings.json"
  "minimal|.local/bin/dotfiles|bin/dotfiles"
  "server|.config/starship.toml|config/starship.toml"
  "server|.config/mise/config.toml|config/mise/config.toml"
  "workstation|.config/mise/config.workstation.toml|config/mise/config.workstation.toml"
)

# _df_profile_level <profile>: 0 minimal, 1 server, 2 workstation; 1 if unknown.
_df_profile_level() {
  case "$1" in
    minimal) echo 0 ;;
    server) echo 1 ;;
    workstation) echo 2 ;;
    *) return 1 ;;
  esac
}

df_profile_valid() { _df_profile_level "$1" >/dev/null; }

_df_manifest() { printf '%s/.config/dotfiles/links' "$HOME"; }

# _df_is_ours <dest>: a symlink that points into $DOTFILES_DIR.
_df_is_ours() {
  [ -L "$1" ] || return 1
  case "$(readlink "$1")" in
    "${DOTFILES_DIR:?}"/*) return 0 ;;
  esac
  return 1
}

_df_manifest_add() {
  local manifest
  manifest="$(_df_manifest)"
  mkdir -p "$(dirname "$manifest")"
  if [ -f "$manifest" ] && grep -qxF -- "$1" "$manifest"; then
    return 0
  fi
  printf '%s\n' "$1" >>"$manifest"
}

_df_manifest_remove() {
  local manifest tmp
  manifest="$(_df_manifest)"
  [ -f "$manifest" ] || return 0
  grep -qxF -- "$1" "$manifest" || return 0
  tmp="$manifest.tmp.$$"
  # grep -v exits 1 when nothing is left, which is fine here.
  grep -vxF -- "$1" "$manifest" >"$tmp" || true
  mv -- "$tmp" "$manifest"
}

# df_link <src_rel> <dest>: make <dest> a symlink to $DOTFILES_DIR/<src_rel>.
# Idempotent. Whatever is in the way is backed up first.
df_link() {
  local src_rel="$1" dest="$2" target
  target="${DOTFILES_DIR:?}/$src_rel"

  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$target" ]; then
    if [ "${DF_DRY_RUN:-0}" != 1 ]; then _df_manifest_add "$dest"; fi
    return 0
  fi
  # A dry run has not copied the repo yet; DF_REPO_ROOT says where to look instead.
  [ -e "${DF_REPO_ROOT:-$DOTFILES_DIR}/$src_rel" ] || die "missing in repo: $src_rel (looked in ${DF_REPO_ROOT:-$DOTFILES_DIR})"

  if [ "${DF_DRY_RUN:-0}" = 1 ]; then
    df_backup_file "$dest"
    log_info "would link $dest -> $target"
    return 0
  fi

  df_backup_file "$dest"
  # Left behind by df_backup_file only when it is our own, stale, symlink.
  if [ -L "$dest" ]; then rm -f -- "$dest"; fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$target" "$dest"
  _df_manifest_add "$dest"
  log_info "linked $dest"
}

# df_unlink_one <dest>: forget <dest> and remove it if it is our symlink.
# Never touches anything that is not a link into $DOTFILES_DIR.
df_unlink_one() {
  local dest="$1"
  if _df_is_ours "$dest"; then
    if [ "${DF_DRY_RUN:-0}" = 1 ]; then
      log_info "would unlink $dest"
      return 0
    fi
    rm -f -- "$dest"
    log_info "unlinked $dest"
  fi
  if [ "${DF_DRY_RUN:-0}" != 1 ]; then _df_manifest_remove "$dest"; fi
}

# df_unlink_all: remove every symlink listed in the manifest that still points
# into $DOTFILES_DIR; entries that no longer do are dropped with a warning.
df_unlink_all() {
  local manifest dest
  local -a dests=()
  manifest="$(_df_manifest)"
  [ -f "$manifest" ] || return 0
  mapfile -t dests <"$manifest"
  for dest in "${dests[@]}"; do
    [ -n "$dest" ] || continue
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      _df_is_ours "$dest" || log_warn "not our symlink any more, leaving it: $dest"
    fi
    df_unlink_one "$dest"
  done
}

# df_link_profile <profile>: link everything the profile includes and remove
# the links that belong only to higher profiles (a downgrade).
df_link_profile() {
  local profile="$1" row min dest src level
  df_profile_valid "$profile" || die "unknown profile: $profile (minimal|server|workstation)"
  level="$(_df_profile_level "$profile")"
  for row in "${DF_LINK_TABLE[@]}"; do
    IFS='|' read -r min dest src <<<"$row"
    if [ "$level" -ge "$(_df_profile_level "$min")" ]; then
      df_link "$src" "$HOME/$dest"
    else
      df_unlink_one "$HOME/$dest"
    fi
  done
}
