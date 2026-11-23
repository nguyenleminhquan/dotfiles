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

# The old setup put Homebrew on PATH. The doctor judges the PATH of a fresh login
# session (case_doctor_fresh_session below), so linuxbrew in the PATH this shell
# inherited means nothing: it is no WARN, and no package is found through it.
assert_ok "no linuxbrew on PATH is an OK line" -- grep -Eq '^OK +PATH: no linuxbrew' <<<"$doctor_out"
out="$(PATH="$PATH:/home/linuxbrew/.linuxbrew/bin" df_out "$df" doctor)"
assert_ok "linuxbrew only in the inherited PATH is not seen" -- grep -Eq '^OK +PATH: no linuxbrew' <<<"$out"

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

# --- case_doctor_fresh_session ------------------------------------------------------------
# The doctor looks at what a NEW terminal sees: the PATH of a login shell started with
# nothing inherited (like ssh or cron). install.sh runs it from the old shell, whose PATH
# has more in it than a fresh session will have. The linuxbrew prefix is a test hook
# (DF_LINUXBREW_PREFIX), as are DF_LOGIN_SHELL and DF_ETC_ENVIRONMENT_FILE; the stubs
# below stand in for tools that exist only there.
brew="$fx/brew"
inh="$fx/inherited"
mkdir -p "$brew/bin" "$inh"
brew_begin='# >>> dotfiles: linuxbrew on PATH >>>'
# brew_block <prefix>: the block `dotfiles migrate` writes into env.local.
brew_block() {
  printf '%s\n' "$brew_begin" \
    '# The login shell and tools such as screen live only in linuxbrew on this host.' \
    '# Appended last, so system tools win; remove this block once brew is gone.' \
    'case ":$PATH:" in' \
    "  *:$1/bin:*) ;;" \
    "  *) [ -d $1/bin ] && PATH=\"\$PATH:$1/bin:$1/sbin\" ;;" \
    'esac' \
    '# <<< dotfiles: linuxbrew on PATH <<<'
}
stub() { printf '#!/bin/sh\nexit 0\n' >"$1"; chmod +x "$1"; }
# probe_doctor: the doctor with one package that no system has, and nothing else changed.
probe_doctor() { ( . /src/lib/doctor.sh; DF_DOCTOR_PACKAGES=(dfprobe); df_doctor ) 2>&1 || true; }
mkdir -p ~/.config/dotfiles

# A package that only the inherited PATH has is missing for a new terminal. This is the
# node that passed the install's doctor and warned in a fresh login.
stub "$inh/dfprobe"
out="$(PATH="$inh:$PATH" probe_doctor)"
assert_ok "a package only the inherited PATH has is a WARN" -- grep -Eq '^WARN +package: dfprobe' <<<"$out"
rm -f "$inh/dfprobe"

# A package that the env.local block makes reachable is found by a fresh session.
stub "$brew/bin/dfprobe"
brew_block "$brew" >~/.config/dotfiles/env.local
out="$(DF_LINUXBREW_PREFIX="$brew" probe_doctor)"
assert_ok "a package reached through the env.local block is OK" -- grep -Eq '^OK +package: dfprobe' <<<"$out"
assert_ok "and the block is named as the reason" -- \
  grep -Eq '^OK +PATH: linuxbrew on PATH \(appended last\) through env.local; remove the block when brew is gone' <<<"$out"
