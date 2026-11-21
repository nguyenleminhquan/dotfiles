# The `dotfiles` command: profile, doctor, update and uninstall.
# Doctor is checked against a real install of the profile, with stub binaries
# standing in for the mise tools (the downloads are covered by
# 50-server-tools.sh); update and uninstall run in throwaway homes. Everything
# works offline: file:// URLs replace GitHub.
# SC2016: the snippets are meant to be expanded by the shell under test.
# shellcheck disable=SC2016
export DOTFILES_NO_TOOLS=1
cfg=/src/config/mise/config.toml
df="$HOME/.local/bin/dotfiles"

bash /src/install.sh --profile "$DF_PROFILE" >/dev/null 2>&1
assert_ok "install linked the dotfiles command" -- test -x "$df"

fx="$(mktemp -d)"
git_ok=0
if command -v git >/dev/null 2>&1; then git_ok=1; fi

# df_out <cmd...>: output of the command, whatever its exit status.
# df_rc <cmd...>: its exit status only.
df_out() { "$@" 2>&1 || true; }
df_rc() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

assert_ne() { [ "$1" != "$2" ] || _fail "$3"; }

# --- case_profile ----------------------------------------------------------------------
assert_eq "$("$df" profile)" "$DF_PROFILE" "dotfiles profile prints the installed profile"
assert_eq "$(bash -lc 'command -v dotfiles')" "$df" "a login shell finds dotfiles"
mkdir -p "$fx/empty-home"
assert_eq "$(HOME="$fx/empty-home" df_rc /src/bin/dotfiles profile)" 1 "profile without an install exits 1"
assert_ok "profile without an install explains itself" -- \
  grep -qi 'not installed\|no saved profile' <<<"$(HOME="$fx/empty-home" df_out /src/bin/dotfiles profile)"

# --- case_usage --------------------------------------------------------------------------
assert_ne "$(df_rc "$df" bogus)" 0 "an unknown command fails"
assert_ne "$(df_rc "$df")" 0 "no command fails"
assert_ok "usage lists the commands" -- grep -q 'doctor' <<<"$(df_out "$df" bogus)"
assert_eq "$(df_rc "$df" help)" 0 "help exits 0"
for flag in help -h --help; do
  assert_eq "$("$df" "$flag" 2>/dev/null | head -n 1)" "usage: dotfiles <command>" "$flag prints the usage on stdout"
  assert_eq "$("$df" "$flag" 2>&1 >/dev/null)" "" "$flag prints nothing on stderr"
  assert_eq "$(df_rc "$df" "$flag")" 0 "$flag exits 0"
done
assert_eq "$("$df" bogus 2>/dev/null)" "" "bad usage prints nothing on stdout"
assert_ok "bad usage prints the usage on stderr" -- grep -q "^usage: dotfiles" <<<"$(df_out "$df" bogus)"

# --- case_doctor ------------------------------------------------------------------------
# What the doctor expects: the commands in config/mise/commands.*, one line per
# mise tool ("<command> <mise key>"). The files and the mise configs must list
# the same tools, so a swapped tool cannot leave the doctor failing every install.
# cmds_of <file>: the commands; keys_of <file>: the mise keys; both ignore comments.
cmds_of() { awk '{ sub(/#.*/, "") } NF { print $1 }' "$1"; }
keys_of() { awk '{ sub(/#.*/, "") } NF { print $2 }' "$1" | LC_ALL=C sort; }
# toml_keys <file>: the keys of its [tools] table, quotes removed (registry names
# such as opentofu and python have none; backend keys such as aqua:... do).
toml_keys() {
  awk '/^\[/ { t = ($0 == "[tools]"); next } t && /^[^# \t]/ { k = $0; sub(/ *=.*/, "", k); gsub(/"/, "", k); print k }' "$1" | LC_ALL=C sort
}
assert_eq "$(keys_of /src/config/mise/commands.server)" "$(toml_keys "$cfg")" \
  "commands.server lists exactly the tools of config.toml"
