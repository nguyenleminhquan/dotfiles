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

# case_etc_bashrc_sourced_once_when_interactive
fx="$(mktemp -d)"
printf 'echo x >>"%s/etc-count"\n' "$fx" >"$fx/etc-bashrc"
printf '. ~/.bashrc\n. ~/.bashrc\nexit\n' | DF_ETC_BASHRC="$fx/etc-bashrc" bash -i >/dev/null 2>&1
assert_eq "$(wc -l <"$fx/etc-count" | tr -d ' ')" "1" "/etc/bashrc sourced once per interactive shell"
DF_ETC_BASHRC="$fx/etc-bashrc" bash -c '. ~/.bashrc'
assert_eq "$(wc -l <"$fx/etc-count" | tr -d ' ')" "1" "/etc/bashrc not sourced non-interactively"
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
