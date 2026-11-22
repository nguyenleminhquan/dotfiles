# One-off migration from the old dotfiles (tools/migrate-from-nobitagamer.sh).
# Every scenario builds a fake old home with made-up data (the repo is public)
# in a throwaway directory and runs the script with HOME pointing there, so the
# real home is never touched. The install it ends with skips the tool downloads
# (DOTFILES_NO_TOOLS): 50-server-tools.sh and 70-workstation.sh cover those.
# Runs on the u20-ws row (everything) and on r9 (only the offline profile case,
# profile_cases); the other rows skip it.
# SC2016: the snippets are meant to be expanded by the shell under test.
# SC2030/SC2031: HOME is changed in subshells on purpose.
# SC2088: a "~" inside a test message is meant literally.
# shellcheck disable=SC2016,SC2030,SC2031,SC2088

case "$DF_ROW" in
  u20-ws | r9) ;;
  *) return 0 ;;
esac
export DOTFILES_NO_TOOLS=1
mig=/src/tools/migrate-from-nobitagamer.sh
fx="$(mktemp -d)"
mkdir -p "$fx/win"
# A made-up token, built in pieces so that this file holds no token-shaped text.
tok="glpat-""aaaaaaaaaaaaaaaaaaaa"

# --- mask_userinfo ------------------------------------------------------------------------
# The script runs its main when sourced, so its function is cut out and evaluated.
eval "$(sed -n '/^mask_userinfo() {/,/^}/p' "$mig")"
masked() { mask_userinfo "$1"; printf '%s' "$MASKED"; }
assert_eq "$(masked 'https://u:p@ss@host.example/x')" 'https://<hidden>@host.example/x' "a password with @ is masked entirely"
assert_eq "$(masked 'https://u:pa/ss@host.example/x')" 'https://<hidden>@host.example/x' "a password with / is masked entirely"
assert_eq "$(masked 'https://tok@host.example')" 'https://<hidden>@host.example' "a token without a password is masked"
assert_eq "$(masked 'https://user:pw@host.example')" 'https://<hidden>@host.example' "user:password is masked"
assert_eq "$(masked 'see https://a@h1 and https://b:c@h2 here')" 'see https://<hidden>@h1 and https://<hidden>@h2 here' "every URL in a line is masked"
assert_eq "$(masked 'url.https://oauth2:abc@host.insteadof')" 'url.https://<hidden>@host.insteadof' "a git config key is masked"
for plain in 'https://github.com/org/repo' 'git@github.com:org/repo.git' 'no url at all' 'mailto:x@example.com'; do
  assert_eq "$(masked "$plain")" "$plain" "text without a URL userinfo is unchanged: $plain"
done
assert_eq "$(masked 'https://<hidden>@host.example')" 'https://<hidden>@host.example' "masking twice changes nothing"

# --- fixture ------------------------------------------------------------------------------
# History written by the real zsh, which is what the migration will read: its
# writer puts a backslash before every embedded newline and does not escape the
# backslashes already there, so a typed `curl \<newline> -H x` is stored as `\\<newline>`.
# zsh_history_entries sets zh_all (the commands typed) and zh_kept (those that survive).
zsh_history_entries() {
  zh_all=(
    $'curl https://api.example.com \\\n  -H "Authorization: Bearer abc"'
    ls
    $'mysql -u root \\\n  --password=hunter2 \\\n  -h db'
    date
    $'echo one \\\n  two'
    $'psql -h db \\\n  -c "select 1" \\\n  --password=hunter3'
    $'cat <<EOF\nhello\nEOF'
  )
  zh_kept=(ls date $'echo one \\\n  two' $'cat <<EOF\nhello\nEOF')
}
# zsh only saves and reads its history file in an interactive shell, so both
# helpers run a small script in a pty (script(1), as 70-workstation.sh does).
# zsh_write_history <file> <entries...>
zsh_write_history() {
  local f="$1"
  shift
  printf '%s\0' "$@" >"$fx/zsh-entries"
  cat >"$fx/zsh-write.zsh" <<'ZSH'
setopt extendedhistory
HISTSIZE=1000
SAVEHIST=1000
HISTFILE=$ZH_FILE
while IFS= read -r -d '' e; do print -rs -- "$e"; done <$ZH_ENTRIES
fc -W
ZSH
  script -qec "env ZH_FILE='$f' ZH_ENTRIES='$fx/zsh-entries' zsh -f -i '$fx/zsh-write.zsh'" /dev/null </dev/null >/dev/null
}
# zsh_entries <file>: the entries as zsh reads them, each ended by "@@END@@".
zsh_entries() {
  cat >"$fx/zsh-read.zsh" <<'ZSH'
setopt extendedhistory
HISTSIZE=100000
fc -R $ZH_FILE
# fc -R, then one more entry: the last entry of the list is the "current" event
# and is left out of $history, so the extra one takes that place.
print -rs -- ZH_SENTINEL
: >$ZH_OUT
for k in ${(onk)history}; do print -rn -- "${history[$k]}@@END@@" >>$ZH_OUT; done
ZSH
  script -qec "env ZH_FILE='$1' ZH_OUT='$fx/zsh-out' zsh -f -i '$fx/zsh-read.zsh'" /dev/null </dev/null >/dev/null
  sed 's/ZH_SENTINEL@@END@@$//' "$fx/zsh-out"
}

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