assert_eq "$(keys_of /src/config/mise/commands.workstation)" "$(toml_keys /src/config/mise/config.workstation.toml)" \
  "commands.workstation lists exactly the tools of config.workstation.toml"
assert_eq "$(cmds_of /src/config/mise/commands.server | sort | uniq -d)" "" "no command is listed twice"
assert_ne "$(cmds_of /src/config/mise/commands.server | wc -l | tr -d ' ')" 0 "commands.server is not empty"
tool_cmds=()
if [ "$DF_PROFILE" != minimal ]; then
  mapfile -t tool_cmds < <(cmds_of /src/config/mise/commands.server; [ "$DF_PROFILE" != workstation ] || cmds_of /src/config/mise/commands.workstation)
fi
(
  # shellcheck source=/dev/null
  . /src/lib/doctor.sh
  assert_eq "$(_df_doctor_tools "$DF_PROFILE" | paste -sd ' ' -)" "${tool_cmds[*]-}" \
    "doctor expects exactly the commands in the files for $DF_PROFILE"
  # The workstation profile adds its own file to the server one.
  assert_eq "$(_df_doctor_tools workstation | wc -l | tr -d ' ')" \
    "$(($(cmds_of /src/config/mise/commands.server | wc -l) + $(cmds_of /src/config/mise/commands.workstation | wc -l)))" \
    "workstation checks the server and the workstation commands"
  assert_eq "$(_df_doctor_tools minimal)" "" "minimal expects no tools"
)

stubs=()
for t in ${tool_cmds[@]+"${tool_cmds[@]}"}; do
  printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/$t"
  chmod +x "$HOME/.local/bin/$t"
  stubs+=("$HOME/.local/bin/$t")
done

doctor_out="$(df_out "$df" doctor)"
assert_eq "$(df_rc "$df" doctor)" 0 "doctor exits 0 on a healthy install"
assert_eq "$(grep -Ecv '^(OK|WARN|FAIL) ' <<<"$doctor_out" || true)" 0 "every doctor line starts with OK, WARN or FAIL"
assert_eq "$(grep -c '^FAIL' <<<"$doctor_out" || true)" 0 "a healthy install has no FAIL line"
for what in 'bash -c' 'bash -lc' 'ssh-like bash' 'PATH order' 'profile'; do
  assert_ok "doctor reports: $what" -- grep -q "^OK .*$what" <<<"$doctor_out"
done

# The old setup put Homebrew on PATH, sometimes through /etc/environment, which
# user scope cannot undo: a WARN naming it, never a FAIL.
assert_ok "no linuxbrew on PATH is an OK line" -- grep -Eq '^OK +PATH: no /home/linuxbrew' <<<"$doctor_out"
brew_path="$PATH:/home/linuxbrew/.linuxbrew/bin"
out="$(PATH="$brew_path" df_out "$df" doctor)"
assert_ok "linuxbrew on PATH is a WARN" -- grep -Eq '^WARN +PATH contains /home/linuxbrew.*/etc/environment' <<<"$out"
assert_eq "$(PATH="$brew_path" df_rc "$df" doctor)" 0 "and does not fail the doctor"

# A package that is on this row is OK, one that is not is a WARN and never a FAIL.
for p in git screen curl ssh openssl ping; do
  if command -v "$p" >/dev/null 2>&1; then
    assert_ok "package $p present is OK" -- grep -Eq "^OK +package: $p" <<<"$doctor_out"
  else
    assert_ok "package $p missing is a WARN" -- grep -Eq "^WARN +package: $p" <<<"$doctor_out"
  fi
done

