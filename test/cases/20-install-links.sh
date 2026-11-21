# Installer: links, backup, idempotence, profile switching, uninstall.
# One container per case file, so the scenarios below run in order and each
# leaves $HOME in the state the next one expects.

run_install() { bash "$DOTFILES_SRC/install.sh" "$@"; }
dotfiles_dir="$HOME/.dotfiles"
manifest="$HOME/.config/dotfiles/links"

# Destinations per profile, relative to $HOME (mirrors the symlink table).
# .config/git/config is not here: it is a generated real file (see the end of this case).
minimal_dests=(
  .profile .bash_profile .bashrc .zshenv .zshrc .screenrc
  .config/micro/settings.json .local/bin/dotfiles
)
server_extra=(.config/starship.toml .config/mise/config.toml)
workstation_extra=(.config/mise/config.workstation.toml)

# Source file in the repo for each destination.
src_of() {
  case "$1" in
    .profile) echo shell/profile ;;
    .bash_profile) echo shell/bash_profile ;;
    .bashrc) echo shell/bashrc ;;
    .zshenv) echo shell/zshenv ;;
    .zshrc) echo shell/zshrc ;;
    .screenrc) echo config/screen/screenrc ;;
    .config/git/config) echo config/git/config ;;
    .config/micro/settings.json) echo config/micro/settings.json ;;
    .local/bin/dotfiles) echo bin/dotfiles ;;
    .config/starship.toml) echo config/starship.toml ;;
    .config/mise/config.toml) echo config/mise/config.toml ;;
    .config/mise/config.workstation.toml) echo config/mise/config.workstation.toml ;;
    *) echo "src_of: unknown dest $1" >&2; return 1 ;;
  esac
}

# same_file <a> <b>: identical bytes (cmp is missing from the Rocky image).
same_file() { [ "$(sha256sum <"$1")" = "$(sha256sum <"$2")" ]; }

# backup_dirs: timestamped backup directories, oldest first.
backup_dirs() {
  local d
  for d in "$HOME"/.dotfiles-backup/[0-9]*; do
    [ -d "$d" ] || continue
    printf '%s\n' "${d##*/}"
  done | LC_ALL=C sort
}

assert_linked() { assert_symlink "$HOME/$1" "$dotfiles_dir/$(src_of "$1")"; }

# --- Scenario 0: pre-existing user files (the OS skeleton plus custom ones) ---
printf 'alias mine=1\n' >"$HOME/.bashrc"
printf '[user]\n\tname = Someone\n' >"$HOME/.gitconfig"
mkdir -p "$HOME/.config/git"
printf '[core]\n\tpager = cat\n' >"$HOME/.config/git/config"
ln -s /etc/hostname "$HOME/.screenrc"
mkdir -p "$HOME/.cache/zsh/completions"
printf 'x\n' >"$HOME/.cache/zsh/completions/_stale"

# Remember every pre-existing dotfile (skeleton files differ per OS) so the
# restore can be checked for every path the installer may touch.
snap="$(mktemp -d)"
tracked=("${minimal_dests[@]}" .config/git/config "${server_extra[@]}" "${workstation_extra[@]}" .bash_logout .gitconfig)
for f in "${tracked[@]}"; do
  if [ -e "$HOME/$f" ] || [ -L "$HOME/$f" ]; then
    mkdir -p "$snap/$(dirname "$f")"
    cp -a "$HOME/$f" "$snap/$f"
  fi
done

# assert_pre_install_state: every tracked path is back to what it was at the
# start (same bytes or same symlink target), or absent if it did not exist.
assert_pre_install_state() {
  local f
  for f in "${tracked[@]}"; do
    if [ -L "$snap/$f" ]; then
      assert_eq "$(readlink "$HOME/$f")" "$(readlink "$snap/$f")" "$f restored as a symlink"
    elif [ -e "$snap/$f" ]; then
      assert_ok "$f restored byte for byte" -- same_file "$HOME/$f" "$snap/$f"
    else
      assert_file_absent "$HOME/$f"
    fi
  done
}