# local_layer <home> <variant>: what the old setup keeps outside the repo (fake values).
#   1  ~/.localrc sourced by the old zsh and bash, GNUPGHOME in the XDG location with a
#      keyring, ~/.foo sourced too, HISTFILE set, a pre-existing ~/.zshrc.local
#      without a final newline
#   2  no ~/.localrc, GNUPGHOME points at a directory with no keys, ~/.foo sourced
local_layer() {
  local h="$1" o="$1/.dotfiles"
  printf 'export GNUPGHOME="${XDG_CONFIG_HOME:-$HOME/.config}/gnupg"\n' >>"$o/shells/zsh/zshenv"
  {
    printf '[[ -a $HOME/.foo ]] && source "$HOME/.foo"\n'
    printf 'source "$HOME/.config/zsh/aliases/git.zsh"\n'
    printf 'HISTFILE=$HOME/.histfile-old\n'
  } >>"$o/shells/zsh/zshrc"
  printf 'export FOO_PROBE=from-foo\n' >"$h/.foo"
  if [ "$2" = 1 ]; then
    printf '[ -f ~/.localrc ] && source ~/.localrc\n' >>"$o/shells/zsh/zshrc"
    printf '[ -f "$HOME/.localrc" ] && . "$HOME/.localrc"\n' >>"$o/shells/bash/bash_profile"
    printf 'export LOCALRC_PROBE=from-localrc\nexport KUBECONFIG=$HOME/.kube/lab.example.yaml\nalias ll="ls -l"\n' >"$h/.localrc"
    mkdir -p "$h/.config/gnupg/private-keys-v1.d"
    printf 'fake key\n' >"$h/.config/gnupg/private-keys-v1.d/ABCD.key"
    printf 'fake trustdb\n' >"$h/.config/gnupg/trustdb.gpg"
    printf '# my zsh local\nalias zz=true' >"$h/.zshrc.local"
  else
    mkdir -p "$h/.config/gnupg/private-keys-v1.d"
  fi
}

# make_old_home <home>: a fake machine with the old setup. Variants (environment):
#   V_DOTS=0     no .dots file (the git origin alone identifies the old setup)
#   V_REALGIT=1  ~/.gitconfig is a real file
#   V_ZDOT=1     ZDOTDIR is ~/zdot instead of ~/.config/zsh
#   V_BIG=0      a short history
#   V_LOCAL=1|2  the old setup's local layer, see local_layer
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
	path = ~/.gitconfig_extra
	path = ~/.gitconfig_local
	path = ~/.gitconfig_extra2
[push]
	default = matching
[hub]
	protocol = https
