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
  # Listed first: only manifest entries count as ours, so a crash between the
  # two steps must not leave an unlisted link of ours behind.
  _df_manifest_add "$dest"
  ln -s "$target" "$dest"
  log_info "linked $dest"
}

# df_unlink_one <dest>: forget <dest> and remove it if it is our symlink.
# Never touches anything that is not a link into $DOTFILES_DIR.
df_unlink_one() {
  local dest="$1"
  if df_is_ours "$dest"; then
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
      df_is_ours "$dest" || log_warn "not our symlink any more, leaving it: $dest"
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
  for row in "${DF_GEN_TABLE[@]}"; do
    IFS='|' read -r min dest src <<<"$row"
    if [ "$level" -ge "$(_df_profile_level "$min")" ]; then
      df_gen_file "$dest" "$src"
    else
      df_gen_remove "$dest"
    fi
  done
}

# Generated files: real files (not links) that the installer writes because
# tools write into them. <lowest profile>|<dest relative to $HOME>|<generator>
# The generator prints the content. ~/.config/git/config is one: `git config
# --global` (safe.directory, gh auth setup-git, user.email, ...) must land in a
# file of the user's, never in the tracked file inside the repo, so the real
# file only includes the repo's settings and the local overrides.
DF_GEN_TABLE=(
  "minimal|.config/git/config|_df_gen_gitconfig"
)
DF_GEN_MARKER="# Generated by the dotfiles installer"

_df_gen_gitconfig() {
  # shellcheck disable=SC2016
  printf '%s; `git config --global` writes below this line.\n' "$DF_GEN_MARKER"
  printf '[include]\n\tpath = %s/config/git/config\n' "${DOTFILES_DIR:?}"
  printf '[include]\n\tpath = ~/.gitconfig.local\n'
}

_df_gen_gitconfig_current() { grep -qF -- "path = ${DOTFILES_DIR:?}/config/git/config" "$1"; }

_df_gen_state() { printf '%s/.config/dotfiles/generated' "$HOME"; }

# _df_gen_record <dest> <sha>: remember the content hash of what we generated
# ("<sha>  <dest>" per line), so uninstall can tell an untouched file.
_df_gen_record() {
  local state tmp
  state="$(_df_gen_state)"
  mkdir -p "$(dirname "$state")"
  tmp="$state.tmp.$$"
  { [ ! -f "$state" ] || grep -vF -- "  $1" "$state" || true; printf '%s  %s\n' "$2" "$1"; } >"$tmp"
  if [ -f "$state" ] && [ "$(cat "$tmp")" = "$(cat "$state")" ]; then rm -f "$tmp"; return 0; fi
  mv -- "$tmp" "$state"
}

_df_gen_forget() {
  local state tmp
  state="$(_df_gen_state)"
  [ -f "$state" ] || return 0
  tmp="$state.tmp.$$"
  grep -vF -- "  $1" "$state" >"$tmp" || true
  if [ -s "$tmp" ]; then mv -- "$tmp" "$state"; else rm -f -- "$tmp" "$state"; fi
}

# df_gen_file <rel> <generator>: make $HOME/<rel> a real file with the
# generated content. Already identical: nothing happens. Ours but extended by
# the tools that write into it: left alone. Anything else (the user's own
# file, or a link, including the one an older install made) is backed up
# first.
df_gen_file() {
  local gen="$2" dest="$HOME/$1" content cur sha
  content="$("$gen")"
  sha="$(printf '%s\n' "$content" | sha256sum | cut -d' ' -f1)"

  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    cur="$(cat "$dest")"
    if [ "$cur" = "$content" ]; then
      [ "${DF_DRY_RUN:-0}" = 1 ] || _df_gen_record "$dest" "$sha"
      return 0
    fi
    if head -n 1 "$dest" | grep -qF -- "$DF_GEN_MARKER"; then
      "${gen}_current" "$dest" || log_warn "$dest points at another checkout than $DOTFILES_DIR; leaving it"
      return 0
    fi
  fi

  if [ -L "$dest" ] && df_is_ours "$dest"; then
    df_unlink_one "$dest"
  else
    df_backup_file "$dest"
  fi
  if [ "${DF_DRY_RUN:-0}" = 1 ]; then
    log_info "would write $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" >"$dest"
  _df_gen_record "$dest" "$sha"
  log_info "wrote $dest"
}

# df_gen_remove <rel>: remove a generated file only while it is byte for byte
# what we wrote; otherwise leave it and say so.
df_gen_remove() {
  local dest="$HOME/$1" state want have
  state="$(_df_gen_state)"
  if [ -f "$state" ]; then
    want="$(grep -F -- "  $dest" "$state" | head -n 1 | cut -d' ' -f1 || true)"
  fi
  if [ -n "${want:-}" ] && [ -f "$dest" ] && [ ! -L "$dest" ]; then
    have="$(sha256sum <"$dest" | cut -d' ' -f1)"
    if [ "$have" = "$want" ]; then
      [ "${DF_DRY_RUN:-0}" = 1 ] || rm -f -- "$dest"
      log_info "removed $dest"
    else
      log_warn "$dest was changed since it was generated, leaving it"
    fi
  fi
  [ "${DF_DRY_RUN:-0}" = 1 ] || _df_gen_forget "$dest"
}

# df_gen_all_remove: uninstall side, for every recorded generated file.
df_gen_all_remove() {
  local state line dest
  state="$(_df_gen_state)"
  [ -f "$state" ] || return 0
  while IFS= read -r line; do
    dest="${line#*  }"
    case "$dest" in "$HOME"/*) df_gen_remove "${dest#"$HOME"/}" ;; esac
  done <"$state"
}