# Rootless ping depends on net.ipv4.ping_group_range (the file is replaced here).
if [ "$(id -u)" != 0 ]; then
  printf '1 0\n' >"$fx/range"
  out="$(DF_PING_GROUP_RANGE_FILE="$fx/range" df_out "$df" doctor)"
  assert_ok "a closed ping range is a WARN" -- grep -Eq '^WARN +rootless ping' <<<"$out"
  assert_eq "$(DF_PING_GROUP_RANGE_FILE="$fx/range" df_rc "$df" doctor)" 0 "a closed ping range does not fail the doctor"
  printf '0 2147483647\n' >"$fx/range"
  out="$(DF_PING_GROUP_RANGE_FILE="$fx/range" df_out "$df" doctor)"
  assert_ok "an open ping range is OK" -- grep -Eq '^OK +rootless ping' <<<"$out"
fi

# zsh: its startup time as information, or a note that it is not there.
if command -v zsh >/dev/null 2>&1; then
  assert_ok "doctor prints the zsh startup time" -- grep -Eq '^OK +zsh startup: [0-9]+ ms' <<<"$doctor_out"
elif [ "$DF_PROFILE" = minimal ]; then
  assert_ok "minimal without zsh is fine" -- grep -Eq '^OK +zsh' <<<"$doctor_out"
else
  assert_ok "server without zsh is a WARN" -- grep -Eq '^WARN +zsh' <<<"$doctor_out"
fi

if [ "$DF_PROFILE" = minimal ]; then
  assert_ok "minimal expects no tools" -- grep -Eq '^OK +tools: none expected' <<<"$doctor_out"
  assert_fail "minimal never looks at trip" -- grep -q 'trip' <<<"$doctor_out"
else
  assert_ok "all tools found" -- grep -Eq '^OK +tools: all [0-9]+ found' <<<"$doctor_out"
  # trippy has no unprivileged mode on Linux: it needs CAP_NET_RAW.
  if [ "$(id -u)" != 0 ]; then
    assert_ok "trip needs CAP_NET_RAW" -- grep -Eq '^WARN +trip.*CAP_NET_RAW' <<<"$doctor_out"
  fi
  # A missing tool is a FAIL naming it; the others stay OK.
  rm -f "$HOME/.local/bin/kubectl"
  out="$(df_out "$df" doctor)"
  assert_eq "$(df_rc "$df" doctor)" 1 "a missing tool fails the doctor"
  assert_ok "the FAIL names the tool" -- grep -Eq '^FAIL +tool: kubectl' <<<"$out"
  assert_eq "$(grep -c '^FAIL' <<<"$out")" 1 "only the missing tool fails"
  printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/kubectl"
  chmod +x "$HOME/.local/bin/kubectl"
  assert_eq "$(df_rc "$df" doctor)" 0 "doctor passes again once the tool is back"
fi

# A line printed by a startup file breaks scripts and scp. ~/.bashrc.local only
# runs in interactive shells, so it cannot; ~/.config/dotfiles/env.local is read
# by every shell, so it can. The doctor looks at login and ssh-like sessions
# (plain `bash -c` reads no file at all).
assert_file_absent ~/.bashrc.local
printf 'echo hi\n' >~/.bashrc.local
assert_eq "$(df_rc "$df" doctor)" 0 "output from ~/.bashrc.local is interactive-only and does not fail the doctor"
rm -f ~/.bashrc.local

mkdir -p ~/.config/dotfiles
printf 'echo hi\n' >~/.config/dotfiles/env.local
out="$(df_out "$df" doctor)"
assert_eq "$(df_rc "$df" doctor)" 1 "output from env.local fails the doctor"
assert_ok "the FAIL line names the login shell" -- grep -Eq '^FAIL +bash -lc' <<<"$out"
assert_ok "the FAIL line names the ssh-like shell" -- grep -Eq '^FAIL +ssh-like bash' <<<"$out"
assert_ok "plain bash -c still passes" -- grep -Eq '^OK +bash -c' <<<"$out"
# The same file can also put ~/.local/bin ahead of the system directories.
printf 'PATH="$HOME/.local/bin:$PATH"\nexport PATH\n' >~/.config/dotfiles/env.local
out="$(df_out "$df" doctor)"
assert_eq "$(df_rc "$df" doctor)" 1 "a PATH with .local/bin before /usr/bin fails the doctor"
assert_ok "the FAIL line names the PATH" -- grep -Eq '^FAIL +PATH order' <<<"$out"
rm -f ~/.config/dotfiles/env.local
assert_eq "$(df_rc "$df" doctor)" 0 "doctor passes again once env.local is gone"

