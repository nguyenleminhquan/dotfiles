# One-off migration from the old dotfiles (tools/migrate-from-nobitagamer.sh).
# Every scenario builds a fake old home with made-up data (the repo is public)
# in a throwaway directory and runs the script with HOME pointing there, so the
# real home is never touched. The install it ends with skips the tool downloads
# (DOTFILES_NO_TOOLS): 50-server-tools.sh and 70-workstation.sh cover those.
# Runs on the u20-ws row only; the other rows skip it.
# SC2016: the snippets are meant to be expanded by the shell under test.
# SC2030/SC2031: HOME is changed in subshells on purpose.
# SC2088: a "~" inside a test message is meant literally.
# shellcheck disable=SC2016,SC2030,SC2031,SC2088

[ "$DF_ROW" = u20-ws ] || return 0
export DOTFILES_NO_TOOLS=1
mig=/src/tools/migrate-from-nobitagamer.sh
fx="$(mktemp -d)"
mkdir -p "$fx/win"

# --- fixture ------------------------------------------------------------------------------
# mklink <home> <target> <path relative to home>: a link into the old setup, remembered.
mklink() {
  mkdir -p "$(dirname "$1/$3")"
  ln -s "$2" "$1/$3"
  printf '%s\n' "$1/$3" >>"$1.expected-links"
}

# History: two bulk blocks of ordinary commands around the special entries, so
# that the whole file has about 2300 entries and 340 KB like the real one.
# Writes $1 (the input) and $2 (what the filter must produce).
make_history() {
  local in="$1" out="$2" bulk=1100 pem=BEGINPEM key=KEYPEM
  awk -v n="$bulk" -v s=1 'BEGIN { for (i = s; i < s + n; i++) printf ": %d:0;kubectl get pods --namespace team-%d --output wide --sort-by=.metadata.name # filler to give the entry a realistic size\n", 1700000000 + i, i }' >"$fx/bulk1"
  awk -v n="$bulk" -v s=5000 'BEGIN { for (i = s; i < s + n; i++) printf ": %d:0;kubectl get pods --namespace team-%d --output wide --sort-by=.metadata.name # filler to give the entry a realistic size\n", 1700000000 + i, i }' >"$fx/bulk2"
  # Kept, in order.
  cat >"$fx/kept" <<'EOF'
: 1700001001:0;ls -la
: 1700001002:0;git status
: 1700001005:0;echo one\
two
: 1700001010:0;kubectl create token sa
plain old command
: 1700001014:0;date
: 1700001015:0;uptime
EOF
  # Everything in the input, dropped entries included. The key words are
  # spelled with placeholders so this file holds no private key marker.
  sed -e "s/$pem/-----BEGIN OPENSSH/" -e "s/$key/ PRIVATE KEY-----/" >"$fx/special" <<'HIST'
: 1700001001:0;ls -la
: 1700001002:0;git status
: 1700001003:0;cat > key.pem <<EOF\
BEGINPEMKEYPEM\
bm90IGEgcmVhbCBrZXk=\
-----END OPENSSH PRIVATE KEY-----\
EOF
: 1700001004:0;export TOKEN=x
: 1700001005:0;echo one\
two
: 1700001006:0;BEGINPEMKEYPEM
: 1700001007:0;bm90IGEgcmVhbCBrZXk=
: 1700001008:0;-----END OPENSSH PRIVATE KEY-----
: 1700001009:0;grep -rn -- '-----BEGIN' .
: 1700001010:0;kubectl create token sa
plain old command
: 1700001011:0;curl -H 'Authorization: Bearer x' https://example.com
: 1700001012:0;-----BEGIN dangling block without an end
: 1700001014:0;date
: 1700001015:0;uptime
HIST
  cat "$fx/bulk1" "$fx/special" "$fx/bulk2" >"$in"
  cat "$fx/bulk1" "$fx/kept" "$fx/bulk2" >"$out"
}