# --- case_dry_run_and_profile_rules: no state, no changes -----------------
h0="$(home_hash)"
assert_fail "first install on a server needs --profile" -- run_install
assert_fail "unknown profile rejected" -- run_install --profile bogus
assert_fail "unknown flag rejected" -- run_install --nope
assert_eq "$(home_hash)" "$h0" "failed installs change nothing"

out="$(run_install --profile "$DF_PROFILE" --dry-run 2>&1)"
assert_eq "$(home_hash)" "$h0" "dry run changes nothing"
assert_file_absent "$dotfiles_dir"
assert_file_absent "$HOME/.dotfiles-backup"
assert_file_absent "$HOME/.config/dotfiles"
assert_ok "dry run announces links" -- grep -q 'would link' <<<"$out"
assert_ok "dry run announces backups" -- grep -q 'would back up' <<<"$out"

# Under WSL the profile defaults to workstation.
printf 'Linux version 5.15.153.1-microsoft-standard-WSL2\n' >"$snap/pv-wsl"
out="$(DF_PROC_VERSION_FILE="$snap/pv-wsl" run_install --dry-run 2>&1)"
assert_ok "WSL defaults to workstation" -- grep -q 'profile: workstation' <<<"$out"
assert_eq "$(home_hash)" "$h0" "WSL dry run changes nothing"

# --- case_links_created -----------------------------------------------------
run_install --profile "$DF_PROFILE"
for d in "${minimal_dests[@]}"; do assert_linked "$d"; done
case "$DF_PROFILE" in
  minimal)
    for d in "${server_extra[@]}" "${workstation_extra[@]}"; do assert_file_absent "$HOME/$d"; done
    ;;
  server)
    for d in "${server_extra[@]}"; do assert_linked "$d"; done
    for d in "${workstation_extra[@]}"; do assert_file_absent "$HOME/$d"; done
    ;;