assert_eq "$(grep -c '^FAIL' <<<"$out" || true)" 0 "the block is no FAIL"
# A zsh that only the block provides is the zsh of a new terminal (rows without a system zsh).
stub "$brew/bin/zsh"
out="$(DF_LINUXBREW_PREFIX="$brew" probe_doctor)"
assert_ok "a zsh reached through the block is found" -- grep -Eq '^OK +zsh startup: ' <<<"$out"
# The startup budget (600 ms, DF_DOCTOR_ZSH_BUDGET_MS lowers it for tests): over it is a WARN with a
# hint, under it stays OK. The slow zsh is a stub that sleeps, put in front of the system's by
# env.local (a zsh from the brew block would come after the system zsh of most rows). WSL1 is
# pretended with a fixture.
slowbin="$fx/slowbin"
mkdir -p "$slowbin"
printf 'PATH="%s:$PATH"\n' "$slowbin" >~/.config/dotfiles/env.local
printf '#!/bin/sh\nsleep 0.7\n' >"$slowbin/zsh"
chmod +x "$slowbin/zsh"
out="$(probe_doctor)"
assert_ok "a zsh slower than the default 600 ms budget is a WARN" -- grep -Eq '^WARN +zsh startup: [0-9]+ ms \(median of 3\), over the 600 ms budget' <<<"$out"
assert_eq "$(grep -c '^FAIL' <<<"$out" || true)" 0 "and no FAIL"
printf '#!/bin/sh\nsleep 0.4\n' >"$slowbin/zsh"
out="$(DF_DOCTOR_ZSH_BUDGET_MS=2000 probe_doctor)"
assert_ok "under a raised budget the same zsh is OK" -- grep -Eq '^OK +zsh startup: [0-9]+ ms \(median of 3\)$' <<<"$out"
out="$(DF_DOCTOR_ZSH_BUDGET_MS=200 DF_PROC_VERSION_FILE=/nonexistent probe_doctor)"
assert_ok "the budget can be lowered" -- grep -Eq '^WARN +zsh startup: [0-9]+ ms \(median of 3\), over the 200 ms budget' <<<"$out"
assert_fail "natively there is no WSL hint" -- grep -Eq '^WARN +zsh startup.*(WSL|localrc)' <<<"$out"
out="$(DF_DOCTOR_ZSH_BUDGET_MS=200 DF_PROC_VERSION_FILE=/src/test/fixtures/proc-version-wsl1 probe_doctor)"
assert_ok "on WSL1 the WARN names mise activate and ~/.localrc" -- grep -Eq '^WARN +zsh startup: .*mise activate.*~/\.localrc' <<<"$out"
assert_ok "and says that WSL2 starts processes natively" -- grep -Eq '^WARN +zsh startup: .*WSL2 starts processes natively' <<<"$out"
printf 'Linux version 5.15.153.1-microsoft-standard-WSL2\n' >"$fx/proc-wsl2"
out="$(DF_DOCTOR_ZSH_BUDGET_MS=200 DF_PROC_VERSION_FILE="$fx/proc-wsl2" probe_doctor)"
assert_fail "on WSL2 there is no WSL hint" -- grep -Eq '^WARN +zsh startup.*(WSL|localrc)' <<<"$out"
printf '#!/bin/sh\nexit 0\n' >"$slowbin/zsh"
out="$(DF_DOCTOR_ZSH_BUDGET_MS=200 DF_PROC_VERSION_FILE=/src/test/fixtures/proc-version-wsl1 probe_doctor)"
assert_ok "a fast zsh is OK, on WSL1 too" -- grep -Eq '^OK +zsh startup: [0-9]+ ms \(median of 3\)$' <<<"$out"
# On WSL every new process from wsl.exe gets the Windows PATH appended to the distribution's, so the
# fresh session the doctor imitates starts from /etc/environment's PATH plus the inherited entries
# under /mnt/ (in their order). Natively it is /etc/environment's alone.
printf 'PATH="/etc/one:/etc/two"\n' >"$fx/etc-path"
start_path() { ( . /src/lib/doctor.sh; DF_ETC_ENVIRONMENT_FILE="${ETC_FILE:-$fx/etc-path}" _df_doctor_start_path ); }
inherited="/usr/bin:/mnt/c/Win One/bin:/bin:/mnt/d/tools:/opt/x:/mntx/no:/mnt/c/Win Two"
assert_eq "$(DF_PROC_VERSION_FILE=/nonexistent PATH="$inherited" start_path)" "/etc/one:/etc/two" "natively the probe PATH is /etc/environment's alone"
assert_eq "$(DF_PROC_VERSION_FILE=/src/test/fixtures/proc-version-wsl1 PATH="$inherited" start_path)" \
  "/etc/one:/etc/two:/mnt/c/Win One/bin:/mnt/d/tools:/mnt/c/Win Two" "on WSL1 the inherited /mnt/ entries follow, in order"
assert_eq "$(DF_PROC_VERSION_FILE="$fx/proc-wsl2" PATH="$inherited" start_path)" \
  "/etc/one:/etc/two:/mnt/c/Win One/bin:/mnt/d/tools:/mnt/c/Win Two" "and on WSL2, which appends the Windows PATH too"
assert_eq "$(DF_PROC_VERSION_FILE=/src/test/fixtures/proc-version-wsl1 DF_WSL_MNT_PREFIX=/opt/ PATH="$inherited" start_path)" \
  "/etc/one:/etc/two:/opt/x" "the mount prefix is the one wsl.sh uses (DF_WSL_MNT_PREFIX)"