# make_old_home <home>: a fake machine with the old setup. Variants (environment):
#   V_DOTS=0     no .dots file (the git origin alone identifies the old setup)
#   V_REALGIT=1  ~/.gitconfig is a real file
#   V_ZDOT=1     ZDOTDIR is ~/zdot instead of ~/.config/zsh
#   V_BIG=0      a short history
make_old_home() {
  local h="$1" o="$1/.dotfiles"
  : >"$h.expected-links"
  mkdir -p "$o/development/git" "$o/shells/zsh/aliases" "$o/shells/bash" "$o/apps/mise" "$o/apps/micro" \
    "$h/.config/mise" "$h/.config/zsh" "$h.win/ssh" "$h.win/data"
  HOME="$h" git init -q "$o"
  HOME="$h" git -C "$o" remote add origin https://github.com/nobitagamer/dotfiles
  if [ "${V_DOTS:-1}" = 1 ]; then : >"$o/.dots"; fi

  cat >"$o/development/git/gitconfig" <<'EOF'
[user]
	name = Test User
	email = test.user@example.com
	signingkey = 0123456789ABCDEF
[credential]
	helper = manager
	credentialStore = gpg
	cacheOptions = --timeout 300
[credential "https://git.internal.example"]
	provider = generic
[safe]
	directory = /srv/repo-a
	directory = /srv/repo-b
	directory = "/srv/with space/proj#1"
	directory = /srv/repo-c
[alias]
	s = status
	co = checkout
	lg = log --graph --oneline
[core]
	editor = /usr/bin/nvim
	excludesfile = ~/.gitignore_global
[include]
	path = ~/.gitconfig_local
[push]
	default = matching
[hub]
	protocol = https
EOF
  printf '*.swp\n.idea/\n' >"$o/development/git/gitignore_global"
  if [ "${V_ZDOT:-0}" = 1 ]; then
    printf 'export ZDOTDIR="$HOME/zdot"\n' >"$o/shells/zsh/zshenv"
  else
    printf 'export ZDOTDIR=~/.config/zsh\n' >"$o/shells/zsh/zshenv"
  fi
  printf '# old zshrc\n' >"$o/shells/zsh/zshrc"
  printf '# old alias file\n' >"$o/shells/zsh/aliases/git.zsh"
  printf '# old bashrc\n' >"$o/shells/bash/bashrc"
  printf '# old bash_profile\n' >"$o/shells/bash/bash_profile"
  printf '[tools]\nnode = "20"\nopentofu = "1.13.9"\n' >"$o/apps/mise/config.toml"
  printf 'format = "$all"\n' >"$o/apps/starship.toml"
  printf '{ "autosave": 5 }\n' >"$o/apps/micro/settings.json"
  printf 'set -g mouse on\n' >"$o/shells/tmux.conf"
  printf 'set number\n' >"$o/shells/vimrc"
  printf 'set bell-style none\n' >"$o/shells/inputrc"

  if [ "${V_REALGIT:-0}" = 1 ]; then
    cp "$o/development/git/gitconfig" "$h/.gitconfig"
  else
    mklink "$h" "$o/development/git/gitconfig" .gitconfig
  fi
  mklink "$h" .dotfiles/shells/zsh/zshenv .zshenv
  mklink "$h" "$o/shells/bash/bashrc" .bashrc
  mklink "$h" "$o/shells/bash/bash_profile" .bash_profile
  mklink "$h" "$o/development/git/gitignore_global" .gitignore_global
  mklink "$h" "$o/shells/tmux.conf" .tmux.conf
  mklink "$h" "$o/shells/vimrc" .vimrc
  mklink "$h" "$o/shells/inputrc" .inputrc
  mklink "$h" ../../.dotfiles/apps/mise/config.toml .config/mise/config.toml
  mklink "$h" "$o/apps/starship.toml" .config/starship.toml
  mklink "$h" "$o/apps/micro/settings.json" .config/micro/settings.json
  mklink "$h" "$o/shells/zsh/zshrc" .config/zsh/.zshrc
  mklink "$h" ../../../.dotfiles/shells/zsh/aliases/git.zsh .config/zsh/aliases/git.zsh
  mklink "$h" "$h/.config/zsh/.zshrc" .config/chain
  mklink "$h" "$o/gone" .config/dangling
  mklink "$h" "$o/shells/vimrc" .config/deep/a/b/c/link
  printf '# real profile\n' >"$h/.profile"
  : >"$h/.gitconfig_local"
  printf 'compdump\n' >"$h/.config/zsh/.zcompdump"

  if [ "${V_ZDOT:-0}" = 1 ]; then
    mkdir -p "$h/zdot"
    printf ': 1700001001:0;ls -la\n: 1700001004:0;export TOKEN=x\n: 1700001002:0;git status\n' >"$h/zdot/.zsh_history"
    printf ': 1700001001:0;ls -la\n: 1700001002:0;git status\n' >"$h.hist-expected"
  elif [ "${V_BIG:-1}" = 1 ]; then
    make_history "$h/.config/zsh/.zsh_history" "$h.hist-expected"
  else
    make_history "$h/.config/zsh/.zsh_history" "$h.hist-expected"
    head -n 40 "$h/.config/zsh/.zsh_history" >"$fx/short"
    cat "$fx/short" "$fx/special" >"$h/.config/zsh/.zsh_history"
    cat "$fx/short" "$fx/kept" >"$h.hist-expected"
  fi

  # Not ours and not into the old setup: must survive untouched, and find must
  # not descend into a symlinked directory (the link inside data points into
  # the old setup).
  printf 'fake key\n' >"$h.win/ssh/id_fake"
  ln -s "$h.win/ssh" "$h/.ssh"
  ln -s "$h.win/data" "$h/data"
  ln -s "$o/shells/zsh/zshrc" "$h.win/data/trap"
  ln -s /etc/hostname "$h/.config/outside"
}

