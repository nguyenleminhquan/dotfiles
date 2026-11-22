# Profile workstation and the WSL tweaks (shell/wsl.sh).
# The tweaks are pure shell, so they are checked on every row, offline. The
# install of the workstation tools (python, opencode, opentofu, terragrunt: a
# few hundred MB) runs on the u20-ws row only, which also pretends to be WSL1.
# SC2016: the snippets are meant to be expanded by the shell under test.
# SC2030/SC2031: HOME and PATH are changed in subshells on purpose.
# shellcheck disable=SC2016,SC2030,SC2031

fx="$(mktemp -d)"
mkdir -p "$fx/home/.config/dotfiles"

# --- case_filter_path: Windows directories on PATH are an allowlist -------------------
(
  # wsl.sh may write its locale cache: not into the real HOME.
  export HOME="$fx/home" DF_WSL_MNT_PREFIX="$fx/mnt/"
  # shellcheck source=/dev/null
  . /src/shell/wsl.sh
  m="$fx/mnt"
  mkdir -p "$m/c/VS Code/bin" "$m/c/Tools" "$m/c/WINDOWS" "$m/c/other"
  touch "$m/c/VS Code/bin/code" "$m/c/WINDOWS/explorer.exe"
  in="/usr/bin:$m/c/Tools:$m/c/VS Code/bin:/usr/local/bin:$m/c/WINDOWS"
  assert_eq "$(df_wsl_filter_path "$in")" "/usr/bin:$m/c/VS Code/bin:/usr/local/bin:$m/c/WINDOWS" \
    "keep allowlisted mnt dirs only"

  # Each allowlisted file keeps its directory, nothing else does.
  for f in code explorer.exe clip.exe powershell.exe wsl.exe docker; do
    mkdir -p "$m/keep-$f"
    touch "$m/keep-$f/$f"
    assert_eq "$(df_wsl_filter_path "$m/keep-$f")" "$m/keep-$f" "$f keeps its directory"
  done
  touch "$m/c/other/notepad.exe" "$m/c/other/code.exe" "$m/c/other/docker-compose"
  assert_eq "$(df_wsl_filter_path "$m/c/other")" "" "look-alike files do not keep a directory"
  assert_eq "$(df_wsl_filter_path "$m/c/missing")" "" "a missing directory is dropped"

  # Order, empty entries and non-mnt entries are untouched.
  assert_eq "$(df_wsl_filter_path "/b:/a:$m/c/Tools:/c")" "/b:/a:/c" "order of the other entries is kept"
  assert_eq "$(df_wsl_filter_path "/a::/b:")" "/a::/b:" "empty entries stay"
  assert_eq "$(df_wsl_filter_path "$fx/mntx/bin:/a")" "$fx/mntx/bin:/a" "only the exact prefix counts"
  assert_eq "$(df_wsl_filter_path "")" "" "empty PATH stays empty"
  assert_eq "$(df_wsl_filter_path "/only/one")" "/only/one" "single entry"
  once="$(df_wsl_filter_path "$in")"
  assert_eq "$(df_wsl_filter_path "$once")" "$once" "filtering twice changes nothing"
)

# --- case_default_prefix: /mnt/ unless the test override is set ------------------------
assert_eq "$(unset DF_WSL_MNT_PREFIX; HOME="$fx/home"; . /src/shell/wsl.sh; df_wsl_filter_path "/usr/bin:/mnt/c/definitely/missing:/bin")" \
  "/usr/bin:/bin" "the default prefix is /mnt/"