assert_eq "$(DF_PROC_VERSION_FILE=/src/test/fixtures/proc-version-wsl1 PATH=/usr/bin:/bin start_path)" "/etc/one:/etc/two" "on WSL with no /mnt/ entry inherited nothing is added"
assert_eq "$(ETC_FILE=/nonexistent DF_PROC_VERSION_FILE=/src/test/fixtures/proc-version-wsl1 PATH="$inherited" start_path)" \
  "/usr/local/bin:/usr/bin:/bin:/mnt/c/Win One/bin:/mnt/d/tools:/mnt/c/Win Two" "the default start PATH gets them too"
# The zsh startup is timed from that PATH on WSL (a stub zsh writes down the PATH it gets), and
# natively from the PATH of the caller as before.
rec="$fx/zsh-path"
printf '#!/bin/sh\nprintf "%%s" "$PATH" >"%s"\n' "$rec" >"$slowbin/zsh"
printf 'PATH="/usr/local/bin:/usr/bin:/bin"\n' >"$fx/etc-path"
out="$(DF_ETC_ENVIRONMENT_FILE="$fx/etc-path" DF_PROC_VERSION_FILE=/src/test/fixtures/proc-version-wsl1 PATH="$PATH:/mnt/c/Win One/bin" probe_doctor)"
assert_ok "the zsh check ran on WSL" -- grep -Eq '^OK +zsh startup: ' <<<"$out"
assert_eq "$(cat "$rec")" "/usr/local/bin:/usr/bin:/bin:/mnt/c/Win One/bin" "on WSL zsh is started with the fresh session's PATH, Windows entries included"
out="$(DF_ETC_ENVIRONMENT_FILE="$fx/etc-path" DF_PROC_VERSION_FILE=/nonexistent PATH="$PATH:/mnt/c/Win One/bin" probe_doctor)"
assert_ok "the zsh check ran natively" -- grep -Eq '^OK +zsh startup: ' <<<"$out"
assert_eq "$(cat "$rec")" "$PATH:/mnt/c/Win One/bin" "natively zsh keeps the PATH of the caller"
rm -f "$rec"
rm -rf "$slowbin"
brew_block "$brew" >~/.config/dotfiles/env.local
rm -f "$brew/bin/zsh"
# Without the block the same package is missing, whatever the inherited PATH says.
rm -f ~/.config/dotfiles/env.local
out="$(PATH="$brew/bin:$PATH" DF_LINUXBREW_PREFIX="$brew" probe_doctor)"
assert_ok "without the block the package is a WARN" -- grep -Eq '^WARN +package: dfprobe' <<<"$out"
assert_ok "and the inherited brew directory is not a PATH finding" -- grep -Eq '^OK +PATH: no linuxbrew' <<<"$out"
rm -f "$brew/bin/dfprobe"

# brew on PATH from anywhere else, or in front of /usr/bin, stays a WARN. /etc/environment
# is named only when it really holds linuxbrew.
printf 'PATH="$PATH:%s/bin"\n' "$brew" >~/.config/dotfiles/env.local
out="$(DF_LINUXBREW_PREFIX="$brew" probe_doctor)"
assert_ok "brew on PATH without the marked block is a WARN" -- grep -Eq "^WARN +PATH: .*$brew" <<<"$out"
assert_fail "the WARN does not blame /etc/environment, which is clean" -- grep -Eq '^WARN +PATH.*/etc/environment' <<<"$out"
{ printf '%s\n' "$brew_begin" "PATH=\"$brew/bin:\$PATH\"" '# <<< dotfiles: linuxbrew on PATH <<<'; } >~/.config/dotfiles/env.local
out="$(DF_LINUXBREW_PREFIX="$brew" probe_doctor)"
assert_ok "brew in front of /usr/bin is a WARN even with the marker" -- grep -Eq "^WARN +PATH: .*$brew.*before /usr/bin" <<<"$out"
assert_fail "and not the OK line" -- grep -Eq '^OK +PATH: linuxbrew' <<<"$out"
printf 'PATH="$PATH:%s/bin"\n' "$brew" >~/.config/dotfiles/env.local
printf 'PATH=/usr/bin:%s/bin\n' "$brew" >"$fx/etc-environment"
out="$(DF_LINUXBREW_PREFIX="$brew" DF_ETC_ENVIRONMENT_FILE="$fx/etc-environment" probe_doctor)"
assert_ok "an /etc/environment that holds it is named" -- grep -Eq '^WARN +PATH.*/etc/environment' <<<"$out"
assert_eq "$(df_rc env DF_LINUXBREW_PREFIX="$brew" "$df" doctor)" 0 "a brew WARN does not fail the doctor"
rm -f ~/.config/dotfiles/env.local