EOF
  # A made-up token (built in pieces so that this file holds no token-shaped text).
  printf '[url "https://oauth2:%s@host.example"]\n\tinsteadOf = https://host.example/\n[http]\n\textraHeader = Authorization: Bearer abc\n' "$tok" >>"$o/development/git/gitconfig"
  printf '*.swp\n.idea/\n' >"$o/development/git/gitignore_global"
  if [ "${V_ZDOT:-0}" = 1 ]; then
    printf 'export ZDOTDIR="$HOME/zdot"  # two spaces before this comment\n' >"$o/shells/zsh/zshenv"
  else
    printf 'export ZDOTDIR=~/.config/zsh\n' >"$o/shells/zsh/zshenv"
  fi
  printf '# old zshrc\n' >"$o/shells/zsh/zshrc"
  printf '# old alias file\n' >"$o/shells/zsh/aliases/git.zsh"
  printf '# old bashrc\n' >"$o/shells/bash/bashrc"
  printf '# old bash_profile\n' >"$o/shells/bash/bash_profile"
  printf '[tools]\nnode = "20"\nopentofu = "1.13.9"\n' >"$o/apps/mise/config.toml"
  printf '[env]\nGITLAB_TOKEN = "%s"\n' "$tok" >>"$o/apps/mise/config.toml"
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
  mkdir -p "$o/with space"
  printf '# a file whose directory has a space\n' >"$o/with space/rc"
  mklink "$h" "$o/with space/rc" ".config/spaced link"
  mklink "$h" "$o/shells/inputrc" .local/share/x/y
  mklink "$h" "$o/shells/vimrc" bin/z
  # find prunes node_modules and .git only as directories: a link with such a
  # name is found, a link inside such a directory is not looked at.
  mklink "$h" "$o/shells/vimrc" .config/node_modules
  mkdir -p "$h/proj/node_modules"
  ln -s "$o/shells/vimrc" "$h/proj/node_modules/not-scanned"
  printf '# real profile\n' >"$h/.profile"
  : >"$h/.gitconfig_local"
  printf '[extra]\n\tone = 1\n' >"$h/.gitconfig_extra"
  printf '[extra]\n\ttwo = 2\n' >"$h/.gitconfig_extra2"
  printf 'compdump\n' >"$h/.config/zsh/.zcompdump"

  if [ "${V_NOHIST:-0}" = 1 ]; then
    :
  elif [ "${V_ZHIST:-0}" = 1 ]; then
    zsh_history_entries
    zsh_write_history "$h/.config/zsh/.zsh_history" "${zh_all[@]}"
    zsh_write_history "$h.hist-expected" "${zh_kept[@]}"
  elif [ "${V_ZDOT:-0}" = 1 ]; then
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

  if [ -n "${V_LOCAL:-}" ]; then local_layer "$h" "$V_LOCAL"; fi

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

# --- the marked blocks the migration writes, and shells to look at them ---------------------------
blk_begin_rc='# >>> migrated from nobitagamer/dotfiles: ~/.localrc >>>'
blk_begin_gpg='# >>> migrated from nobitagamer/dotfiles: GNUPGHOME >>>'
blk_end='# <<< migrated from nobitagamer/dotfiles <<<'
shim_line='[ -r "$HOME/.localrc" ] && . "$HOME/.localrc"'
# probe_bash_i <home> <command>: run it in an interactive bash (no tty, so it stays bash).
probe_bash_i() { env -u DOTFILES_DIR HOME="$1" bash -i -c "$2" </dev/null 2>/dev/null; }
# probe_zsh_i <home> <command>: run it in an interactive zsh on a pty.
probe_zsh_i() { env -u DOTFILES_DIR HOME="$1" TERM=dumb script -qec "zsh -i -c '$2'" /dev/null </dev/null 2>/dev/null | tr -d '\r'; }