# tree_hash <home>: sha256 over every file and link under the home except the
# backup directory (content of files, target of links).
tree_hash() {
  (
    cd "$1" || exit 1
    find . -path ./.dotfiles-backup -prune -o \( -type f -o -type l \) -print0 |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' path; do
        if [ -L "$path" ]; then
          printf 'L %s -> %s\n' "$path" "$(readlink "$path")"
        else
          printf 'F %s %s\n' "$path" "$(sha256sum <"$path" | cut -d' ' -f1)"
        fi
      done |
      sha256sum | cut -d' ' -f1
  )
}
# tree_list <home>: every path (directories too), without the backup directory.
tree_list() { (cd "$1" && find . -path ./.dotfiles-backup -prune -o -print | LC_ALL=C sort); }

# run_mig <home> [args...]: the migration with that home, from a neutral directory.
run_mig() {
  local h="$1"
  shift
  (cd / && HOME="$h" bash "${MIG:-$mig}" "$@" 2>&1)
}
gitc() { (cd "$1" && HOME="$1" GIT_CONFIG_NOSYSTEM=1 git config "${@:2}"); }
gitlist() { (cd "$1" && HOME="$1" GIT_CONFIG_NOSYSTEM=1 git config --list | LC_ALL=C sort); }

# expect_refusal <home> <regex> [script]: the run fails with that message and changes nothing.
expect_refusal() {
  local h="$1" re="$2" before bk_before out rc=0
  before="$(tree_hash "$h")"
  bk_before="$(find "$h/.dotfiles-backup" 2>/dev/null | LC_ALL=C sort || true)"
  out="$(MIG="${3:-$mig}" run_mig "$h")" || rc=$?
  [ "$rc" -ne 0 ] || _fail "migrate should refuse ($re)"
  if ! grep -qE -- "$re" <<<"$out"; then
    printf '%s\n' "$out" >&2
    _fail "refusal does not say: $re"
  fi
  assert_eq "$(tree_hash "$h")" "$before" "a refused run changes nothing ($re)"
  assert_eq "$(find "$h/.dotfiles-backup" 2>/dev/null | LC_ALL=C sort || true)" "$bk_before" "and writes no backup ($re)"
}
assert_ne() { [ "$1" != "$2" ] || _fail "$3"; }

backup_of() { sed -n 's/^backup=//p' "$1/.config/dotfiles/migrated-from-nobitagamer"; }

# --- case_dry_run: prints everything, writes nothing --------------------------------------
a="$fx/a"
make_old_home "$a"
cp "$a/.dotfiles/development/git/gitconfig" "$fx/old-gitconfig"
hash_before="$(tree_hash "$a")"
list_before="$(tree_list "$a")"
gitlist "$a" >"$fx/git-before"