# --- case_wsl_sh_effects: PATH, umask and locale, in a clean environment ---------------
# A fake `locale` stands in for the real one and counts its calls.
bin="$fx/bin"
mkdir -p "$bin" "$fx/mnt/c/Tools" "$fx/mnt/c/WINDOWS" "$fx/locale-dir"
touch "$fx/mnt/c/WINDOWS/explorer.exe"
fake_locale() { # <list printed by locale -a>
  printf '#!/bin/sh\necho x >>"%s/locale-calls"\nprintf "%%s\\n" %s\n' "$fx" "$1" >"$bin/locale"
  chmod +x "$bin/locale"
}
calls() { if [ -f "$fx/locale-calls" ]; then wc -l <"$fx/locale-calls" | tr -d ' '; else echo 0; fi; }
clean() { # <sh code>: run it with wsl.sh sourced, in an environment that is ours
  env -i HOME="$fx/home" PATH="$bin:/usr/bin:/bin:$fx/mnt/c/Tools:$fx/mnt/c/WINDOWS" \
    DF_WSL_MNT_PREFIX="$fx/mnt/" DF_WSL_LOCALE_DIR="$fx/locale-dir" "$@"
}
fake_locale "C C.utf8 en_US.utf8 POSIX"
out="$(clean sh -c '. /src/shell/wsl.sh; echo "$PATH"' 2>&1)"
assert_eq "$out" "$bin:/usr/bin:/bin:$fx/mnt/c/WINDOWS" "wsl.sh filters PATH and prints nothing else"
assert_eq "$(clean sh -c 'umask 0000; . /src/shell/wsl.sh; umask')" "0022" "umask 0000 becomes 022"
assert_eq "$(clean sh -c 'umask 077; . /src/shell/wsl.sh; umask')" "0077" "a deliberate umask stays"
assert_eq "$(clean sh -c 'umask 002; . /src/shell/wsl.sh; umask')" "0002" "umask 002 stays"
assert_eq "$(clean sh -c '. /src/shell/wsl.sh; echo "$LANG $LC_ALL"')" "en_US.UTF-8 en_US.UTF-8" "en_US.UTF-8 when the host has it"
assert_eq "$(clean sh -c '. /src/shell/wsl.sh; sh -c "echo \$LANG \$LC_ALL"')" "en_US.UTF-8 en_US.UTF-8" "LANG and LC_ALL are exported"

# Locale: the fallback, the cache and its invalidation.
rm -rf "$fx/home/.cache" "$fx/locale-calls"
fake_locale "C C.utf8 POSIX"
assert_eq "$(clean sh -c '. /src/shell/wsl.sh; echo "$LANG $LC_ALL"')" "C.UTF-8 C.UTF-8" "C.UTF-8 when there is no en_US.utf8"
assert_eq "$(calls)" 1 "first shell asks locale once"
clean sh -c '. /src/shell/wsl.sh'
clean zsh -c '. /src/shell/wsl.sh' 2>/dev/null || true
clean bash -c '. /src/shell/wsl.sh'
assert_eq "$(calls)" 1 "later shells use the cache, whatever the shell"
fake_locale "C C.utf8 en_US.utf8 POSIX"
sleep 1
touch "$fx/locale-dir"
assert_eq "$(clean sh -c '. /src/shell/wsl.sh; echo "$LC_ALL"')" "en_US.UTF-8" "a new locale invalidates the cache"
assert_eq "$(calls)" 2 "and locale is asked again"
assert_eq "$(clean sh -c '. /src/shell/wsl.sh; echo "$LC_ALL"')" "en_US.UTF-8" "the new answer is cached"
assert_eq "$(calls)" 2 "without asking again"
# An inherited UTF-8 locale needs no work at all (children of a session).
rm -rf "$fx/home/.cache" "$fx/locale-calls"
assert_eq "$(clean env LC_ALL=C.UTF-8 sh -c '. /src/shell/wsl.sh; echo "$LC_ALL"')" "C.UTF-8" "an inherited locale is kept"
assert_eq "$(calls)" 0 "and costs no locale call"
# Unwritable cache directory: still works, still silent.
rm -rf "$fx/home/.cache"
mkdir -p "$fx/ro-home"
chmod 500 "$fx/ro-home"
assert_eq "$(env -i HOME="$fx/ro-home" PATH="$bin:/usr/bin:/bin" DF_WSL_LOCALE_DIR="$fx/locale-dir" \
  sh -c '. /src/shell/wsl.sh; echo "$LC_ALL"' 2>&1)" "en_US.UTF-8" "an unwritable HOME does not break or print"
chmod 700 "$fx/ro-home"
# No locale, mkdir or mv on PATH at all: the fallback, and still silent.
rm -rf "$fx/home/.cache"
assert_eq "$(env -i HOME="$fx/home" PATH=/nonexistent DF_WSL_LOCALE_DIR="$fx/locale-dir" \
  /bin/sh -c '. /src/shell/wsl.sh; echo "$LC_ALL"' 2>&1)" "C.UTF-8" "without a locale command: C.UTF-8 and silent"