# --- case_profile: --profile picks what is installed; a host that is not WSL has no default ----------
# Needs no network (minimal installs no tools), so the r9 row runs it with the network off.
profile_cases() {
  local w="$fx/w" w_before out rc=0 rout bk_w
  V_BIG=0 V_LOCAL=1 make_old_home "$w"
  w_before="$(tree_hash "$w")"
  if [ "$DF_ROW" != u20-ws ]; then
    expect_refusal "$w" 'no default profile'
    out="$(run_mig "$w" --dry-run)" && _fail "a dry run without --profile on a host that is not WSL should refuse"
    assert_ok "the dry run says to pass --profile" -- grep -qF 'pass --profile' <<<"$out"
  fi
  out="$(run_mig "$w" --profile bogus)" && _fail "an unknown profile should be refused"
  assert_ok "an unknown profile is named" -- grep -qF 'unknown profile: bogus' <<<"$out"
  assert_eq "$(tree_hash "$w")" "$w_before" "refusals change nothing"

  out="$(run_mig "$w" --dry-run --profile minimal)" || { printf '%s\n' "$out" >&2; _fail "dry run with --profile minimal failed"; }
  assert_ok "the dry run installs the chosen profile" -- grep -qF 'install.sh --profile minimal' <<<"$out"
  assert_ok "and says that minimal has nothing to compare the mise config with" -- grep -qF 'installs no tools' <<<"$out"
  assert_eq "$(tree_hash "$w")" "$w_before" "a dry run with --profile writes nothing"

  rc=0
  out="$(run_mig "$w" --profile=minimal)" || rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; _fail "migrate --profile minimal failed"; fi
  bk_w="$(backup_of "$w")"
  assert_eq "$(cat "$w/.config/dotfiles/profile")" minimal "the saved profile is minimal"
  assert_symlink "$w/.zshenv" "$w/.dotfiles/shell/zshenv"
  assert_ok "~/.dotfiles is the new one" -- test -f "$w/.dotfiles/.dotfiles-managed"
  assert_ok "the links into the old setup are gone" -- test ! -L "$w/.config/zsh/.zshrc"
  assert_file_absent "$w/.config/mise/conf.d/dotfiles.toml"
  assert_ok "the mise config is kept in the backup" -- grep -qF 'node = "20"' "$bk_w/.config/mise/config.toml"
  assert_eq "$(sed -n '/^# >>> migrated/,$p' "$w/.bashrc.local")" "$(printf '%s\n%s\n%s' "$blk_begin_rc" "$shim_line" "$blk_end")" "the ~/.localrc shim is in ~/.bashrc.local"
  assert_ok "and in ~/.zshrc.local" -- grep -qxF "$shim_line" "$w/.zshrc.local"
  assert_eq "$(probe_bash_i "$w" 'echo "P:$LOCALRC_PROBE:E"' | grep -o 'P:[^:]*:E')" "P:from-localrc:E" "interactive bash reads ~/.localrc under minimal"
  assert_eq "$(env HOME="$w" bash -c '. ~/.bashrc; echo "G:$GNUPGHOME"')" "G:$w/.config/gnupg" "an ssh-like shell sees GNUPGHOME under minimal"
  assert_eq "$(env HOME="$w" bash -c '. ~/.bashrc; echo ok' 2>&1)" ok "non-interactive bash prints nothing under minimal"

  (cd / && HOME="$w" bash "$w/.local/bin/dotfiles" uninstall >/dev/null 2>&1) || _fail "dotfiles uninstall failed (profile minimal)"
  rout="$(cd / && HOME="$w" bash "$bk_w/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed (profile minimal)"; }
  assert_eq "$(tree_hash "$w")" "$w_before" "restore.sh brings back the exact state (profile minimal)"
}

# The r9 row is not WSL: it only runs the profile case, offline (minimal installs nothing).
if [ "$DF_ROW" = r9 ]; then
  if [ "$DF_PROFILE" = minimal ]; then profile_cases; fi
  rm -rf "$fx"
  return 0
fi


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
  "safe.directory (4 values)" "history:" "would be kept" "found 20 symlinks that point into the old dotfiles" "walk of " \
  "would run: DOTFILES_SRC=/src bash /src/install.sh --profile workstation" \
  'config.workstation.toml' '-node = "20"' "dry run done: nothing was written"; do
  assert_ok "dry run says: $want" -- grep -qF -- "$want" <<<"$dry_out"
done
assert_fail "dry run never prints the identity values" -- grep -qF -e test.user@example.com -e 0123456789ABCDEF <<<"$dry_out"
# Secrets that sit in printed values are masked: a token in a URL (key and
# value), an Authorization header, an [env] token in the mise diff.
for secret in "$tok" 'Bearer abc' 'oauth2:'; do
  assert_fail "dry run never prints a token ($secret)" -- grep -qF -- "$secret" <<<"$dry_out"
