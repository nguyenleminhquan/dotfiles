# Installer: links, backup, idempotence, profile switching, uninstall.
# One container per case file, so the scenarios below run in order and each
# leaves $HOME in the state the next one expects.

run_install() { bash "$DOTFILES_SRC/install.sh" "$@"; }
dotfiles_dir="$HOME/.dotfiles"
manifest="$HOME/.config/dotfiles/links"

# Destinations per profile, relative to $HOME (mirrors the symlink table).
minimal_dests=(
  .profile .bash_profile .bashrc .zshenv .zshrc .screenrc
  .config/git/config .config/micro/settings.json .local/bin/dotfiles
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
tracked=("${minimal_dests[@]}" "${server_extra[@]}" "${workstation_extra[@]}" .bash_logout .gitconfig)
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
assert_ok "backups are kept" -- test -d "$orig"

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

rm -rf "$snap"
