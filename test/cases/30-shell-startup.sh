# Shell startup: silent and PATH-safe for non-interactive sessions, zsh
# hand-over only for real terminals.
export DOTFILES_NO_TOOLS=1 # tools are covered by 50-server-tools.sh
/src/install.sh --profile "$DF_PROFILE" >/dev/null 2>&1

# case_noninteractive_silent_and_path_last
assert_eq "$(bash -c 'echo ok')" "ok" "bash -c silent"
assert_eq "$(bash -lc 'echo ok')" "ok" "bash -lc silent"
assert_eq "$(sh -c '. ~/.profile; echo ok')" "ok" "sh sourcing ~/.profile silent"
# `ssh host cmd` sources ~/.bashrc non-interactively; plain `bash -c` sources nothing, so simulate ssh
assert_eq "$(bash -c '. ~/.bashrc; echo ok')" "ok" "ssh-like bashrc silent"
p=$(bash -c '. ~/.bashrc; echo "$PATH"'); assert_ok "local/bin after /usr/bin (ssh-like)" -- \
  bash -c "[[ \"$p\" == */usr/bin*$HOME/.local/bin* ]]"
p=$(bash -lc 'echo "$PATH"'); assert_ok "local/bin after /usr/bin (login)" -- \
  bash -c "[[ \"$p\" == */usr/bin*$HOME/.local/bin* ]]"
assert_eq "$(bash -c '. ~/.bashrc; echo "$PATH"')" \
          "$(bash -c '. ~/.bashrc; . ~/.bashrc; echo "$PATH"')" "no PATH dup"
assert_eq "$(bash -c '. ~/.bashrc; echo "$PATH"')" \
          "$(bash -c '. ~/.profile; . ~/.bashrc; echo "$PATH"')" "no PATH dup across profile and bashrc"
assert_eq "$(bash -c '. ~/.bashrc; echo "${DOTFILES_IN_ZSH:-unset}"')" "unset" "non-interactive never switches"

# case_env_sh_details: run against a throwaway HOME so the real one is untouched
fx="$(mktemp -d)"
mkdir -p "$fx/.config/dotfiles"
run_env() { env -i HOME="$fx" PATH=/usr/bin:/bin DOTFILES_DIR=/src "$@"; }
assert_eq "$(run_env sh -c '. /src/shell/env.sh; echo "${MISE_ENV:-unset}"')" "unset" "MISE_ENV unset without profile"
echo server >"$fx/.config/dotfiles/profile"
assert_eq "$(run_env sh -c '. /src/shell/env.sh; echo "${MISE_ENV:-unset}"')" "unset" "MISE_ENV unset for server"
echo workstation >"$fx/.config/dotfiles/profile"
assert_eq "$(run_env sh -c '. /src/shell/env.sh; echo "$MISE_ENV"')" "workstation" "MISE_ENV for workstation"
echo 'export DF_LOCAL_PROBE=yes' >"$fx/.config/dotfiles/env.local"
assert_eq "$(run_env sh -c '. /src/shell/env.sh; echo "$DF_LOCAL_PROBE"')" "yes" "env.local is sourced"
assert_eq "$(run_env sh -c '. /src/shell/env.sh; echo "$DOTFILES_DIR"')" "/src" "DOTFILES_DIR exported"
assert_eq "$(run_env sh -ic '. /src/shell/env.sh; echo "$PATH"' 2>/dev/null)" \
          "$fx/.local/share/mise/shims:$fx/.local/bin:/usr/bin:/bin" "interactive puts our dirs first"
rm -rf "$fx"