done
for want in 'http.extraheader = <hidden>' 'url.https://<hidden>@host.example.insteadof = https://host.example/' \
  '-<hidden: looks like a secret>'; do
  assert_ok "dry run masks: $want" -- grep -qF -- "$want" <<<"$dry_out"
done

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
assert_eq "$(git config --file "$lc" http.extraheader)" "Authorization: Bearer abc" "an Authorization header stays in gitconfig.local (it is only masked in the output)"
assert_ok "so does a URL with a token" -- grep -qF "oauth2:$tok@host.example" "$lc"
assert_eq "$(git config --file "$lc" --get-all include.path | paste -sd ' ' -)" "~/.gitconfig_extra ~/.gitconfig_extra2" \
  "kept includes keep their order, only the empty one is gone"
assert_ok "the run printed no token" -- test "$(grep -cF -e "$tok" -e 'Bearer abc' <<<"$out")" = 0
assert_ok "the run masked the header" -- grep -qF 'http.extraheader = <hidden>' <<<"$out"
assert_ok "the run says how to get updates" -- grep -qF 'DOTFILES_REPO=<repo url>' <<<"$out"
assert_eq "$(git config --file "$a/.config/git/config" --get-all include.path | wc -l | tr -d ' ')" 2 "the generated global config includes the repo and the local file"
assert_ok "the link in ~/.local/share is gone" -- test ! -L "$a/.local/share/x/y"
assert_ok "the link in ~/bin is gone" -- test ! -L "$a/bin/z"
assert_ok "the link whose target has a space is gone" -- test ! -L "$a/.config/spaced link"
assert_ok "and links.tsv has it with its target" -- grep -qF "$(printf '%s\t%s' "$a/.config/spaced link" "$a/.dotfiles/with space/rc")" "$bk/links.tsv"
assert_fail "core.editor is gone" -- git config --file "$lc" core.editor
assert_fail "alias.s is not repeated (the repo has it)" -- git config --file "$lc" alias.s
assert_fail "the include of the empty file is gone" -- grep -qxF '~/.gitconfig_local' <<<"$(git config --file "$lc" --get-all include.path)"
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
assert_eq "$(wc -l <"$a.expected-links" | tr -d ' ')" 20 "the fixture has 20 links into the old setup"
assert_eq "$(readlink "$a/proj/node_modules/not-scanned")" "$a/.dotfiles/shells/vimrc" "a link inside a node_modules directory is not scanned"
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
assert_symlink "$a/.config/mise/conf.d/dotfiles.toml" "$a/.dotfiles/config/mise/config.toml"
assert_file_absent "$a/.config/mise/config.toml"
assert_ok "micro settings are a copy, not a link into the repo" -- test -f "$a/.config/micro/settings.json" -a ! -L "$a/.config/micro/settings.json"
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
assert_eq "$(LC_ALL=C comm -13 <(printf '%s\n' "$list_before") <(tree_list "$a"))" ./.local/bin \
  "no file or directory is left over except the empty ~/.local/bin the install made"
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

# --- case_zsh_history: history written by the real zsh, \ continuations holding secrets ----
command -v zsh >/dev/null 2>&1 || _fail "the u20-ws row has zsh"
z="$fx/z"
V_BIG=0 V_ZHIST=1 make_old_home "$z"
zh="$z/.config/zsh/.zsh_history"
assert_ok "the fixture has zsh's doubled backslash before the newline" -- grep -qxF "mysql -u root \\\\" <<<"$(sed 's/^: [0-9]*:[0-9]*;//' "$zh")"
assert_eq "$(zsh_entries "$zh" | grep -o '@@END@@' | wc -l | tr -d ' ')" 7 "zsh reads 7 entries from the fixture"
rc=0
out="$(run_mig "$z")" || rc=$?
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; _fail "migrate with a zsh-written history failed"; fi
assert_eq "$(zsh_entries "$z/.zsh_history" | grep -o '@@END@@' | wc -l | tr -d ' ')" 4 "zsh reads 4 entries from the filtered history: whole commands only"
assert_eq "$(zsh_entries "$z/.zsh_history")" "$(zsh_entries "$z.hist-expected")" "the entries zsh reads are exactly the ordinary ones"
assert_fail "no part of a secret command is left" -- grep -qE 'hunter|Authorization|api.example|select 1|root' "$z/.zsh_history"