rm -rf "$fx/home/.cache"
# Sourced twice: same result.
assert_eq "$(clean sh -c '. /src/shell/wsl.sh; . /src/shell/wsl.sh; echo "$PATH|$LC_ALL|$(umask)"')" \
  "$bin:/usr/bin:/bin:$fx/mnt/c/WINDOWS|en_US.UTF-8|0022" "sourcing twice is harmless"
# No network tool is ever needed.
assert_fail "wsl.sh never touches the network" -- grep -Eq 'curl|wget|\bnc\b|/dev/tcp' /src/shell/wsl.sh

# --- case_env_sh_loads_wsl_sh: only under WSL ------------------------------------------
printf 'Linux version 4.4.0-19041-Microsoft #1237-Microsoft Sat Sep 11 14:32:00 PST 2021\n' >"$fx/proc-wsl1"
printf 'Linux version 5.15.153.1-microsoft-standard-WSL2\n' >"$fx/proc-wsl2"
printf 'Linux version 5.15.0-91-generic (buildd@lcy02) #101-Ubuntu SMP\n' >"$fx/proc-native"
env_path() { # <proc version file> <shell>
  env -i HOME="$fx/home" PATH="$bin:/usr/bin:/bin:$fx/mnt/c/Tools:$fx/mnt/c/WINDOWS" DOTFILES_DIR=/src \
    DF_PROC_VERSION_FILE="$1" DF_WSL_MNT_PREFIX="$fx/mnt/" DF_WSL_LOCALE_DIR="$fx/locale-dir" \
    "$2" -c '. /src/shell/env.sh; echo "$PATH ${LC_ALL:-unset}"' 2>&1
}
hb="$fx/home/.local/bin"
for proc in proc-wsl1 proc-wsl2; do
  assert_eq "$(env_path "$fx/$proc" sh)" "$bin:/usr/bin:/bin:$fx/mnt/c/WINDOWS:$hb en_US.UTF-8" "$proc: env.sh applies the WSL tweaks"
done
assert_eq "$(env_path "$fx/proc-native" sh)" "$bin:/usr/bin:/bin:$fx/mnt/c/Tools:$fx/mnt/c/WINDOWS:$hb unset" "native Linux: env.sh leaves PATH and locale alone"
assert_eq "$(env_path "$fx/no-such-file" sh)" "$bin:/usr/bin:/bin:$fx/mnt/c/Tools:$fx/mnt/c/WINDOWS:$hb unset" "no /proc/version: not WSL"
if command -v zsh >/dev/null 2>&1; then
  assert_eq "$(env_path "$fx/proc-wsl1" zsh)" "$bin:/usr/bin:/bin:$fx/mnt/c/WINDOWS:$hb en_US.UTF-8" "zsh gets the same tweaks"
fi

rm -rf "$fx"

# --- the install: the u20-ws row only ----------------------------------------------------
[ "$DF_ROW" = u20-ws ] || return 0
[ "$DF_PROFILE" = workstation ] || _fail "the u20-ws row runs the workstation profile"
assert_eq "${DF_PROC_VERSION_FILE:-unset}" "/src/test/fixtures/proc-version-wsl1" "the row pretends to be WSL1"

cfg=/src/config/mise/config.workstation.toml
# The pins are exact (a moving tool would make two installs differ), the way
# the server config does it, and the checks below are about that file.
for line in '^opentofu = "[0-9][0-9.]*"$' '^terragrunt = "1\.0\.1"$' '^python = "3\.12\.16"$' \
            '^"github:anomalyco/opencode" = \{ version = "1\.14\.33", asset_pattern = "[^"]*linux-x64\.tar\.gz" \}$' \
            '^_\.python\.venv = \{ path = "\{\{env\.HOME\}\}/python-env/ansible2\.16", create = true \}$'; do
  assert_ok "config has: $line" -- grep -Eq "$line" "$cfg"
done
assert_ok "an [env] section holds the venv" -- grep -q '^\[env\]$' "$cfg"
for t in werf cmctl dive hyperfine dua; do
  assert_ok "$t is listed as a comment" -- grep -Eq "^# +.*$t" "$cfg"
  assert_fail "$t is not installed" -- grep -Eq "^\"?[a-z:/-]*$t\"? *=" "$cfg"
done

# The server tools are covered by 50-server-tools.sh, so this install uses a
# copy of the repo whose server config lists two small tools; the workstation
# config is the real one.
src="$(mktemp -d)"
cp -a /src/. "$src/"
cat >"$src/config/mise/config.toml" <<'TOML'
[settings]
download_cache = false