# case_no_tty_stays_bash
assert_eq "$(bash -i -c 'echo $0' </dev/null 2>/dev/null)" "bash" "no tty → bash"
# case_tty_switches_to_zsh (only rows with zsh); feed an interactive bash through a pty
tty_probe() { printf 'echo Z${DOTFILES_IN_ZSH:-0}\nexit\n' | timeout 30 script -qec 'bash -i' /dev/null | tr -d '\r' | grep -o 'Z[01]' | tail -1; }
if command -v zsh >/dev/null; then
  assert_eq "$(tty_probe)" "Z1" "tty → zsh"
  touch ~/.no-zsh; assert_eq "$(tty_probe)" "Z0" "~/.no-zsh keeps bash"; rm ~/.no-zsh
  assert_eq "$(zsh -c 'echo ok')" "ok" "zsh -c silent"
  assert_eq "$(zsh -lc 'echo ok')" "ok" "zsh -lc silent"
  p=$(zsh -c 'echo "$PATH"'); assert_ok "local/bin after /usr/bin (zsh -c)" -- \
    bash -c "[[ \"$p\" == */usr/bin*$HOME/.local/bin* ]]"
  assert_eq "$(DOTFILES_IN_ZSH=1 timeout 30 script -qec 'bash -i -c "echo \$0"' /dev/null | tr -d '\r' | grep -o '^bash$')" "bash" "bash inside zsh stays bash"
else
  assert_eq "$DF_ROW" "u20-nozsh" "only the no-zsh row lacks zsh"
  assert_eq "$(tty_probe)" "Z0" "no zsh installed → stays bash"
fi
# case_tty_with_command_stays_bash: `bash -i -c cmd` on a tty must run cmd, not exec zsh
assert_eq "$(timeout 30 script -qec 'bash -i -c "echo C"' /dev/null | tr -d '\r' | grep -o '^C$')" "C" "-c on tty runs command"

# --- robustness round -------------------------------------------------------
# kind_probe <script cmd>: feed one command to an interactive bash on a pty and
# report which shell answered ("zsh" or "bash"). The echoed input line never
# matches the pattern, only the command's output does.
kind_probe() {
  printf 'echo W${ZSH_VERSION:+Z}B\nexit\n' | timeout 30 script -qec "${1:-bash -i}" /dev/null |
    tr -d '\r' | grep -o 'WZ\?B' | tail -1 | sed 's/^WZB$/zsh/; s/^WB$/bash/'
}

# case_path_front_for_inherited_back_entry: VS Code Remote, ssh host tmux, ...
inherited="/usr/bin:/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims"
# The mise shims are put on PATH only by the profiles that install tools; on
# minimal the inherited entry stays where it was.
sp="$HOME/.local/share/mise/shims:"
want="${sp}$HOME/.local/bin:/usr/bin:/bin"
if [ "$DF_PROFILE" = minimal ]; then
  sp=""
  want="$HOME/.local/bin:/usr/bin:/bin:$HOME/.local/share/mise/shims"
fi
assert_eq "$(PATH="$inherited" bash -ic 'echo "$PATH"' 2>/dev/null)" "$want" "interactive bash moves inherited back entries to the front"
assert_eq "$(PATH="/usr/bin:$HOME/.local/bin2:$HOME/.local/bin:/bin" bash -ic 'echo "$PATH"' 2>/dev/null)" \
          "${sp}$HOME/.local/bin:/usr/bin:$HOME/.local/bin2:/bin" "front move keeps look-alike entries and leaves no duplicate"
assert_eq "$(PATH="$HOME/.local/bin" /bin/bash -ic 'echo "$PATH"' 2>/dev/null)" \
          "${sp}$HOME/.local/bin" "front move works when ours is the whole PATH"
assert_eq "$(PATH="$inherited" bash -c '. ~/.bashrc; echo "$PATH"')" "$inherited" "non-interactive leaves an inherited PATH alone"
if command -v zsh >/dev/null; then
  assert_eq "$(PATH="$inherited" zsh -ic 'echo "$PATH"' 2>/dev/null)" "$want" "interactive zsh moves inherited back entries to the front"
fi