# --- case_no_history: nothing to filter is not an error ---------------------------------------
n="$fx/n"
V_NOHIST=1 make_old_home "$n"
n_before="$(tree_hash "$n")"
dry="$(run_mig "$n" --dry-run)" || { printf '%s\n' "$dry" >&2; _fail "dry run without a history failed"; }
assert_ok "the dry run notes that there is no history" -- grep -qF 'no .zsh_history found' <<<"$dry"
assert_eq "$(tree_hash "$n")" "$n_before" "and writes nothing"
rc=0
out="$(run_mig "$n")" || rc=$?
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; _fail "migrate without a history failed"; fi
assert_ok "the run notes that there is no history" -- grep -qF 'no .zsh_history found' <<<"$out"
assert_file_absent "$n/.zsh_history"
bk_n="$(backup_of "$n")"
(cd / && HOME="$n" bash "$n/.local/bin/dotfiles" uninstall >/dev/null 2>&1) || _fail "dotfiles uninstall failed (no history)"
rout="$(cd / && HOME="$n" bash "$bk_n/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed (no history)"; }
assert_eq "$(tree_hash "$n")" "$n_before" "restored byte for byte (no history)"

# --- case_partial_install: an install that got as far as its manifest -------------------------
cp -a /src "$fx/partial"
cat >"$fx/partial/install.sh" <<'PARTIAL'
#!/usr/bin/env bash
mkdir -p "$HOME/.config/dotfiles"
printf '%s\n' "$HOME/.zshrc" >"$HOME/.config/dotfiles/links"
echo "partial install" >&2
exit 1
PARTIAL
p="$fx/p"
make_old_home "$p"
p_before="$(tree_hash "$p")"
rc=0
out="$(MIG="$fx/partial/tools/migrate-from-nobitagamer.sh" run_mig "$p")" || rc=$?
assert_ok "the partial install fails the migration" -- test "$rc" -ne 0
assert_ok "and the output says how to roll back" -- grep -qF 'restore.sh' <<<"$out"
bk_p="$(backup_of "$p")"
p_mid="$(tree_hash "$p")"
rc=0
rout="$(cd / && HOME="$p" bash "$bk_p/restore.sh" 2>&1)" || rc=$?
assert_ok "restore.sh refuses while the install's manifest exists" -- test "$rc" -ne 0
assert_ok "and says to uninstall first" -- grep -qF 'dotfiles uninstall' <<<"$rout"
assert_eq "$(tree_hash "$p")" "$p_mid" "a refused restore.sh changes nothing"
rm "$p/.config/dotfiles/links" # what uninstall.sh does with it
rout="$(cd / && HOME="$p" bash "$bk_p/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed after the manifest was removed"; }
assert_eq "$(tree_hash "$p")" "$p_before" "then restore.sh brings back the exact state"

# --- case_local_layer: ~/.localrc and GNUPGHOME survive, what is not carried is reported -------
l="$fx/l"
V_BIG=0 V_LOCAL=1 make_old_home "$l"
l_before="$(tree_hash "$l")"
l_list="$(tree_list "$l")"
localrc_sha="$(sha256sum <"$l/.localrc")"
cp "$l/.zshrc.local" "$fx/zshrc.local.orig"
dry="$(run_mig "$l" --dry-run)" || { printf '%s\n' "$dry" >&2; _fail "dry run with a local layer failed"; }
assert_eq "$(tree_hash "$l")" "$l_before" "local layer: the dry run writes nothing"
assert_eq "$(tree_list "$l")" "$l_list" "local layer: the dry run creates nothing"
for want in "would add the ~/.localrc shim to ~/.zshrc.local (existing file, backed up)" \
  "would add the ~/.localrc shim to ~/.bashrc.local (new file)" \
  'would add GNUPGHOME="$HOME/.config/gnupg" to ~/.config/dotfiles/env.local (new file)' \
  "~/.localrc: kept (shim in ~/.zshrc.local, ~/.bashrc.local)" "~/.foo: no longer read" \
  "GNUPGHOME: carried to env.local" "ZDOTDIR: history migrated to ~/.zsh_history" "HISTFILE: no longer read"; do
  assert_ok "local layer dry run says: $want" -- grep -qF -- "$want" <<<"$dry"