SECONDS=0
dry_out="$(run_mig "$a" --dry-run)" || { printf '%s\n' "$dry_out" >&2; _fail "dry run failed"; }
dry_secs=$SECONDS
printf 'dry run took %ss\n' "$dry_secs" >&2
assert_ok "a dry run takes well under 10 s on 2300 history entries" -- test "$dry_secs" -lt 10
assert_eq "$(tree_hash "$a")" "$hash_before" "dry run: files and links are byte for byte the same"
assert_eq "$(tree_list "$a")" "$list_before" "dry run: no file or directory was created"
assert_file_absent "$a/.dotfiles-backup"
assert_file_absent "$a/.config/dotfiles"
assert_file_absent "$a/.zsh_history"
assert_file_absent "$a/.gitconfig.local"
for want in "unlink $a/.gitconfig -> " "unlink $a/.config/zsh/aliases/git.zsh -> " "unlink $a/.config/chain -> " \
  "core.editor: dropped" "include.path = ~/.gitconfig_local: dropped" "core.excludesfile: dropped" \
  "alias.s: skipped" "alias.co = checkout" "push.default = matching" "hub.protocol = https" \
  "safe.directory (4 values)" "history:" "would be kept" "would remove 16 symlinks" \
  "would run: DOTFILES_SRC=/src bash /src/install.sh --profile workstation" \
  'config.workstation.toml' '-node = "20"' "dry run done: nothing was written"; do
  assert_ok "dry run says: $want" -- grep -qF -- "$want" <<<"$dry_out"
done
assert_fail "dry run never prints the identity values" -- grep -qF -e test.user@example.com -e 0123456789ABCDEF <<<"$dry_out"

# --- case_refusals: only the old setup is migrated -------------------------------------------
g="$fx/g1"
V_BIG=0 make_old_home "$g"
rm "$g/.dotfiles/.dots"
HOME="$g" git -C "$g/.dotfiles" remote set-url origin https://example.com/other/dotfiles
expect_refusal "$g" 'is not the old dotfiles'

g="$fx/g2"
V_BIG=0 make_old_home "$g"
rm -rf "$g/.dotfiles"
expect_refusal "$g" 'does not exist'

g="$fx/g3"
V_BIG=0 make_old_home "$g"
cp -a /src "$g/.dotfiles/mig-src"
expect_refusal "$g" 'inside the old' "$g/.dotfiles/mig-src/tools/migrate-from-nobitagamer.sh"

g="$fx/g4"
V_BIG=0 make_old_home "$g"
printf '[user]\n\tname = Someone\n' >"$g/.gitconfig.local"
expect_refusal "$g" '.gitconfig.local already has content'

g="$fx/g5"
V_BIG=0 make_old_home "$g"
printf ': 1700000000:0;ls\n' >"$g/.zsh_history"
expect_refusal "$g" '.zsh_history already has content'

g="$fx/g6"
V_BIG=0 make_old_home "$g"
mkdir -p "$g/.dotfiles-backup/20200101-000000"
ln -s "$g/.dotfiles-backup/20200101-000000" "$g/.dotfiles-backup/original"
# The backup directory is excluded from the hash, so check the refusal by hand.
rc=0
out="$(run_mig "$g")" || rc=$?
assert_ok "an active install cycle blocks the migration" -- test "$rc" -ne 0
assert_ok "and says why" -- grep -qF 'an install cycle is active' <<<"$out"
assert_ok "and the old setup stays in place" -- test -f "$g/.dotfiles/.dots"

# --- case_migrate: the real run --------------------------------------------------------------
rc=0
out="$(run_mig "$a")" || rc=$?
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; _fail "migrate failed"; fi
bk="$(backup_of "$a")"
assert_ok "the backup directory exists" -- test -d "$bk"
assert_ok "restore.sh is executable" -- test -x "$bk/restore.sh"
assert_ne "$(readlink "$a/.dotfiles-backup/original" 2>/dev/null || true)" "$bk" \
  "the migration backup is not the install cycle's original (uninstall must not restore it file by file)"

# History: exactly the ordinary commands, in order, the format kept.
assert_ok "~/.zsh_history is the filtered history" -- cmp -s "$a/.zsh_history" "$a.hist-expected"
assert_eq "$(grep -c . "$a/.zsh_history")" "$(grep -c . "$a.hist-expected")" "history line count"
assert_fail "no secret is left in the history" -- grep -qE 'TOKEN=|BEGIN|Authorization|dangling|bm90IGEg' "$a/.zsh_history"
assert_ok "the original history is untouched" -- cmp -s "$a/.config/zsh/.zsh_history" "$bk/.config/zsh/.zsh_history"
assert_eq "$(stat -c %a "$a/.zsh_history")" 600 "the history is private"