# case_guards_that_must_fail_without_their_condition
if command -v zsh >/dev/null; then
  assert_eq "$(kind_probe)" "zsh" "probe sees zsh on a real tty"
  # no tty: piped stdin without -c must stay bash (only the -t check prevents exec here)
  assert_eq "$(printf 'echo W${ZSH_VERSION:+Z}B\nexit\n' | bash -i 2>/dev/null | grep -o 'WZ\?B' | tail -1)" "WB" "piped stdin stays bash"
  # stdin not a tty but stdout is (only the -t 0 check prevents exec here)
  cmds="$(mktemp)"
  printf 'echo W${ZSH_VERSION:+Z}B\nexit\n' >"$cmds"
  assert_eq "$(timeout 30 script -qec "bash -i <$cmds" /dev/null </dev/null | tr -d '\r' | grep -o 'WZ\?B' | tail -1)" "WB" "stdin from a file stays bash"
  rm -f "$cmds"
  # stdout not a tty
  out="$(mktemp)"
  printf 'echo W${ZSH_VERSION:+Z}B\nexit\n' | timeout 30 script -qec "bash -i >$out" /dev/null >/dev/null
  assert_eq "$(grep -o 'WZ\?B' "$out" | tail -1)" "WB" "stdout redirected to a file stays bash"
  rm -f "$out"
  # already switched once
  assert_eq "$(DOTFILES_IN_ZSH=1 kind_probe)" "bash" "DOTFILES_IN_ZSH keeps bash"
  # bash -i script.sh on a tty runs the script instead of dropping it
  printf 'echo SCRIPTRAN\n' >"$HOME/s.sh"
  assert_eq "$(timeout 30 script -qec "bash -i $HOME/s.sh" /dev/null </dev/null | tr -d '\r' | grep -o 'SCRIPTRAN')" "SCRIPTRAN" "bash -i script on tty runs the script"
  rm -f "$HOME/s.sh"
  # a login bash becomes a login zsh, a plain one a non-login zsh
  login_probe() { printf '[[ -o login ]] && echo LOGIN${ZSH_VERSION:+Z}\nexit\n' | timeout 30 script -qec "$1" /dev/null | tr -d '\r' | grep -o 'LOGINZ' | tail -1; }
  assert_eq "$(login_probe 'bash -il')" "LOGINZ" "login bash execs a login zsh"
  assert_eq "$(login_probe 'bash -i')" "" "non-login bash execs a non-login zsh"
  # screen/tmux must start zsh: SHELL has to name a zsh after the switch
  shell_probe() { printf 'echo S:$SHELL:E\nexit\n' | timeout 30 script -qec 'bash -i' /dev/null | tr -d '\r' | grep -o 'S:[^:]*:E' | tail -1; }
  case "$(shell_probe)" in
    S:*/zsh:E) ;;
    *) _fail "SHELL does not point at zsh after the switch: $(shell_probe)" ;;
  esac
fi

# case_etc_bashrc: sourced once per shell, silenced, in every bash mode (the
# RHEL skeleton ~/.bashrc did the same), and before env.sh so that our PATH
# entries stay last.
fx="$(mktemp -d)"
printf 'echo x >>"%s/etc-count"\necho noise; echo noise >&2\nPATH=/opt/system-first:$PATH\n' "$fx" >"$fx/etc-bashrc"
printf '. ~/.bashrc\n. ~/.bashrc\nexit\n' | DF_ETC_BASHRC="$fx/etc-bashrc" bash -i >/dev/null 2>&1
assert_eq "$(wc -l <"$fx/etc-count" | tr -d ' ')" "1" "/etc/bashrc sourced once per interactive shell"
assert_eq "$(DF_ETC_BASHRC="$fx/etc-bashrc" bash -c '. ~/.bashrc; echo ok' 2>&1)" "ok" "/etc/bashrc is silent non-interactively"
assert_eq "$(wc -l <"$fx/etc-count" | tr -d ' ')" "2" "/etc/bashrc sourced by a non-interactive bash too"
assert_eq "$(DF_ETC_BASHRC="$fx/etc-bashrc" bash -c '. ~/.bashrc; . ~/.bashrc; echo ok' 2>&1)" "ok" "silent when sourced twice"
assert_eq "$(wc -l <"$fx/etc-count" | tr -d ' ')" "3" "/etc/bashrc sourced once per shell, not once per ~/.bashrc"
p="$(DF_ETC_BASHRC="$fx/etc-bashrc" bash -c '. ~/.bashrc; echo "$PATH"')"
case "$p" in
  /opt/system-first:*:"$HOME/.local/bin" | /opt/system-first:*:"$HOME/.local/bin":*) ;;
  *) _fail "system PATH first, ours last after /etc/bashrc: $p" ;;