# brew only in /etc/environment: pam_env gives every ssh and console login that PATH before any
# shell file runs, so a probe that starts from the default PATH never sees it. The probe starts
# from the PATH= line of /etc/environment (parsed, never sourced), and a brew that file holds is
# a WARN whether it comes before or after /usr/bin, since it is not from the marked block. Some
# distributions reset PATH in /etc/profile, which hides it from a login probe: the file itself is
# looked at too.
rm -f ~/.config/dotfiles/env.local
for order in before after; do
  if [ "$order" = before ]; then
    printf 'PATH="%s/bin:/usr/local/bin:/usr/bin:/bin"\n' "$brew" >"$fx/etc-environment"
  else
    printf 'PATH="/usr/local/bin:/usr/bin:/bin:%s/bin"\n' "$brew" >"$fx/etc-environment"
  fi
  out="$(DF_LINUXBREW_PREFIX="$brew" DF_ETC_ENVIRONMENT_FILE="$fx/etc-environment" probe_doctor)"
  assert_ok "brew only in /etc/environment ($order /usr/bin) is a WARN naming the file" -- \
    grep -Eq "^WARN +PATH: .*$brew.*/etc/environment" <<<"$out"
  assert_fail "and not the OK line ($order /usr/bin)" -- grep -Eq '^OK +PATH: (no linuxbrew|linuxbrew)' <<<"$out"
  assert_eq "$(grep -c '^FAIL' <<<"$out" || true)" 0 "the /etc/environment brew is no FAIL ($order /usr/bin)"
  # The marked env.local block does not excuse a brew that /etc/environment also puts there.
  brew_block "$brew" >~/.config/dotfiles/env.local
  out="$(DF_LINUXBREW_PREFIX="$brew" DF_ETC_ENVIRONMENT_FILE="$fx/etc-environment" probe_doctor)"
  assert_ok "the block does not hide an /etc/environment brew ($order /usr/bin)" -- grep -Eq '^WARN +PATH: .*/etc/environment' <<<"$out"
  rm -f ~/.config/dotfiles/env.local
done
# A PATH line that needs a shell to evaluate is not used; the default start PATH stays.
printf 'PATH="$PATH:%s/bin"\n' "$brew" >"$fx/etc-environment"
out="$(DF_LINUXBREW_PREFIX="$brew" DF_ETC_ENVIRONMENT_FILE="$fx/etc-environment" probe_doctor)"
assert_ok "a PATH line with a variable in it is ignored" -- grep -Eq '^OK +PATH: no linuxbrew|^WARN +PATH: .*/etc/environment' <<<"$out"
assert_eq "$(grep -c '^FAIL' <<<"$out" || true)" 0 "and is no FAIL"
# A comment in /etc/environment that mentions linuxbrew is not a PATH entry.
printf '# linuxbrew was removed from here\nPATH="/usr/local/bin:/usr/bin:/bin"\n' >"$fx/etc-environment"
out="$(DF_LINUXBREW_PREFIX="$brew" DF_ETC_ENVIRONMENT_FILE="$fx/etc-environment" probe_doctor)"
assert_ok "a commented linuxbrew line in /etc/environment is no WARN" -- grep -Eq '^OK +PATH: no linuxbrew' <<<"$out"
rm -f "$fx/etc-environment"

# A login shell that lives in brew while a fresh session has no brew: its owner cannot log in
# by name tomorrow, and `zsh` is gone from PATH.
out="$(DF_LINUXBREW_PREFIX="$brew" DF_LOGIN_SHELL="$brew/bin/zsh" probe_doctor)"
assert_ok "a login shell in brew without brew on PATH is a WARN naming it" -- \
  grep -Eq "^WARN +PATH: login shell $brew/bin/zsh .*linuxbrew" <<<"$out"
out="$(DF_LINUXBREW_PREFIX="$brew" DF_LOGIN_SHELL=/bin/bash probe_doctor)"
assert_ok "an ordinary login shell is nothing to report" -- grep -Eq '^OK +PATH: no linuxbrew' <<<"$out"
rm -rf "$brew" "$inh" "$fx/etc-environment"

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

# --- case_update_runs_a_private_copy -----------------------------------------------------
# WSL1 refuses to rename a directory while a process holds a file or its working
# directory inside it, and bash keeps the running install.sh open. The swap in
# the tarball update therefore must not run from $DOTFILES_DIR/install.sh. A stub
# mv stands in for WSL1: it refuses to move the install directory while any
# process has a file or its cwd inside, and records the command line of the
# process that asked (the shell running the installer).
stubs="$fx/stubs"
mkdir -p "$stubs"
cat >"$stubs/mv" <<'STUB'
#!/bin/sh
# Only the install directory itself is protected, like on WSL1.
real_dir=''
for arg in "$@"; do
  if [ "$arg" = "$STUB_MV_DIR" ] && [ -d "$arg" ]; then real_dir="$(cd "$arg" && pwd -P)"; fi