# Nothing installed: the doctor says so.
assert_eq "$(HOME="$fx/empty-home" df_rc /src/bin/dotfiles doctor)" 1 "doctor without an install fails"
assert_ok "doctor without an install names the profile" -- \
  grep -Eq '^FAIL +profile' <<<"$(HOME="$fx/empty-home" df_out /src/bin/dotfiles doctor)"

# The stubs were only for the doctor.
if [ "${#stubs[@]}" -gt 0 ]; then rm -f "${stubs[@]}"; fi

# The workstation profile checks commands.server and commands.workstation. With
# the second file gone the check must say so, not quietly look at the first only.
mkdir -p "$fx/ws-home/.config/dotfiles" "$fx/ws-copy"
echo workstation >"$fx/ws-home/.config/dotfiles/profile"
cp -a /src/. "$fx/ws-copy/"
rm -f "$fx/ws-copy/config/mise/commands.workstation"
out="$(HOME="$fx/ws-home" DOTFILES_DIR="$fx/ws-copy" df_out "$fx/ws-copy/bin/dotfiles" doctor)"
assert_ok "a missing commands.workstation is a FAIL" -- grep -Eq '^FAIL +tools: no command list for workstation' <<<"$out"
assert_eq "$(HOME="$fx/ws-home" DOTFILES_DIR="$fx/ws-copy" df_rc "$fx/ws-copy/bin/dotfiles" doctor)" 1 "and fails the doctor"
rm -rf "$fx/ws-home" "$fx/ws-copy"

# --- case_install_runs_doctor ---------------------------------------------------------------
# The installer's last step is the doctor; its output is printed, a FAIL turns
# the exit status non-zero after everything else is done, a dry run skips it.
mkdir -p "$fx/ih1" "$fx/ih2" "$fx/ih3" "$fx/ih4"
out="$(HOME="$fx/ih1" DOTFILES_SRC=/src bash /src/install.sh --profile minimal 2>&1)" || _fail "a healthy install exits 0: $out"
assert_ok "install prints the doctor's profile line" -- grep -Eq '^OK +profile: minimal' <<<"$out"
assert_ok "and its session checks" -- grep -Eq '^OK +bash -lc' <<<"$out"
out="$(HOME="$fx/ih2" DOTFILES_SRC=/src bash /src/install.sh --profile minimal --dry-run 2>&1)"
assert_eq "$(grep -Ec '^(OK|WARN|FAIL) ' <<<"$out" || true)" 0 "a dry run does not run the doctor"
mkdir -p "$fx/ih3/.config/dotfiles"
printf 'echo hi\n' >"$fx/ih3/.config/dotfiles/env.local"
rc=0
out="$(HOME="$fx/ih3" DOTFILES_SRC=/src bash /src/install.sh --profile minimal 2>&1)" || rc=$?
assert_eq "$rc" 1 "a doctor FAIL makes the installer exit 1"
assert_ok "and the installer says so" -- grep -q 'doctor reported FAIL' <<<"$out"
assert_ok "the doctor output is there" -- grep -Eq '^FAIL +bash -lc' <<<"$out"
assert_symlink "$fx/ih3/.bashrc" "$fx/ih3/.dotfiles/shell/bashrc"
assert_eq "$(cat "$fx/ih3/.config/dotfiles/profile")" minimal "the install itself had completed"
if [ "$DF_PROFILE" != minimal ]; then
  # --no-tools: the tools are skipped on purpose, which the doctor must not call a FAIL.
  rc=0
  out="$(HOME="$fx/ih4" DOTFILES_SRC=/src bash /src/install.sh --profile "$DF_PROFILE" --no-tools 2>&1)" || rc=$?
  assert_eq "$rc" 0 "install --no-tools exits 0: $out"
  assert_ok "the doctor says the tools were not checked" -- grep -Eq '^WARN +tools: not checked' <<<"$out"
  assert_eq "$(grep -c '^FAIL' <<<"$out" || true)" 0 "and nothing FAILs"
  # Without --no-tools nothing is installed here, and the doctor does FAIL on the tools.
  assert_eq "$(HOME="$fx/ih4" df_rc /src/bin/dotfiles doctor)" 1 "a later doctor run does miss the tools"