esac
assert_eq "$(DF_ETC_BASHRC="$fx/missing" bash -c '. ~/.bashrc; echo ok' 2>&1)" "ok" "a missing /etc/bashrc is no error"
rm -rf "$fx"
# A variable exported from /etc/profile.d reaches `ssh host cmd` (the image has
# /etc/profile.d/zz-dotfiles-test.sh). Hosts without /etc/bashrc (Debian family)
# do not get it, which is how their stock setup behaves too.
if [ -r /etc/bashrc ]; then
  assert_eq "$(bash -c '. ~/.bashrc; echo "${DF_TEST_PROFILED:-unset}"' 2>&1)" "from-profile-d" "ssh-like bash gets /etc/profile.d (RHEL family)"
  assert_eq "$(env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c '. ~/.bashrc; echo "${DF_TEST_PROFILED:-unset}"' 2>&1)" "from-profile-d" "also from a bare environment"
  assert_eq "$(bash -c '. ~/.bashrc; echo ok' 2>&1)" "ok" "and stays byte-silent"
  assert_eq "$(bash -lc 'echo "${DF_TEST_PROFILED:-unset}"' 2>&1)" "from-profile-d" "login shells get it from /etc/profile"
else
  assert_eq "$(bash -c '. ~/.bashrc; echo "${DF_TEST_PROFILED:-unset}"' 2>&1)" "unset" "no /etc/bashrc, no profile.d in ssh-like bash"
fi
[ "$DF_ROW" != r9 ] || assert_ok "the Rocky row has /etc/bashrc, so the check above ran" -- test -r /etc/bashrc

# case_bashrc_d_and_completion: interactive non-login bash loads ~/.bashrc.d/*.sh
# and bash completion (what the skeleton ~/.bashrc used to do), not twice and
# not in a non-interactive shell.
fx="$(mktemp -d)"
mkdir -p "$HOME/.bashrc.d"
printf 'DF_RCD_PROBE=yes\n' >"$HOME/.bashrc.d/probe.sh"
printf 'DF_RCD_IGNORED=yes\n' >"$HOME/.bashrc.d/ignored.txt"
printf 'BASH_COMPLETION_VERSINFO=(2 11)\necho x >>"%s/comp-count"\n' "$fx" >"$fx/bash_completion"
interactive_probe() { printf '%s\nexit\n' "$1" | env "${@:2}" bash -i 2>/dev/null; }
assert_eq "$(interactive_probe 'echo "${DF_RCD_PROBE:-unset}:${DF_RCD_IGNORED:-unset}"')" "yes:unset" "files of .bashrc.d ending in .sh are sourced, others are not"
assert_eq "$(bash -c '. ~/.bashrc; echo "${DF_RCD_PROBE:-unset}"' 2>&1)" "unset" "not in a non-interactive shell"
assert_eq "$(interactive_probe 'echo "${BASH_COMPLETION_VERSINFO:-unset}"' DF_BASH_COMPLETION="$fx/bash_completion" | tr -d ' ')" "2" "bash completion is loaded by an interactive non-login bash"
printf '. ~/.bashrc\nexit\n' | DF_BASH_COMPLETION="$fx/bash_completion" bash -i >/dev/null 2>&1
assert_eq "$(wc -l <"$fx/comp-count" | tr -d ' ')" "2" "an already loaded completion is not sourced again"
: >"$fx/comp-count"
printf 'exit\n' | DF_BASH_COMPLETION="$fx/bash_completion" bash -il >/dev/null 2>&1
assert_eq "$(wc -l <"$fx/comp-count" | tr -d ' ')" "0" "a login shell leaves it to /etc/profile.d"
assert_eq "$(DF_BASH_COMPLETION="$fx/bash_completion" bash -c '. ~/.bashrc; echo ok' 2>&1)" "ok" "silent non-interactively"
assert_eq "$(wc -l <"$fx/comp-count" | tr -d ' ')" "0" "completion is not loaded non-interactively"
rm -rf "$HOME/.bashrc.d" "$fx"