done
if [ -n "$real_dir" ]; then
  printf '%s\n' "$(tr '\0' ' ' </proc/$PPID/cmdline)" >>"$STUB_MV_LOG"
  busy=0
  if [ "$STUB_MV_MODE" = always ]; then busy=1; fi
  for link in /proc/[0-9]*/fd/* /proc/[0-9]*/cwd; do
    target="$(readlink "$link" 2>/dev/null || true)"
    case "$target" in
      "$real_dir" | "$real_dir"/*) busy=1 ;;
    esac
  done
  if [ "$busy" = 1 ]; then
    echo "mv: cannot move '$real_dir': Permission denied" >&2
    exit 1
  fi
fi
PATH="${PATH#"$STUB_MV_PATH":}"
exec mv "$@"
STUB
chmod +x "$stubs/mv"
# stub_update <mode> [env...]: dotfiles update in the tarball home with the stub mv first on PATH.
stub_update() {
  local mode="$1"
  shift
  "${isoenv[@]}" HOME="$th" TMPDIR="$fx/tmp" PATH="$stubs:$PATH" STUB_MV_PATH="$stubs" STUB_MV_DIR="$th/.dotfiles" \
    STUB_MV_MODE="$mode" STUB_MV_LOG="$fx/mv.log" "$@" "$th/.local/bin/dotfiles" update
}

# The tarball install again (the uninstall below needs it).
mkpack tar-3
: >"$fx/mv.log"
out="$(stub_update open 2>&1)" || _fail "update with the swap refused for a file held open in the install directory failed: $out"
assert_eq "$(cat "$th/.dotfiles/config/update-probe")" "tar-3" "update swapped the new code in"
assert_eq "$(wc -l <"$fx/mv.log" | tr -d ' ')" 1 "the stub saw exactly one move of the install directory"
assert_ok "the installer ran from a private copy under ~/.cache/dotfiles" -- grep -q "^bash $th/.cache/dotfiles/" "$fx/mv.log"
assert_fail "and not from the install directory" -- grep -q "$th/.dotfiles/install.sh" "$fx/mv.log"
assert_fail "the copy is removed again" -- compgen -G "$th/.cache/dotfiles/install.*"
assert_eq "$(ls -A "$fx/tmp")" "" "the copy is not written outside HOME"
assert_eq "$("$th/.local/bin/dotfiles" profile)" "$DF_PROFILE" "update through a copy keeps the profile"

# A process with its working directory in the install directory (a shell cd-ed
# there): the rename is refused, the message says why, the install stays as it was.
mkpack tar-4
(cd "$th/.dotfiles" && exec sleep 120) &
holder=$!
out="$(stub_update open 2>&1)" && _fail "update succeeded although a process holds the install directory"
assert_ok "the refusal names the cause and the way out" -- \
  grep -q 'working directory.*close it and run the update again' <<<"$out"
assert_ok "the refusal names the install directory" -- grep -qF "$th/.dotfiles" <<<"$out"
assert_eq "$(cat "$th/.dotfiles/config/update-probe")" "tar-3" "a refused update leaves the install alone"
assert_ok "and the install is still usable" -- test -f "$th/.dotfiles/install.sh"
assert_fail "and no copy is left behind" -- compgen -G "$th/.cache/dotfiles/install.*"
assert_fail "and no staging directory is left behind" -- compgen -G "$th/.dotfiles.staging.*"
assert_fail "nor an aside copy" -- compgen -G "$th/.dotfiles.old.*"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
out="$(stub_update open 2>&1)" || _fail "update after the holder exited failed: $out"
assert_eq "$(cat "$th/.dotfiles/config/update-probe")" "tar-4" "the update goes through once nothing holds the directory"

# DOTFILES_SRC naming the install directory itself is the in-place path: no swap,
# so nothing is moved and nothing needs a copy.
: >"$fx/mv.log"
stub_update always DOTFILES_SRC="$th/.dotfiles" >/dev/null 2>&1 || _fail "update with DOTFILES_SRC=\$DOTFILES_DIR failed"
assert_eq "$(wc -c <"$fx/mv.log" | tr -d ' ')" 0 "update from the install directory itself moves nothing"

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