done
assert_fail "a file that links into the old dotfiles is not reported" -- grep -qF 'git.zsh: ' <<<"$dry"

rc=0
out="$(run_mig "$l")" || rc=$?
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; _fail "migrate with a local layer failed"; fi
bk_l="$(backup_of "$l")"
assert_ok "the run says what stops being read" -- grep -qF "~/.foo: no longer read" <<<"$out"
assert_ok "and hints at the shim" -- grep -qF 'kept through a shim' <<<"$out"
assert_eq "$(sha256sum <"$l/.localrc")" "$localrc_sha" "~/.localrc is not modified"
assert_eq "$(cat "$l/.bashrc.local")" "$(printf '%s\n%s\n%s' "$blk_begin_rc" "$shim_line" "$blk_end")" \
  "a new ~/.bashrc.local holds exactly the shim"
assert_eq "$(cat "$l/.zshrc.local")" "$(
  cat "$fx/zshrc.local.orig"
  printf '\n%s\n%s\n%s' "$blk_begin_rc" "$shim_line" "$blk_end"
)" "the existing ~/.zshrc.local keeps its content and gets the shim after it"
assert_eq "$(cat "$l/.config/dotfiles/env.local")" "$(printf '%s\n%s\n%s' "$blk_begin_gpg" 'export GNUPGHOME="$HOME/.config/gnupg"' "$blk_end")" \
  'env.local exports GNUPGHOME written with $HOME'
assert_eq "$(stat -c %a "$l/.bashrc.local")" 644 "the new rc file is world-readable like the others"
assert_ok "the existing ~/.zshrc.local is in the backup" -- cmp -s "$bk_l/.zshrc.local" "$fx/zshrc.local.orig"
# Behaviour: interactive shells read ~/.localrc, every shell gets GNUPGHOME, no shell prints anything.
assert_eq "$(probe_bash_i "$l" 'echo "P:$LOCALRC_PROBE:E"' | grep -o 'P:[^:]*:E')" "P:from-localrc:E" "interactive bash reads ~/.localrc"
assert_eq "$(probe_zsh_i "$l" 'echo "P:$LOCALRC_PROBE:E"' | grep -o 'P:[^:]*:E')" "P:from-localrc:E" "interactive zsh reads ~/.localrc"
assert_eq "$(env HOME="$l" bash -c '. ~/.bashrc; echo "G:$GNUPGHOME"')" "G:$l/.config/gnupg" "an ssh-like shell sees GNUPGHOME"
assert_eq "$(env HOME="$l" zsh -c 'echo "G:$GNUPGHOME"')" "G:$l/.config/gnupg" "a non-interactive zsh sees GNUPGHOME"
assert_eq "$(env HOME="$l" bash -c '. ~/.bashrc; echo "${LOCALRC_PROBE:-unset}"')" unset "~/.localrc is not read by a non-interactive shell (as before)"
assert_eq "$(env HOME="$l" bash -c '. ~/.bashrc; echo ok' 2>&1)" ok "non-interactive bash prints nothing"
assert_eq "$(env HOME="$l" bash -lc 'echo ok' 2>&1)" ok "login bash prints nothing"
assert_eq "$(env HOME="$l" zsh -c 'echo ok' 2>&1)" ok "non-interactive zsh prints nothing"

# Rolling back: the files the migration created go, the existing one is as it was.
(cd / && HOME="$l" bash "$l/.local/bin/dotfiles" uninstall >/dev/null 2>&1) || _fail "dotfiles uninstall failed (local layer)"
rout="$(cd / && HOME="$l" bash "$bk_l/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed (local layer)"; }
assert_eq "$(tree_hash "$l")" "$l_before" "local layer: restore.sh brings back the exact state, ~/.zshrc.local byte for byte"
assert_file_absent "$l/.bashrc.local"
assert_file_absent "$l/.config/dotfiles/env.local"