# case_home_bin_on_path: ~/bin joins PATH like ~/.local/bin, only when it exists
fx="$(mktemp -d)"
mkdir -p "$fx/.config/dotfiles" "$fx/bin" "$fx/.local/bin"
run_env_in() { env -i HOME="$fx" PATH=/usr/bin:/bin DOTFILES_DIR=/src "$@"; }
assert_eq "$(run_env_in sh -c '. /src/shell/env.sh; echo "$PATH"')" "/usr/bin:/bin:$fx/bin:$fx/.local/bin" "a home bin directory is appended for non-interactive shells"
assert_eq "$(run_env_in sh -ic '. /src/shell/env.sh; echo "$PATH"' 2>/dev/null)" "$fx/.local/bin:$fx/bin:/usr/bin:/bin" "and goes to the front, behind ~/.local/bin, for interactive ones"
assert_eq "$(run_env_in sh -c '. /src/shell/env.sh; . /src/shell/env.sh; echo "$PATH"')" "/usr/bin:/bin:$fx/bin:$fx/.local/bin" "no duplicate on a second source"
rmdir "$fx/bin"
assert_eq "$(run_env_in sh -c '. /src/shell/env.sh; echo "$PATH"')" "/usr/bin:/bin:$fx/.local/bin" "a missing ~/bin is not added"
if command -v zsh >/dev/null; then
  mkdir "$fx/bin"
  assert_eq "$(run_env_in zsh -c '. /src/shell/env.sh; echo "$PATH"')" "/usr/bin:/bin:$fx/bin:$fx/.local/bin" "zsh gets ~/bin the same way"
fi
rm -rf "$fx"

# case_non_default_dotfiles_dir: the recorded location, not ~/.dotfiles, is used
fx="$(mktemp -d)"
alt="$fx/alt-dots"
HOME="$fx" DOTFILES_DIR="$alt" /src/install.sh --profile "$DF_PROFILE" >/dev/null 2>&1
assert_eq "$(cat "$fx/.config/dotfiles/dir")" "$alt" "installer records the location"
assert_eq "$(env -i HOME="$fx" PATH=/usr/bin:/bin bash -lc 'echo "$DOTFILES_DIR"')" "$alt" "bash -l finds a non-default DOTFILES_DIR"
assert_eq "$(env -i HOME="$fx" PATH=/usr/bin:/bin sh -c '. "$HOME/.profile"; echo "$DOTFILES_DIR"')" "$alt" "~/.profile finds a non-default DOTFILES_DIR"
assert_ok "PATH gets ~/.local/bin from the non-default checkout" -- \
  bash -c "[[ \"\$(env -i HOME=$fx PATH=/usr/bin:/bin bash -c '. ~/.bashrc; echo \$PATH')\" == */usr/bin*$fx/.local/bin* ]]"
if command -v zsh >/dev/null; then
  assert_eq "$(env -i HOME="$fx" PATH=/usr/bin:/bin zsh -c 'echo "$DOTFILES_DIR"')" "$alt" "zsh finds a non-default DOTFILES_DIR"
fi
# an explicit environment value still wins over the record
assert_eq "$(env -i HOME="$fx" PATH=/usr/bin:/bin DOTFILES_DIR=/src bash -lc 'echo "$DOTFILES_DIR"')" "/src" "environment DOTFILES_DIR wins"
HOME="$fx" bash "$alt/uninstall.sh" >/dev/null 2>&1
assert_file_absent "$fx/.config/dotfiles/dir"
rm -rf "$fx"