esac
assert_eq "$(cat "$HOME/.config/dotfiles/profile")" "$DF_PROFILE" "profile recorded"
expected_count=${#minimal_dests[@]}
[ "$DF_PROFILE" != server ] || expected_count=$((expected_count + ${#server_extra[@]}))
assert_eq "$(wc -l <"$manifest" | tr -d ' ')" "$expected_count" "manifest lists every link"
assert_ok "manifest has .bashrc" -- grep -qxF "$HOME/.bashrc" "$manifest"
assert_ok "installed code is a copy, not /src" -- test -f "$dotfiles_dir/lib/link.sh"
assert_ok "install is marked as ours" -- test -f "$dotfiles_dir/.dotfiles-managed"
assert_fail "no .git copied from the source" -- test -e "$dotfiles_dir/.git"

# Pre-existing files went to the backup, original marked.
orig="$HOME/.dotfiles-backup/original"
assert_ok "original backup exists" -- test -L "$orig"
assert_eq "$(cat "$orig/.bashrc")" "alias mine=1" "custom .bashrc backed up"
assert_eq "$(readlink "$orig/.screenrc")" "/etc/hostname" "symlink backed up as a symlink"
assert_eq "$(cat "$orig/.config/git/config")" "$(cat "$snap/.config/git/config")" "nested file backed up"
assert_ok ".gitconfig untouched" -- same_file "$HOME/.gitconfig" "$snap/.gitconfig"

# --- case_idempotent --------------------------------------------------------
h1="$(home_hash)"
run_install
assert_eq "$(home_hash)" "$h1" "second install (saved profile) changes nothing"
run_install --profile "$DF_PROFILE"
assert_eq "$(home_hash)" "$h1" "third install (explicit profile) changes nothing"
assert_eq "$(find "$HOME/.dotfiles-backup" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2" "re-install makes no new backup"

# --- case_profile_switch: upgrade and downgrade ------------------------------
run_install --profile workstation
for d in "${minimal_dests[@]}" "${server_extra[@]}" "${workstation_extra[@]}"; do assert_linked "$d"; done
run_install --profile minimal
for d in "${minimal_dests[@]}"; do assert_linked "$d"; done
for d in "${server_extra[@]}" "${workstation_extra[@]}"; do assert_file_absent "$HOME/$d"; done
assert_eq "$(wc -l <"$manifest" | tr -d ' ')" "${#minimal_dests[@]}" "downgrade shrinks the manifest"
assert_eq "$(cat "$HOME/.config/dotfiles/profile")" "minimal" "downgrade recorded"
# A user's own file at a higher-profile destination survives a downgrade.
printf 'mine\n' >"$HOME/.config/starship.toml"
run_install --profile minimal
assert_eq "$(cat "$HOME/.config/starship.toml")" "mine" "foreign file untouched on downgrade"
rm -f "$HOME/.config/starship.toml"
run_install --profile "$DF_PROFILE"
for d in "${minimal_dests[@]}"; do assert_linked "$d"; done

# --- case_preexisting_files_restored ------------------------------------------
rm -rf "$HOME/.cache/zsh"
mkdir -p "$HOME/.cache/zsh/completions"
printf 'x\n' >"$HOME/.cache/zsh/completions/_stale"
bash "$dotfiles_dir/uninstall.sh"
assert_eq "$(cat "$HOME/.bashrc")" "alias mine=1" "custom .bashrc restored"
assert_pre_install_state
assert_file_absent "$HOME/.cache/zsh/completions"
assert_file_absent "$HOME/.config/dotfiles/profile"
assert_file_absent "$HOME/.config/dotfiles/links"
assert_file_absent "$orig"
assert_ok "original marker is retired, not deleted" -- test -L "$(find "$HOME/.dotfiles-backup" -maxdepth 1 -name "original.restored-*" | head -n 1)"
assert_ok "the backup itself is kept" -- test -f "$HOME/.dotfiles-backup/$(backup_dirs | head -n 1)/.bashrc"

# Uninstalling again is harmless.
h2="$(home_hash)"
bash "$dotfiles_dir/uninstall.sh"
assert_eq "$(home_hash)" "$h2" "second uninstall changes nothing"

# --- case_purge: --purge removes the checkout too -----------------------------
run_install --profile "$DF_PROFILE"
assert_linked .bashrc
bash "$dotfiles_dir/uninstall.sh" --purge
assert_file_absent "$dotfiles_dir"
assert_file_absent "$HOME/.config/dotfiles/profile"
assert_eq "$(cat "$HOME/.bashrc")" "alias mine=1" "custom .bashrc restored after purge"
assert_pre_install_state

# --- Safety scenarios -----------------------------------------------------------
# Each one starts from a clean installer state; $HOME dotfiles are back to
# their original content after the purge above.
reset_installer_state() {
  rm -rf "$HOME/.dotfiles" "$HOME/.dotfiles.old" "$HOME/.dotfiles.staging" \
    "$HOME/.dotfiles-backup" "$HOME/.config/dotfiles"
}
backup_cycles() { find "$HOME/.dotfiles-backup" -maxdepth 1 -name 'original.restored-*' | wc -l | tr -d ' '; }

# case_foreign_dotfiles_dir: a ~/.dotfiles the installer did not create is
# never merged into, linked through, or deleted by uninstall --purge.
reset_installer_state
mkdir -p "$HOME/.dotfiles"
printf 'my own bashrc\n' >"$HOME/.dotfiles/bashrc"
ln -sfn "$HOME/.dotfiles/bashrc" "$HOME/.bashrc"
h3="$(home_hash)"
assert_fail "foreign ~/.dotfiles is refused" -- run_install --profile minimal
assert_fail "foreign ~/.dotfiles is refused in a dry run" -- run_install --profile minimal --dry-run
assert_eq "$(home_hash)" "$h3" "refusal changes nothing"
assert_ok "refusal explains how to move it aside" -- grep -q 'Move it aside' <<<"$(run_install --profile minimal 2>&1 || true)"
bash "$DOTFILES_SRC/uninstall.sh" --purge
assert_eq "$(cat "$HOME/.dotfiles/bashrc")" "my own bashrc" "foreign directory survives uninstall --purge"
assert_symlink "$HOME/.bashrc" "$HOME/.dotfiles/bashrc"
assert_eq "$(home_hash)" "$h3" "uninstall leaves foreign state alone"
rm -f "$HOME/.bashrc"
printf 'alias mine=1\n' >"$HOME/.bashrc"

# A symlinked ~/.dotfiles is somebody's layout as well, even if it points at an empty dir.
reset_installer_state
mkdir -p "$HOME/elsewhere"
ln -s "$HOME/elsewhere" "$HOME/.dotfiles"
assert_fail "symlinked ~/.dotfiles is refused" -- run_install --profile minimal
assert_ok "symlink left in place" -- test -L "$HOME/.dotfiles"
rm -f "$HOME/.dotfiles"
rmdir "$HOME/elsewhere"

# Running install.sh from a checkout that already is $DOTFILES_DIR is accepted
# (that is how the checkout gets adopted); purge then removes it.
reset_installer_state
cp -r "$DOTFILES_SRC" "$HOME/clone"
DOTFILES_DIR="$HOME/clone" env -u DOTFILES_SRC bash "$HOME/clone/install.sh" --profile minimal
assert_symlink "$HOME/.profile" "$HOME/clone/shell/profile"
assert_ok "adopted checkout is marked" -- test -f "$HOME/clone/.dotfiles-managed"
DOTFILES_DIR="$HOME/clone" bash "$HOME/clone/uninstall.sh" --purge
assert_file_absent "$HOME/clone"
assert_pre_install_state
reset_installer_state

# case_earliest_backup_wins: a file backed up by a later install (profile
# upgrade) is restored too.
mkdir -p "$HOME/.config/mise"
printf 'mine\n' >"$HOME/.config/mise/config.toml"
run_install --profile minimal
run_install --profile server
bash "$dotfiles_dir/uninstall.sh"
assert_eq "$(cat "$HOME/.config/mise/config.toml")" "mine" "file backed up by the second install is restored"
rm -f "$HOME/.config/mise/config.toml"
reset_installer_state

# case_second_cycle: install, uninstall, edit, install, uninstall restores the
# edit, not the content from the first cycle.
printf 'v1\n' >"$HOME/.bashrc"
run_install --profile minimal
bash "$dotfiles_dir/uninstall.sh"
assert_eq "$(cat "$HOME/.bashrc")" "v1" "first cycle restores v1"
assert_eq "$(backup_cycles)" "1" "first cycle retired its marker"
printf 'v2\n' >"$HOME/.bashrc"
run_install --profile minimal
assert_eq "$(readlink "$HOME/.dotfiles-backup/original" | sed 's|.*/||')" "$(backup_dirs | tail -n 1)" "new cycle starts a new original"
bash "$dotfiles_dir/uninstall.sh"
assert_eq "$(cat "$HOME/.bashrc")" "v2" "second cycle restores the edit, not v1"
assert_eq "$(backup_cycles)" "2" "second cycle retired its marker"
assert_file_absent "$HOME/.dotfiles-backup/original"
printf 'alias mine=1\n' >"$HOME/.bashrc"
reset_installer_state

# case_src_wins_over_self_dir: re-running ~/.dotfiles/install.sh with
# DOTFILES_SRC re-copies from the source and mirrors it (deleted files go).
src_root="$DOTFILES_SRC"
tmpsrc="$(mktemp -d)/src"
cp -r "$DOTFILES_SRC" "$tmpsrc"
env DOTFILES_SRC="$tmpsrc" bash "$src_root/install.sh" --profile minimal
printf '# changed upstream\n' >"$tmpsrc/shell/profile"
printf 'new\n' >"$tmpsrc/extra-file"
env DOTFILES_SRC="$tmpsrc" bash "$dotfiles_dir/install.sh"
assert_eq "$(cat "$dotfiles_dir/shell/profile")" "# changed upstream" "update picked up the edit"
assert_eq "$(cat "$dotfiles_dir/extra-file")" "new" "update picked up a new file"
assert_ok "marker survives the update" -- test -f "$dotfiles_dir/.dotfiles-managed"
assert_linked .profile
rm -f "$tmpsrc/extra-file"
env DOTFILES_SRC="$tmpsrc" bash "$dotfiles_dir/install.sh"
assert_file_absent "$dotfiles_dir/extra-file"
assert_linked .profile
assert_file_absent "$HOME/.dotfiles.staging"
assert_file_absent "$HOME/.dotfiles.old"
# DOTFILES_SRC pointing at DOTFILES_DIR is a no-op, not a copy onto itself.
h4="$(home_hash)"
env DOTFILES_SRC="$dotfiles_dir" bash "$dotfiles_dir/install.sh"
assert_eq "$(home_hash)" "$h4" "SRC == DIR changes nothing"
bash "$dotfiles_dir/uninstall.sh" --purge
assert_file_absent "$dotfiles_dir"
rm -rf "$tmpsrc" "$HOME/.dotfiles-backup"

# case_refusal_advice_is_safe: following the refusal message literally, then
# installing (twice, so the swap path runs too), must not delete the moved
# directory.
reset_installer_state
mkdir -p "$HOME/.dotfiles"
printf 'my own bashrc\n' >"$HOME/.dotfiles/bashrc"
ln -sfn "$HOME/.dotfiles/bashrc" "$HOME/.bashrc"
err="$(run_install --profile minimal 2>&1 || true)"
mv_cmd="$(sed -n "s/.*for example: \(mv '[^']*' '[^']*'\),.*/\1/p" <<<"$err")"
assert_ok "refusal message contains a mv command" -- test -n "$mv_cmd"
eval "$mv_cmd"
moved="$(find "$HOME" -maxdepth 1 -name '.dotfiles.bak-*' | head -n 1)"
assert_ok "advice moved the directory" -- test -f "$moved/bashrc"
run_install --profile minimal
run_install --profile minimal
assert_eq "$(cat "$moved/bashrc")" "my own bashrc" "moved-aside directory survives the installer"
assert_ok "fresh install is ours" -- test -f "$dotfiles_dir/.dotfiles-managed"
assert_eq "$(find "$HOME" -maxdepth 1 \( -name '.dotfiles.old*' -o -name '.dotfiles.staging*' \) | wc -l | tr -d ' ')" "0" "no temporary directories left behind"
bash "$dotfiles_dir/uninstall.sh"
rm -rf "$moved"
rm -f "$HOME/.bashrc"
printf 'alias mine=1\n' >"$HOME/.bashrc"
reset_installer_state

# case_user_named_siblings_untouched: .staging and .old next to ~/.dotfiles are
# the user's if they exist; the installer's own temporary names are unique.
mkdir -p "$HOME/.dotfiles.staging" "$HOME/.dotfiles.old"
printf 'precious\n' >"$HOME/.dotfiles.staging/notes"
printf 'precious too\n' >"$HOME/.dotfiles.old/notes"
run_install --profile minimal
run_install --profile minimal
assert_eq "$(cat "$HOME/.dotfiles.staging/notes")" "precious" "user's .dotfiles.staging survives"
assert_eq "$(cat "$HOME/.dotfiles.old/notes")" "precious too" "user's .dotfiles.old survives"
bash "$dotfiles_dir/uninstall.sh"
rm -rf "$HOME/.dotfiles.staging" "$HOME/.dotfiles.old"
reset_installer_state

# case_dangling_user_link_is_not_ours: a dangling symlink into ~/.dotfiles that
# is not in our manifest (the user moved their own dotfiles away) is a user
# file: backed up as a symlink, restored by uninstall.
mkdir -p "$HOME/.dotfiles"
printf 'my own bashrc\n' >"$HOME/.dotfiles/bashrc"
ln -sfn "$HOME/.dotfiles/bashrc" "$HOME/.bashrc"
mv "$HOME/.dotfiles" "$HOME/mydots"
run_install --profile minimal
assert_eq "$(readlink "$HOME/.dotfiles-backup/original/.bashrc")" "$HOME/.dotfiles/bashrc" "dangling user link backed up as a symlink"
assert_linked .bashrc
bash "$dotfiles_dir/uninstall.sh"
assert_eq "$(readlink "$HOME/.bashrc")" "$HOME/.dotfiles/bashrc" "dangling user link restored"
assert_eq "$(cat "$HOME/mydots/bashrc")" "my own bashrc" "moved directory untouched"
rm -rf "$HOME/mydots"
rm -f "$HOME/.bashrc"
printf 'alias mine=1\n' >"$HOME/.bashrc"
reset_installer_state

# --- case_generated_git_config -------------------------------------------------
# ~/.config/git/config is a REAL file that only includes the repo settings and
# the local overrides, so tools that run `git config --global` (safe.directory,
# gh auth setup-git, user.email) never write into the tracked file in the repo.
gitglobal="$HOME/.config/git/config"
repo_gitcfg="$dotfiles_dir/config/git/config"
restore_gitcfg() { rm -rf "$gitglobal"; mkdir -p "$HOME/.config/git"; cp -a "$snap/.config/git/config" "$gitglobal"; }
reset_installer_state
restore_gitcfg
run_install --profile minimal
assert_ok "git config is a real file, not a link" -- test -f "$gitglobal" -a ! -L "$gitglobal"
assert_ok "git config includes the repo file (quoted, marked)" -- grep -qxF "$(printf '	path = "%s" # dotfiles:repo' "$repo_gitcfg")" "$gitglobal"
assert_ok "git config includes ~/.gitconfig.local" -- grep -qxF "	path = ~/.gitconfig.local" "$gitglobal"
assert_fail "git config is not in the link manifest" -- grep -qxF "$gitglobal" "$manifest"
assert_eq "$(cat "$HOME/.dotfiles-backup/original/.config/git/config")" "$(cat "$snap/.config/git/config")" "the user's git config was backed up"
repo_sum="$(sha256sum <"$repo_gitcfg")"
printf '[user]\n\temail = someone@example.invalid\n[safe]\n\tdirectory = /somewhere\n' >>"$gitglobal"
assert_eq "$(sha256sum <"$repo_gitcfg")" "$repo_sum" "a global write does not change the repo file"
# re-install keeps what tools added, makes no new backup, and changes nothing
h5="$(home_hash)"
run_install --profile minimal
assert_eq "$(home_hash)" "$h5" "re-install leaves an extended git config alone"
assert_eq "$(find "$HOME/.dotfiles-backup" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2" "no new backup for our own file"
# uninstall removes it only while it is untouched: this one was extended
out="$(bash "$dotfiles_dir/uninstall.sh" 2>&1)"
assert_ok "uninstall keeps an extended git config" -- grep -qF 'someone@example.invalid' "$gitglobal"
assert_ok "uninstall warns about it" -- grep -qi 'leaving it' <<<"$out"
assert_file_absent "$HOME/.config/dotfiles/generated"
restore_gitcfg
reset_installer_state

# untouched: install, uninstall, and the user's file is back; the install is idempotent
restore_gitcfg
run_install --profile "$DF_PROFILE"
h6="$(home_hash)"
run_install --profile "$DF_PROFILE"
assert_eq "$(home_hash)" "$h6" "second install rewrites nothing"
bash "$dotfiles_dir/uninstall.sh"
assert_ok "the user's git config is restored byte for byte" -- same_file "$gitglobal" "$snap/.config/git/config"
assert_file_absent "$HOME/.config/dotfiles/generated"
reset_installer_state

# a link left by an older install is replaced by a real file, never written through
restore_gitcfg
run_install --profile minimal
rm -f "$gitglobal"
ln -s "$repo_gitcfg" "$gitglobal"
printf '%s\n' "$gitglobal" >>"$manifest"
repo_sum="$(sha256sum <"$repo_gitcfg")"
run_install --profile minimal
assert_ok "old-style link becomes a real file" -- test -f "$gitglobal" -a ! -L "$gitglobal"
assert_eq "$(sha256sum <"$repo_gitcfg")" "$repo_sum" "repo file untouched by the migration"
assert_fail "old-style link left the manifest" -- grep -qxF "$gitglobal" "$manifest"
bash "$dotfiles_dir/uninstall.sh"
restore_gitcfg
reset_installer_state

# a user file that already includes nothing of ours is backed up, even with --dry-run announcing it
restore_gitcfg
out="$(run_install --profile minimal --dry-run 2>&1)"
assert_ok "dry run announces the generated file" -- grep -q "would write $gitglobal" <<<"$out"
assert_ok "dry run leaves the user's file alone" -- same_file "$gitglobal" "$snap/.config/git/config"
reset_installer_state

# --- case_git_config_quoting_and_relocation -------------------------------------
# The include path is a quoted git-config value, and a moved checkout gets its
# include line rewritten in place (tool-added settings stay).
fx2="$(mktemp -d)"
odd="$fx2/we#ird;d\"ir\\x y"
install_at() { env HOME="$fx2" DOTFILES_DIR="$1" bash "$DOTFILES_SRC/install.sh" --profile minimal >/dev/null 2>&1; }
cfg2="$fx2/.config/git/config"
assert_ok "install into a checkout path with # ; \" \ and a space" -- install_at "$odd"
assert_ok "the odd path is quoted and escaped" -- grep -qxF "$(printf '\tpath = "%s/we#ird;d\\"ir\\\\x y/config/git/config" # dotfiles:repo' "$fx2")" "$cfg2"
if command -v git >/dev/null; then
  assert_eq "$(HOME="$fx2" git config --file "$cfg2" --get-all include.path | head -n 1)" "$odd/config/git/config" "git reads the odd path back unchanged"
  assert_eq "$(HOME="$fx2" git config alias.s)" "status" "repo aliases resolve through the odd path"
fi
mv "$odd" "$fx2/moved"
printf '[user]\n\temail = keep@example.invalid\n' >>"$cfg2"
assert_ok "reinstall from the moved checkout" -- install_at "$fx2/moved"
assert_ok "include line follows the moved checkout" -- grep -qxF "$(printf '\tpath = "%s/moved/config/git/config" # dotfiles:repo' "$fx2")" "$cfg2"
assert_eq "$(grep -c 'dotfiles:repo' "$cfg2")" "1" "exactly one repo include after the move"
assert_ok "tool-added settings survive the move" -- grep -qF 'keep@example.invalid' "$cfg2"
if command -v git >/dev/null; then
  assert_eq "$(HOME="$fx2" git config alias.s)" "status" "repo aliases still resolve after the move"
  assert_eq "$(HOME="$fx2" git config user.email)" "keep@example.invalid" "tool-added identity still read after the move"
fi
# the unquoted line an earlier version wrote is migrated too
{ printf '%s; git config --global writes below this line.\n[include]\n\tpath = %s/moved/config/git/config\n[include]\n\tpath = ~/.gitconfig.local\n[user]\n\temail = old@example.invalid\n' "# Generated by the dotfiles installer" "$fx2"; } >"$cfg2"
assert_ok "reinstall over an older generated file" -- install_at "$fx2/moved"
assert_ok "old unquoted include is rewritten" -- grep -qxF "$(printf '\tpath = "%s/moved/config/git/config" # dotfiles:repo' "$fx2")" "$cfg2"
assert_eq "$(grep -c 'config/git/config' "$cfg2")" "1" "no duplicate repo include"
assert_ok "old file's settings survive" -- grep -qF 'old@example.invalid' "$cfg2"
rm -rf "$fx2"

rm -rf "$snap"