fi
rm -rf "$fx/ih1" "$fx/ih2" "$fx/ih3" "$fx/ih4"

# --- case_update_from_src -----------------------------------------------------------------
# /src is read-only for this user, so the "edited checkout" is a copy of it.
work="$fx/work"
mkdir -p "$work"
cp -a /src/. "$work/"
printf 'probe-1\n' >"$work/config/update-probe"
assert_file_absent "$HOME/.dotfiles/config/update-probe"
DOTFILES_SRC="$work" "$df" update >/dev/null 2>&1 || _fail "dotfiles update with DOTFILES_SRC failed"
assert_eq "$(cat "$HOME/.dotfiles/config/update-probe")" "probe-1" "update copies the edited checkout into ~/.dotfiles"
assert_eq "$("$df" profile)" "$DF_PROFILE" "update keeps the profile"
assert_symlink "$HOME/.bashrc" "$HOME/.dotfiles/shell/bashrc"
printf 'probe-2\n' >"$work/config/update-probe"
DOTFILES_SRC="$work" "$df" update >/dev/null 2>&1 || _fail "second dotfiles update failed"
assert_eq "$(cat "$HOME/.dotfiles/config/update-probe")" "probe-2" "a second update picks up the next change"
assert_fail "a copy of the checkout has no .git" -- test -e "$HOME/.dotfiles/.git"

# isoenv HOME=<throwaway home> <cmd...>: no inherited source or location.
isoenv=(env -u DOTFILES_SRC -u DOTFILES_DIR -u DOTFILES_REPO -u DOTFILES_REF)

# --- case_update_with_nothing_to_go_on ---------------------------------------------------
mkdir -p "$fx/lone/.config/dotfiles"
echo minimal >"$fx/lone/.config/dotfiles/profile"
assert_eq "$(df_rc "${isoenv[@]}" HOME="$fx/lone" /src/bin/dotfiles update)" 1 "update without any source fails"
assert_ok "update says where the code could come from" -- \
  grep -q 'DOTFILES_SRC' <<<"$(df_out "${isoenv[@]}" HOME="$fx/lone" /src/bin/dotfiles update)"
assert_eq "$(df_rc "${isoenv[@]}" HOME="$fx/empty-home" /src/bin/dotfiles update)" 1 "update without an install fails"