# Git: the identity and everything else moved to ~/.gitconfig.local.
assert_file_absent "$a/.gitconfig"
lc="$a/.gitconfig.local"
assert_eq "$(git config --file "$lc" user.email)" test.user@example.com "gitconfig.local has the email"
assert_eq "$(git config --file "$lc" user.name)" "Test User" "gitconfig.local has the name"
assert_eq "$(git config --file "$lc" user.signingkey)" 0123456789ABCDEF "gitconfig.local has the signing key"
assert_eq "$(git config --file "$lc" credential.helper)" manager "gitconfig.local has the credential helper"
assert_eq "$(git config --file "$lc" credential.https://git.internal.example.provider)" generic "a credential subsection survives"
assert_eq "$(git config --file "$lc" --get-all safe.directory | wc -l | tr -d ' ')" 4 "every safe.directory survives"
assert_eq "$(git config --file "$lc" --get-all safe.directory | sed -n 3p)" "/srv/with space/proj#1" "a safe.directory with a space and a # survives"
assert_eq "$(git config --file "$lc" alias.co)" checkout "an alias that the repo lacks survives"
assert_eq "$(git config --file "$lc" push.default)" matching "push.default survives"
assert_fail "core.editor is gone" -- git config --file "$lc" core.editor
assert_fail "alias.s is not repeated (the repo has it)" -- git config --file "$lc" alias.s
assert_fail "the include of the empty file is gone" -- git config --file "$lc" include.path
assert_fail "the excludes file key is gone" -- git config --file "$lc" core.excludesfile
assert_eq "$(stat -c %a "$lc")" 600 "gitconfig.local is private"
assert_eq "$(gitc "$a" user.email)" test.user@example.com "git config user.email reads the old value through the include"
assert_eq "$(gitc "$a" push.default)" matching "the local value wins over the repo's"
assert_fail "core.editor is unset" -- gitc "$a" core.editor
# Behaviour is preserved: every old key=value is still effective, except the three dropped ones.
gitlist "$a" >"$fx/git-after"
printf '%s\n' 'core.editor=/usr/bin/nvim' 'core.excludesfile=~/.gitignore_global' 'include.path=~/.gitconfig_local' | LC_ALL=C sort >"$fx/git-dropped"
assert_eq "$(LC_ALL=C comm -23 "$fx/git-before" "$fx/git-after")" "$(cat "$fx/git-dropped")" \
  "git config --list lost exactly the dropped keys"
# The old global excludes still apply, now through git's default file.
assert_eq "$(cat "$a/.config/git/ignore")" "$(printf '*.swp\n.idea/')" "~/.config/git/ignore has the old excludes"
HOME="$a" git init -q "$fx/work"
touch "$fx/work/a.swp" "$fx/work/b.txt"
assert_ok "git still ignores *.swp" -- env HOME="$a" git -C "$fx/work" check-ignore -q a.swp
assert_fail "and still not b.txt" -- env HOME="$a" git -C "$fx/work" check-ignore -q b.txt