# A file that was edited after the migration is kept, with a warning; so is an edited block.
l2="$fx/l2"
V_BIG=0 V_LOCAL=1 make_old_home "$l2"
out="$(run_mig "$l2")" || { printf '%s\n' "$out" >&2; _fail "migrate failed (edited local files)"; }
bk_l2="$(backup_of "$l2")"
printf 'alias mine=true\n' >>"$l2/.bashrc.local"
sed -i 's|^\[ -r "\$HOME/.localrc" \] .*|& # edited|' "$l2/.zshrc.local"
(cd / && HOME="$l2" bash "$l2/.local/bin/dotfiles" uninstall >/dev/null 2>&1) || _fail "dotfiles uninstall failed (edited local files)"
rout="$(cd / && HOME="$l2" bash "$bk_l2/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed (edited local files)"; }
assert_ok "an edited created file is kept" -- grep -qF 'alias mine=true' "$l2/.bashrc.local"
assert_ok "and restore.sh says so" -- grep -qF "$l2/.bashrc.local changed since the migration" <<<"$rout"
assert_ok "an edited block is kept" -- grep -qF '# edited' "$l2/.zshrc.local"
assert_ok "and restore.sh says so too" -- grep -qF "$l2/.zshrc.local: the migration block was edited" <<<"$rout"
assert_file_absent "$l2/.config/dotfiles/env.local"

# Idempotence: a file that already has the block does not get a second one, and is not touched on rollback.
l3="$fx/l3"
V_BIG=0 V_LOCAL=1 make_old_home "$l3"
printf '# mine\n%s\n%s\n%s\n' "$blk_begin_rc" "$shim_line" "$blk_end" >"$l3/.zshrc.local"
l3_before="$(tree_hash "$l3")"
out="$(run_mig "$l3")" || { printf '%s\n' "$out" >&2; _fail "migrate failed (block already there)"; }
bk_l3="$(backup_of "$l3")"
assert_eq "$(grep -cF "$blk_begin_rc" "$l3/.zshrc.local")" 1 "no second block in a file that has one"
assert_ok "the run says the block is there already" -- grep -qF "~/.zshrc.local already has the ~/.localrc shim" <<<"$out"
(cd / && HOME="$l3" bash "$l3/.local/bin/dotfiles" uninstall >/dev/null 2>&1) || _fail "dotfiles uninstall failed (block already there)"
rout="$(cd / && HOME="$l3" bash "$bk_l3/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed (block already there)"; }
assert_eq "$(tree_hash "$l3")" "$l3_before" "restore.sh leaves the block that was there before"

# Nothing to carry: no ~/.localrc, a GNUPGHOME directory without keys.
m="$fx/m"
V_BIG=0 V_LOCAL=2 make_old_home "$m"
m_before="$(tree_hash "$m")"
out="$(run_mig "$m")" || { printf '%s\n' "$out" >&2; _fail "migrate failed (nothing to carry)"; }
bk_m="$(backup_of "$m")"
assert_file_absent "$m/.zshrc.local"
assert_file_absent "$m/.bashrc.local"
assert_file_absent "$m/.config/dotfiles/env.local"
assert_ok "GNUPGHOME without keys is reported as no longer read" -- grep -qF "GNUPGHOME: no longer read" <<<"$out"
assert_ok "so is a file the old shells sourced" -- grep -qF "~/.foo: no longer read" <<<"$out"
assert_fail "no shim is announced" -- grep -qF 'kept through a shim' <<<"$out"
assert_eq "$(env HOME="$m" bash -c '. ~/.bashrc; echo "${GNUPGHOME:-unset}"')" unset "GNUPGHOME is not set from an empty directory"
(cd / && HOME="$m" bash "$m/.local/bin/dotfiles" uninstall >/dev/null 2>&1) || _fail "dotfiles uninstall failed (nothing to carry)"
rout="$(cd / && HOME="$m" bash "$bk_m/restore.sh" 2>&1)" || { printf '%s\n' "$rout" >&2; _fail "restore.sh failed (nothing to carry)"; }
assert_eq "$(tree_hash "$m")" "$m_before" "restored byte for byte (nothing to carry)"

profile_cases

# The real home was never touched.
assert_file_absent "$HOME/.dotfiles-backup"
assert_file_absent "$HOME/.gitconfig.local"
rm -rf "$fx"