# --- case_update_from_git ---------------------------------------------------------------
if [ "$git_ok" = 1 ]; then
  origin="$fx/origin"
  mkdir -p "$origin"
  cp -a /src/. "$origin/"
  rm -rf "$origin/.git"
  g() { git -C "$origin" -c user.name=test -c user.email=test@example.invalid "$@"; }
  g init -q
  g symbolic-ref HEAD refs/heads/main
  g add -A
  g commit -q -m "initial"
  gh="$fx/git-home"
  mkdir -p "$gh"
  "${isoenv[@]}" HOME="$gh" DOTFILES_REPO="file://$origin" DOTFILES_REF=main bash /src/install.sh --profile "$DF_PROFILE" >/dev/null 2>&1 ||
    _fail "install from a git repo failed"
  assert_ok "the install is a git clone" -- test -d "$gh/.dotfiles/.git"
  assert_eq "$(cat "$gh/.config/dotfiles/repo")" "$(printf 'file://%s\nmain' "$origin")" "install records the repo and ref it cloned"
  printf 'git-1\n' >"$origin/config/update-probe"
  g add -A
  g commit -q -m "probe"
  "${isoenv[@]}" HOME="$gh" "$gh/.local/bin/dotfiles" update >/dev/null 2>&1 || _fail "dotfiles update from a git clone failed"
  assert_eq "$(cat "$gh/.dotfiles/config/update-probe")" "git-1" "update pulls the new commit"
  assert_eq "$("$gh/.local/bin/dotfiles" profile)" "$DF_PROFILE" "update from git keeps the profile"
  # A tag-pinned clone is detached: update moves it to where the tag points now.
  g tag -f v1
  tg="$fx/tag-git-home"
  mkdir -p "$tg"
  "${isoenv[@]}" HOME="$tg" DOTFILES_REPO="file://$origin" DOTFILES_REF=v1 bash /src/install.sh --profile "$DF_PROFILE" >/dev/null 2>&1 ||
    _fail "install from a tag failed"
  assert_fail "the tag-pinned clone is on a detached HEAD" -- git -C "$tg/.dotfiles" symbolic-ref -q HEAD
  assert_eq "$(sed -n 2p "$tg/.config/dotfiles/repo")" v1 "install records the tag as the ref"
  printf 'git-tag-2\n' >"$origin/config/update-probe"
  g add -A
  g commit -q -m "after the tag"
  "${isoenv[@]}" HOME="$tg" "$tg/.local/bin/dotfiles" update >/dev/null 2>&1 || _fail "dotfiles update of a tag-pinned clone failed"
  assert_eq "$(cat "$tg/.dotfiles/config/update-probe")" "git-1" "update of a tag-pinned clone stays on the tag while the tag does not move"
  g tag -f v1
  "${isoenv[@]}" HOME="$tg" "$tg/.local/bin/dotfiles" update >/dev/null 2>&1 || _fail "dotfiles update after the tag moved failed"
  assert_eq "$(cat "$tg/.dotfiles/config/update-probe")" "git-tag-2" "update follows the tag when it moves"
  assert_fail "and the clone stays detached" -- git -C "$tg/.dotfiles" symbolic-ref -q HEAD
  # An adopted clone with no record: the branch it is on and the origin it has are enough.
  rm -f "$gh/.config/dotfiles/repo"
  printf 'git-3\n' >"$origin/config/update-probe"
  g add -A
  g commit -q -m "probe 3"
  "${isoenv[@]}" HOME="$gh" "$gh/.local/bin/dotfiles" update >/dev/null 2>&1 || _fail "dotfiles update without a recorded repo failed"
  assert_eq "$(cat "$gh/.dotfiles/config/update-probe")" "git-3" "update without a record follows the branch of the clone"
  # A history that cannot fast-forward is reported, not forced.
  g commit -q --amend -m "rewritten"
  assert_eq "$(df_rc "${isoenv[@]}" HOME="$gh" "$gh/.local/bin/dotfiles" update)" 1 "update refuses a history that is not a fast-forward"
fi