# The links into the old setup are gone (or are the installer's new ones); others are untouched.
while IFS= read -r p; do
  if [ -L "$p" ]; then
    case "$(readlink "$p")" in
      */development/* | */shells/* | */apps/*) _fail "still a link into the old layout: $p" ;;
    esac
  fi
done <"$a.expected-links"
for rel in .gitconfig .tmux.conf .vimrc .inputrc .gitignore_global .config/zsh/.zshrc .config/zsh/aliases/git.zsh .config/chain .config/dangling; do
  assert_file_absent "$a/$rel"
done
assert_eq "$(wc -l <"$a.expected-links" | tr -d ' ')" 16 "the fixture has 16 links into the old setup"
assert_eq "$(readlink "$a/.ssh")" "$a.win/ssh" "a link outside the old setup is untouched"
assert_eq "$(readlink "$a/data")" "$a.win/data" "so is a link to a directory"
assert_eq "$(readlink "$a.win/data/trap")" "$a/.dotfiles/shells/zsh/zshrc" "a symlinked directory is not entered"
assert_eq "$(readlink "$a/.config/outside")" /etc/hostname "nor is a link to a system file"
assert_ok "the history file stays where it was" -- test -f "$a/.config/zsh/.zsh_history"
assert_ok "the empty ~/.gitconfig_local stays" -- test -e "$a/.gitconfig_local"

# The install ran: new ~/.dotfiles, profile, links.
assert_ok "~/.dotfiles is the new one" -- test -f "$a/.dotfiles/.dotfiles-managed"
assert_file_absent "$a/.dotfiles/.dots"
assert_eq "$(cat "$a/.config/dotfiles/profile")" workstation "the workstation profile is installed"
assert_symlink "$a/.zshenv" "$a/.dotfiles/shell/zshenv"
assert_symlink "$a/.config/mise/config.toml" "$a/.dotfiles/config/mise/config.toml"
assert_ok "~/.config/git/config is generated" -- grep -qF 'Generated by the dotfiles installer' "$a/.config/git/config"

# The backup has every original.
assert_ok "the old checkout is in the backup" -- test -f "$bk/old-dotfiles/.dots"
assert_ok "with its history" -- test -d "$bk/old-dotfiles/.git"
assert_ok "~/.gitconfig content is in the backup" -- cmp -s "$bk/.gitconfig" "$fx/old-gitconfig"
assert_ok "~/.zshenv content" -- grep -qF 'ZDOTDIR=~/.config/zsh' "$bk/.zshenv"
assert_ok "~/.bashrc content" -- grep -qF '# old bashrc' "$bk/.bashrc"
assert_ok "~/.bash_profile content" -- grep -qF '# old bash_profile' "$bk/.bash_profile"
assert_ok "~/.profile" -- grep -qF '# real profile' "$bk/.profile"
assert_ok "the mise config" -- grep -qF 'node = "20"' "$bk/.config/mise/config.toml"
assert_ok "the zsh history is in the backup" -- test -s "$bk/.config/zsh/.zsh_history"
assert_ok "the zsh compdump" -- test -f "$bk/.config/zsh/.zcompdump"
assert_eq "$(cut -f1 "$bk/links.tsv" | LC_ALL=C sort)" "$(LC_ALL=C sort "$a.expected-links")" "links.tsv lists every removed link"
assert_ok "links.tsv records the targets" -- grep -qF "$(printf '%s\t%s' "$a/.zshenv" .dotfiles/shells/zsh/zshenv)" "$bk/links.tsv"

# What the user is told.
for want in "core.editor: dropped" "include.path = ~/.gitconfig_local: dropped" "alias.co = checkout" "hub.protocol = https" \
  "safe.directory (4 values)" "roll back: dotfiles uninstall && bash $bk/restore.sh" '-node = "20"'; do
  assert_ok "the run says: $want" -- grep -qF -- "$want" <<<"$out"
done

# A second run is refused.
expect_refusal "$a" 'already migrated'

# --- case_round_trip: uninstall, restore.sh, and everything is as before -----------------------
state_after_migrate="$(tree_hash "$a")"
rc=0
rout="$(cd / && HOME="$a" bash "$bk/restore.sh" 2>&1)" || rc=$?
assert_ok "restore.sh refuses while the new dotfiles are installed" -- test "$rc" -ne 0
assert_ok "and says to uninstall first" -- grep -qF 'dotfiles uninstall' <<<"$rout"
assert_eq "$(tree_hash "$a")" "$state_after_migrate" "a refused restore.sh changes nothing"

(cd / && HOME="$a" bash "$a/.local/bin/dotfiles" uninstall >/dev/null 2>&1) || _fail "dotfiles uninstall failed"

# A foreign ~/.dotfiles blocks restore.sh.
mv "$a/.dotfiles" "$fx/new-copy"
mkdir "$a/.dotfiles"
touch "$a/.dotfiles/mine"
state_blocked="$(tree_hash "$a")"
rc=0
rout="$(cd / && HOME="$a" bash "$bk/restore.sh" 2>&1)" || rc=$?
assert_ok "restore.sh refuses when ~/.dotfiles is occupied" -- test "$rc" -ne 0
assert_ok "and says so" -- grep -qF 'is occupied' <<<"$rout"
assert_eq "$(tree_hash "$a")" "$state_blocked" "nothing changed"
rm -rf "$a/.dotfiles"
mv "$fx/new-copy" "$a/.dotfiles"

rout="$(cd / && HOME="$a" bash "$bk/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed"; }
assert_ok "restore.sh prints what it does" -- grep -qF 'moving' <<<"$rout"
assert_eq "$(tree_hash "$a")" "$hash_before" "after migrate, uninstall and restore.sh the home is byte for byte what it was"
# The only things left over are the empty directories the install made.
assert_eq "$(LC_ALL=C comm -13 <(printf '%s\n' "$list_before") <(tree_list "$a"))" "$(printf '%s\n' ./.local ./.local/bin)" \
  "no file or directory is left over except the empty ones the install made"
assert_ok "~/.gitconfig resolves again" -- test -e "$a/.gitconfig"
assert_ok "~/.gitconfig is the old content" -- cmp -s "$a/.gitconfig" "$fx/old-gitconfig"
assert_file_absent "$a/.zsh_history"
assert_file_absent "$a/.gitconfig.local"
assert_file_absent "$a/.config/git/ignore"
assert_file_absent "$a/.config/dotfiles/migrated-from-nobitagamer"
assert_ok "the old clone is back" -- test -f "$a/.dotfiles/.dots"
assert_ok "and the backup keeps the new copy" -- test -f "$bk/new-dotfiles/.dotfiles-managed"
gitlist "$a" >"$fx/git-restored"
assert_ok "git config --list is what it was" -- cmp -s "$fx/git-before" "$fx/git-restored"

# restore.sh can be run again, and the migration can too.
rout="$(cd / && HOME="$a" bash "$bk/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "second restore.sh failed"; }
assert_eq "$(tree_hash "$a")" "$hash_before" "a second restore.sh changes nothing"
rc=0
out="$(run_mig "$a")" || rc=$?
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; _fail "migrating again after a rollback failed"; fi
assert_ok "the second migration works" -- test -f "$a/.gitconfig.local"

# --- case_failure: a failing install leaves a state restore.sh recovers -----------------------
cp -a /src "$fx/broken"
printf '#!/usr/bin/env bash\necho "injected failure" >&2\nexit 1\n' >"$fx/broken/install.sh"
e="$fx/e"
make_old_home "$e"
e_before="$(tree_hash "$e")"
rc=0
out="$(MIG="$fx/broken/tools/migrate-from-nobitagamer.sh" run_mig "$e")" || rc=$?
assert_ok "a failing install fails the migration" -- test "$rc" -ne 0
assert_ok "the failure is reported" -- grep -qF 'injected failure' <<<"$out"
bk_e="$(backup_of "$e")"
assert_ok "the output says how to roll back" -- grep -qF "bash $bk_e/restore.sh" <<<"$out"
assert_ok "the old checkout had been moved" -- test ! -e "$e/.dotfiles"
assert_ok "restore.sh exists" -- test -x "$bk_e/restore.sh"
assert_ok "the run is marked, so it is not repeated blindly" -- test -f "$e/.config/dotfiles/migrated-from-nobitagamer"
expect_refusal "$e" 'already migrated|does not exist'
rout="$(cd / && HOME="$e" bash "$bk_e/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh after a failed install failed"; }
assert_eq "$(tree_hash "$e")" "$e_before" "restore.sh brings back the exact state after a failed install"

# --- case_variants: a real ~/.gitconfig, ZDOTDIR elsewhere, no .dots, an empty history ---------
f="$fx/f"
V_REALGIT=1 V_ZDOT=1 V_DOTS=0 make_old_home "$f"
: >"$f/.zsh_history"
cp "$f/.gitconfig" "$fx/f-gitconfig"
f_before="$(tree_hash "$f")"
rc=0
out="$(run_mig "$f")" || rc=$?
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; _fail "variant migrate failed"; fi
bk_f="$(backup_of "$f")"
assert_ok "the history comes from ZDOTDIR" -- cmp -s "$f/.zsh_history" "$f.hist-expected"
assert_ok "a real ~/.gitconfig is moved into the backup" -- cmp -s "$bk_f/.gitconfig" "$fx/f-gitconfig"
assert_file_absent "$f/.gitconfig"
assert_eq "$(gitc "$f" user.email)" test.user@example.com "the email survives"
assert_ok "the history that lives outside ~/.config/zsh is backed up too" -- cmp -s "$bk_f/zsh_history.orig" "$f/zdot/.zsh_history"
(cd / && HOME="$f" bash "$f/.local/bin/dotfiles" uninstall >/dev/null 2>&1) || _fail "dotfiles uninstall failed (variant)"
rout="$(cd / && HOME="$f" bash "$bk_f/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed (variant)"; }
assert_eq "$(tree_hash "$f")" "$f_before" "the variant is restored byte for byte, the empty history included"

# The real home was never touched.
assert_file_absent "$HOME/.dotfiles-backup"
assert_file_absent "$HOME/.gitconfig.local"
rm -rf "$fx"