[tools]
"github:starship/starship" = { version = "1.27.0", asset_pattern = "*x86_64-unknown-linux-musl.tar.gz" }
"aqua:junegunn/fzf" = "0.75.0"
TOML
# The install ends with the doctor, which looks for the commands of every tool
# the profile lists: the copy lists two server tools, so it expects two.
printf 'starship github:starship/starship\nfzf aqua:junegunn/fzf\n' >"$src/config/mise/commands.server"
tree_of() {
  (
    cd "$HOME" || exit 1
    find . -mindepth 1 ! -path './.dotfiles-backup' ! -path './.dotfiles-backup/*' \
      ! -name '*_history' ! -name '.lesshst' ! -name '.viminfo' | LC_ALL=C sort
  )
}
tree_before="$(tree_of)"
log="$(mktemp)"
t0=$(date +%s)
DOTFILES_SRC="$src" bash "$src/install.sh" --profile workstation >"$log" 2>&1 || { cat "$log" >&2; _fail "install.sh --profile workstation failed"; }
printf 'workstation install took %ss\n' "$(( $(date +%s) - t0 ))" >&2

assert_eq "$(cat "$HOME/.config/dotfiles/profile")" workstation "profile is recorded"
assert_symlink "$HOME/.config/mise/config.workstation.toml" "$HOME/.dotfiles/config/mise/config.workstation.toml"
assert_symlink "$HOME/.config/mise/conf.d/dotfiles.toml" "$HOME/.dotfiles/config/mise/config.toml"
assert_file_absent "$HOME/.config/mise/config.toml"
assert_eq "$(bash -lc 'echo "$MISE_ENV"')" workstation "login shells select the workstation mise environment"
ls_out="$(cd "$HOME" && bash -lc 'mise ls --current' 2>&1)"
echo "$ls_out" >&2
for tool in opentofu terragrunt opencode python; do
  assert_ok "mise ls --current lists $tool" -- grep -q "$tool" <<<"$ls_out"
done
assert_ok "mise ls --current shows the pinned python" -- grep -Eq 'python +3\.12\.16' <<<"$ls_out"
assert_ok "mise ls --current shows the pinned opentofu" -- grep -Eq 'opentofu +[0-9]+\.[0-9]+\.[0-9]+' <<<"$ls_out"

# The commands the doctor looks for, found by a login shell.
while read -r cmd _; do
  assert_ok "$cmd is found by a login shell" -- bash -lc "command -v $cmd"
done < <(awk '{ sub(/#.*/, "") } NF' /src/config/mise/commands.workstation)

assert_ok "tofu runs" -- bash -lc 'tofu version'
assert_ok "terragrunt runs" -- bash -lc 'terragrunt --version'
assert_eq "$(bash -lc 'opencode --version' 2>&1)" "1.14.33" "opencode runs and is the pinned version"
assert_ok "python3 runs through the shim in a non-interactive login shell" -- grep -q 'Python 3.12.16' <<<"$(bash -lc 'python3 --version' 2>&1)"

# Interactive login sessions: python3 comes from the venv of the mise python 3.12.16.
pty() { timeout 120 script -qec "$1" /dev/null </dev/null | tr -d '\r'; }
zsh_bin="$(command -v zsh)"
assert_ok "zsh -lic: python3 is 3.12.16" -- grep -q 'Python 3.12.16' <<<"$(pty "TERM=xterm-256color $zsh_bin -lic 'python3 --version'")"
assert_ok "bash -lic: python3 is 3.12.16" -- grep -q 'Python 3.12.16' <<<"$(pty "DOTFILES_IN_ZSH=1 TERM=xterm-256color bash -lic 'python3 --version'")"
assert_eq "$(pty "TERM=xterm-256color $zsh_bin -lic 'print -r -- \${commands[python3]}'" | tail -n 1)" \
  "$HOME/python-env/ansible2.16/bin/python3" "interactive python3 is the ansible venv's"
assert_ok "the venv was created, no package was installed" -- test -x "$HOME/python-env/ansible2.16/bin/python"
assert_fail "ansible is not installed by us" -- test -e "$HOME/python-env/ansible2.16/bin/ansible"