# --- case_update_from_tarball ------------------------------------------------------------
# The repo recorded at install time is downloaded as a tarball. curl reads
# file:// URLs, so a directory tree stands in for GitHub.
srv="$fx/srv"
mkpack() { # <probe content>: rebuild $srv/archive/main.tar.gz from the checkout copy
  rm -rf "$fx/pack"
  mkdir -p "$fx/pack/dotfiles-main" "$srv/archive"
  cp -a /src/. "$fx/pack/dotfiles-main/"
  rm -rf "$fx/pack/dotfiles-main/.git"
  printf '%s\n' "$1" >"$fx/pack/dotfiles-main/config/update-probe"
  tar -czf "$srv/archive/main.tar.gz" -C "$fx/pack" dotfiles-main
}
mkpack tar-1
th="$fx/tar-home"
mkdir -p "$th"
if [ "$git_ok" = 0 ]; then
  # No git here: the installer itself takes the tarball and has to record where from.
  "${isoenv[@]}" HOME="$th" DOTFILES_REPO="file://$srv" DOTFILES_REF=main bash /src/install.sh --profile "$DF_PROFILE" >/dev/null 2>&1 ||
    _fail "install from a tarball failed"
  assert_eq "$(cat "$th/.config/dotfiles/repo")" "$(printf 'file://%s\nmain' "$srv")" "install records the repo and ref it downloaded"
  assert_eq "$(cat "$th/.dotfiles/config/update-probe")" "tar-1" "the tarball install has the probe"
else
  "${isoenv[@]}" HOME="$th" DOTFILES_SRC=/src bash /src/install.sh --profile "$DF_PROFILE" >/dev/null 2>&1 ||
    _fail "install for the tarball update failed"
  assert_file_absent "$th/.config/dotfiles/repo"
  printf 'file://%s\nmain\n' "$srv" >"$th/.config/dotfiles/repo"
fi
mkpack tar-2
# TMPDIR points at a directory that must stay empty: nothing may be written outside $HOME.
mkdir -p "$fx/tmp"
"${isoenv[@]}" HOME="$th" TMPDIR="$fx/tmp" "$th/.local/bin/dotfiles" update >/dev/null 2>&1 || _fail "dotfiles update from a tarball failed"
assert_eq "$(cat "$th/.dotfiles/config/update-probe")" "tar-2" "update downloads the recorded repo"
assert_eq "$(ls -A "$fx/tmp")" "" "update writes nothing outside HOME"
assert_fail "update cleans up its temporary directory under HOME" -- compgen -G "$th/.cache/dotfiles-update.*"
assert_eq "$("$th/.local/bin/dotfiles" profile)" "$DF_PROFILE" "update from a tarball keeps the profile"
# A failed download leaves the install as it was.
rm -f "$srv/archive/main.tar.gz"
assert_eq "$(df_rc "${isoenv[@]}" HOME="$th" TMPDIR="$fx/tmp" "$th/.local/bin/dotfiles" update)" 1 "update fails when the download fails"
assert_eq "$(cat "$th/.dotfiles/config/update-probe")" "tar-2" "a failed update leaves the install alone"
assert_eq "$(ls -A "$fx/tmp")" "" "a failed update writes nothing outside HOME"
assert_fail "a failed update cleans up too" -- compgen -G "$th/.cache/dotfiles-update.*"

# --- case_uninstall ------------------------------------------------------------------------
"${isoenv[@]}" HOME="$th" "$th/.local/bin/dotfiles" uninstall --purge >/dev/null 2>&1 || _fail "dotfiles uninstall --purge failed"
assert_file_absent "$th/.dotfiles"
assert_file_absent "$th/.local/bin/dotfiles"
assert_file_absent "$th/.bashrc"
assert_file_absent "$th/.config/dotfiles"
assert_file_absent "$th/.config/dotfiles/repo"
# Without --purge the checkout stays.
mkdir -p "$fx/un-home"
"${isoenv[@]}" HOME="$fx/un-home" DOTFILES_SRC=/src bash /src/install.sh --profile minimal >/dev/null 2>&1
"${isoenv[@]}" HOME="$fx/un-home" "$fx/un-home/.local/bin/dotfiles" uninstall >/dev/null 2>&1 || _fail "dotfiles uninstall failed"
assert_file_absent "$fx/un-home/.bashrc"
assert_ok "uninstall without --purge keeps the checkout" -- test -f "$fx/un-home/.dotfiles/install.sh"

rm -rf "$fx"
