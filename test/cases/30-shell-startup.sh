# Shell startup: silent and PATH-safe for non-interactive sessions, zsh
# hand-over only for real terminals.
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
tty_probe() { printf 'echo Z${DOTFILES_IN_ZSH:-0}\nexit\n' | script -qec 'bash -i' /dev/null | tr -d '\r' | grep -o 'Z[01]' | tail -1; }
if command -v zsh >/dev/null; then
  assert_eq "$(tty_probe)" "Z1" "tty → zsh"
  touch ~/.no-zsh; assert_eq "$(tty_probe)" "Z0" "~/.no-zsh keeps bash"; rm ~/.no-zsh
  assert_eq "$(zsh -c 'echo ok')" "ok" "zsh -c silent"
  assert_eq "$(zsh -lc 'echo ok')" "ok" "zsh -lc silent"
  p=$(zsh -c 'echo "$PATH"'); assert_ok "local/bin after /usr/bin (zsh -c)" -- \
    bash -c "[[ \"$p\" == */usr/bin*$HOME/.local/bin* ]]"
  assert_eq "$(DOTFILES_IN_ZSH=1 script -qec 'bash -i -c "echo \$0"' /dev/null | tr -d '\r' | grep -o '^bash$')" "bash" "bash inside zsh stays bash"
else
  assert_eq "$DF_ROW" "u20-nozsh" "only the no-zsh row lacks zsh"
  assert_eq "$(tty_probe)" "Z0" "no zsh installed → stays bash"
fi
# case_tty_with_command_stays_bash: `bash -i -c cmd` on a tty must run cmd, not exec zsh
assert_eq "$(script -qec 'bash -i -c "echo C"' /dev/null | tr -d '\r' | grep -o '^C$')" "C" "-c on tty runs command"