# WSL: the session is silent and the Windows PATH entries are filtered.
mnt="$(mktemp -d)"
mkdir -p "$mnt/c/Tools" "$mnt/c/WINDOWS"
touch "$mnt/c/WINDOWS/explorer.exe"
assert_eq "$(DF_WSL_MNT_PREFIX="$mnt/" PATH="$PATH:$mnt/c/Tools:$mnt/c/WINDOWS" bash -c '. ~/.bashrc; echo "$PATH"' 2>&1 | tr ':' '\n' | grep -c "^$mnt/")" 1 \
  "ssh-like bash keeps only the allowlisted Windows entry"
assert_eq "$(DF_WSL_MNT_PREFIX="$mnt/" PATH="$PATH:$mnt/c/Tools" bash -lc 'echo ok' 2>&1)" ok "login shell stays silent under WSL"
assert_eq "$(DF_WSL_MNT_PREFIX="$mnt/" PATH="$PATH:$mnt/c/Tools" bash -c '. ~/.bashrc; echo ok' 2>&1)" ok "ssh-like shell stays silent under WSL"
assert_eq "$("$zsh_bin" -c 'echo ok' 2>&1)" ok "zsh -c stays silent under WSL"
assert_eq "$("$zsh_bin" -lc 'echo ok' 2>&1)" ok "zsh -lc stays silent under WSL"
assert_eq "$(bash -c '. ~/.bashrc; echo "$LC_ALL"')" "en_US.UTF-8" "the locale is set in a non-interactive shell"
p="$(bash -c '. ~/.bashrc; echo "$PATH"')"
assert_ok "our PATH is still appended last in non-interactive shells" -- bash -c "[[ \"$p\" == */usr/bin*$HOME/.local/bin* ]]"
rm -rf "$mnt"

# Startup time on WSL1 is the tightest budget (600 ms): warm up, then 10 starts.
zsh_i() { pty "TERM=xterm-256color $zsh_bin -i -c '$1'"; }
assert_eq "$(zsh_i exit)" "" "interactive zsh prints nothing under WSL"
zsh_i exit >/dev/null
times=()
for _ in 1 2 3 4 5 6 7 8 9 10; do
  s=$(date +%s%N)
  zsh_i exit >/dev/null
  times+=($(( ($(date +%s%N) - s) / 1000000 )))
done
median="$(printf '%s\n' "${times[@]}" | sort -n | sed -n 5p)"
printf 'zsh -i startup ms: %s (median %s)\n' "${times[*]}" "$median" >&2
assert_ok "zsh startup median ${median}ms < 600ms" -- test "$median" -lt 600

# WSL1 mode with the real mise (the stub-based checks of every row are in 40-interactive.sh):
# the install leaves a fresh cache, and shells then make no mise call at start or per prompt.
cache="$HOME/.cache/dotfiles/mise-env.sh"
venv="$HOME/python-env/ansible2.16"
assert_ok "the install left the mise cache" -- test -r "$cache"
bin_paths="$(cd "$HOME" && bash -lc 'mise bin-paths' | paste -sd: -)"
assert_eq "$(sed -n 1p "$cache")" "# df-mise-dirs $venv/bin:$bin_paths" "the cache holds the venv and the tool dirs mise puts in front"
assert_eq "$(sed -n 2p "$cache")" "# df-mise-bin $HOME/.local/bin/mise" "and names the mise that wrote it"
assert_ok "and the non-PATH variables of the global config" -- grep -qx "export VIRTUAL_ENV=$venv" "$cache"
assert_eq "$(sed 1,2d "$cache" | grep -c '^export PATH=' || true)" 0 "and no PATH"
p="$(bash -c '. ~/.bashrc; echo "$PATH"')"
assert_eq "${p#*:"$HOME"/.local/bin:}" "$venv/bin:$bin_paths" "non-interactive: the real dirs, last, in place of the shims"
assert_ok "python3 runs from them in a non-interactive login shell" -- grep -q 'Python 3.12.16' <<<"$(bash -lc 'python3 --version' 2>&1)"

# A counting wrapper takes the place of the mise binary (a change of the binary also
# invalidates the cache, which the first start below shows).
mise_bin="$HOME/.local/bin/mise"
mv "$mise_bin" "$mise_bin-real"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"${DF_TEST_MISE_LOG:-/dev/null}"\nexec "%s-real" "$@"\n' "$mise_bin" >"$mise_bin"
chmod +x "$mise_bin"
export DF_TEST_MISE_LOG="$HOME/mise-calls"
n_calls() { if [ -f "$DF_TEST_MISE_LOG" ]; then wc -l <"$DF_TEST_MISE_LOG" | tr -d ' '; else echo 0; fi; }
: >"$DF_TEST_MISE_LOG"
zsh_i exit >/dev/null
assert_eq "$(n_calls)" 1 "a changed mise binary regenerates the cache once"
: >"$DF_TEST_MISE_LOG"
assert_eq "$(zsh_i exit)" "" "zsh -i prints nothing"
bash_i() { pty "DOTFILES_IN_ZSH=1 TERM=xterm-256color bash -i -c '$1'"; }
assert_eq "$(bash_i true)" "" "bash -i prints nothing"
assert_eq "$(n_calls)" 0 "zsh -i and bash -i make zero mise calls with a fresh cache"
assert_eq "$(zsh_i 'print -r -- ${PATH%%:*}')" "$venv/bin" "the venv is in front of PATH"
n_front=$(($(tr ':' '\n' <<<"$bin_paths" | wc -l) + 1))
assert_eq "$(zsh_i "print -r -- \${(j.:.)\${(s.:.)PATH}[1,$n_front]}")" "$venv/bin:$bin_paths" "the real tool dirs follow, in the order mise uses"
assert_eq "$(zsh_i 'print -r -- $VIRTUAL_ENV')" "$venv" "VIRTUAL_ENV is set as activation sets it"
assert_eq "$(bash_i 'echo $VIRTUAL_ENV')" "$venv" "also in bash"
assert_eq "$(zsh_i 'print -r -- ${commands[python3]}')" "$venv/bin/python3" "python3 is the venv's, as with activation"
zsh_i 'for f in $precmd_functions; do $f; done' >/dev/null
assert_eq "$(n_calls)" 0 "the precmd hooks make zero mise calls"
assert_eq "$(bash_i 'eval "$PROMPT_COMMAND"')" "" "the PROMPT_COMMAND entries make zero mise calls and print nothing"
assert_eq "$(n_calls)" 0 "bash: still zero"
# A project config switches to the real activation.
mkdir -p "$HOME/proj-test"
printf '[tools]\n' >"$HOME/proj-test/mise.toml"
assert_eq "$(zsh_i 'cd ~/proj-test; print -r -- ${+functions[_mise_hook]}')" 1 "zsh: cd into a project directory activates mise"
assert_ok "and mise was called" -- test "$(n_calls)" -ge 1
assert_eq "$(zsh_i 'print -r -- ${+functions[_mise_hook]}')" 0 "zsh: and a plain start does not"
rm -rf "$HOME/proj-test"
# A touched config regenerates the cache once.
: >"$DF_TEST_MISE_LOG"
sleep 1
touch "$HOME/.config/mise/config.workstation.toml"
zsh_i exit >/dev/null
assert_eq "$(n_calls)" 1 "a touched mise config regenerates the cache once"
zsh_i exit >/dev/null
assert_eq "$(n_calls)" 1 "and the next start makes no call"
rm -f "$mise_bin"
mv "$mise_bin-real" "$mise_bin"
rm -f "$DF_TEST_MISE_LOG"
unset DF_TEST_MISE_LOG
# `dotfiles update` ends with a fresh cache as well.
rm -f "$cache"
DOTFILES_SRC="$src" "$HOME/.local/bin/dotfiles" update >/dev/null 2>&1 || _fail "dotfiles update failed"
assert_ok "dotfiles update rewrote the mise cache" -- test -r "$cache"

# Purge takes back everything the installer did. The venv is the user's own
# environment (it is what ansible lives in), so it is deliberately left alone.
# Running the tools made state of their own (opencode, opentofu, starship); that
# is the user's, not the installer's, and is cleared so the listing below sees
# only what the install created.
bash "$HOME/.dotfiles/uninstall.sh" --purge >/dev/null 2>&1
assert_ok "purge leaves the venv in place" -- test -d "$HOME/python-env"
rm -rf "$HOME/python-env" "$HOME/.terraform.d" "$HOME/.cache/starship" "$HOME/.cache/opencode" \
  "$HOME/.config/opencode" "$HOME/.local/share/opencode" "$HOME/.local/state/opencode"
for d in .local/share .local/state .local .config .cache; do rmdir "$HOME/$d" 2>/dev/null || true; done
assert_eq "$(tree_of)" "$tree_before" "purge restores the home tree of before the install"
rm -rf "$src"
