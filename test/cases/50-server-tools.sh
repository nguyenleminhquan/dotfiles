# Profile server: zsh-bin where needed, the pinned mise tools, starship,
# fzf, completions, and the way back to minimal. Server rows download the full
# tool list once (it is purged at the end); the downgrade and isolation
# scenarios install a three-tool copy of the repo instead, so they cost about
# 70 MB rather than 1 GB. Minimal rows run offline and only prove that nothing
# tool-related appears.
# SC2016: the zsh and bash snippets are meant to be expanded by the shell under test.
# SC2030/SC2031: HOME is changed in subshells on purpose.
# shellcheck disable=SC2016,SC2030,SC2031
cfg=/src/config/mise/config.toml

# elf_interp <file>: the program interpreter (PT_INTERP) of a 64-bit
# little-endian ELF file, nothing when it has none (a static binary). Plain od
# and dd, so it works on every row without binutils or file(1).
elf_interp() {
  local f="$1" phoff phentsize phnum i off po sz
  phoff="$(od -An -t u8 -j 32 -N 8 "$f" | tr -d ' ')"
  phentsize="$(od -An -t u2 -j 54 -N 2 "$f" | tr -d ' ')"
  phnum="$(od -An -t u2 -j 56 -N 2 "$f" | tr -d ' ')"
  for ((i = 0; i < phnum; i++)); do
    off=$((phoff + i * phentsize))
    if [ "$(od -An -t u4 -j "$off" -N 4 "$f" | tr -d ' ')" = 3 ]; then
      po="$(od -An -t u8 -j $((off + 8)) -N 8 "$f" | tr -d ' ')"
      sz="$(od -An -t u8 -j $((off + 32)) -N 8 "$f" | tr -d ' ')"
      # p_filesz includes the terminating NUL.
      dd if="$f" bs=1 skip="$po" count=$((sz - 1)) 2>/dev/null
      return 0
    fi
  done
}

# --- case_pure_helpers: no network, no install --------------------------------
(
  # shellcheck source=/dev/null
  . /src/lib/log.sh
  # shellcheck source=/dev/null
  . /src/lib/tools.sh
  for v in 5.8 5.8.1 5.9 6.0 10.1; do
    assert_ok "zsh $v is new enough" -- _df_zsh_version_ok "zsh $v (x86_64-pc-linux-gnu)"
  done
  for v in 5.7.1 5.0.2 4.3.17 '' garbage; do
    assert_fail "zsh '$v' is too old or unreadable" -- _df_zsh_version_ok "zsh $v (x)"
  done
  d="$(mktemp -d)"
  printf 'hello\n' >"$d/f"
  sum="$(sha256sum <"$d/f" | cut -d' ' -f1)"
  assert_ok "matching sha256 passes" -- _df_sha256_check "$d/f" "$sum"
  assert_fail "wrong sha256 is rejected" -- _df_sha256_check "$d/f" "$(printf '0%.0s' $(seq 64))"
  assert_fail "empty sha256 is rejected" -- _df_sha256_check "$d/f" ""
  printf '%s  ./a-linux.tar.gz\n%s  ./b-linux.tar.gz.sig\n' "$sum" "ffff" >"$d/sums"
  assert_eq "$(_df_shasums_lookup "$d/sums" a-linux.tar.gz)" "$sum" "lookup finds the exact name"
  assert_eq "$(_df_shasums_lookup "$d/sums" b-linux.tar.gz || echo none)" "none" "lookup does not match a longer name"
  assert_eq "$(_df_shasums_lookup "$d/sums" zzz || echo none)" "none" "lookup of a missing name fails"
  rm -rf "$d"
)

# --- case_remove_only_what_was_recorded: forged state, no network ---------------
(
  # shellcheck source=/dev/null
  . /src/lib/log.sh
  # shellcheck source=/dev/null
  . /src/lib/tools.sh
  fx="$(mktemp -d)"
  export HOME="$fx"
  state="$fx/.config/dotfiles"
  mkdir -p "$state" "$fx/.local/bin" "$fx/.local/share/mise/installs/aqua-a/1.0/bin" \
    "$fx/.local/share/mise/installs/aqua-b/2.0/bin" "$fx/.cache/zsh/completions" "$fx/.cache/dotfiles/init"
  printf '#!/bin/sh\necho "$*" >>"%s/mise.log"\n' "$fx" >"$fx/.local/bin/mise"
  chmod +x "$fx/.local/bin/mise"
  printf 'aqua-a/1.0\n' >"$state/mise-installs"
  # The user's own mise and tool (aqua-b) are not recorded: both must survive.
  df_tools_remove >/dev/null 2>&1
  assert_file_absent "$fx/.local/share/mise/installs/aqua-a"
  assert_ok "unrecorded tool survives" -- test -d "$fx/.local/share/mise/installs/aqua-b/2.0/bin"
  assert_ok "unrecorded mise binary survives" -- test -x "$fx/.local/bin/mise"
  assert_ok "shims are rebuilt after removing tools" -- grep -q reshim "$fx/mise.log"
  assert_file_absent "$state/mise-installs"
  assert_file_absent "$fx/.cache/zsh/completions"
  assert_file_absent "$fx/.cache/dotfiles/init"

  # Recorded: mise itself and a data directory that did not exist before. The
  # user has installed aqua-b since (and has a global config of their own), so
  # the data directory and the config stay; only the binary goes.
  mkdir -p "$fx/.config/mise"
  printf '[tools]\n"aqua:b" = "2.0"\n' >"$fx/.config/mise/config.toml"
  printf 'mise-bin\nmise-data\n' >"$state/tools"
  out="$(df_tools_remove 2>&1)"
  assert_file_absent "$fx/.local/bin/mise"
  assert_ok "a tool the user installed keeps the data directory" -- test -d "$fx/.local/share/mise/installs/aqua-b/2.0/bin"
  assert_ok "and the user is told" -- grep -q 'kept the tools you installed' <<<"$out"
  assert_ok "the user's global mise config is never touched" -- grep -q 'aqua:b' "$fx/.config/mise/config.toml"
  assert_file_absent "$state/tools"
  # Only our own installs in a directory we created: all of it goes.
  rm -rf "$fx/.local/share/mise/installs/aqua-b"
  mkdir -p "$fx/.local/share/mise/installs/aqua-c/3.0/bin" "$fx/.local/state/mise" "$fx/.local/bin"
  : >"$fx/.local/bin/mise"
  printf 'mise-bin\nmise-data\n' >"$state/tools"
  printf 'aqua-c/3.0\n' >"$state/mise-installs"
  df_tools_remove >/dev/null 2>&1
  assert_file_absent "$fx/.local/share/mise"
  assert_file_absent "$fx/.local/state/mise"
  assert_file_absent "$fx/.local/bin/mise"
  assert_file_absent "$state/tools"
  assert_file_absent "$state/mise-installs"
  assert_ok "the user's global mise config survives that too" -- grep -q 'aqua:b' "$fx/.config/mise/config.toml"
  rm -rf "$fx/.config/mise"

  # Nothing recorded: a no-op that prints nothing.
  mkdir -p "$fx/.local/bin"
  : >"$fx/.local/bin/keep"
  assert_eq "$(df_tools_remove 2>&1)" "" "removal with no state is silent"
  assert_ok "unrelated files untouched" -- test -e "$fx/.local/bin/keep"
  rm -rf "$fx"
)

# --- case_dry_run_changes_nothing -----------------------------------------------
h0="$(home_hash)"
out="$(bash /src/install.sh --profile server --dry-run 2>&1)"
assert_ok "dry run says what it would install" -- grep -qi 'would install' <<<"$out"
assert_eq "$(home_hash)" "$h0" "dry run changes nothing"
assert_file_absent "$HOME/.local/bin/mise"
assert_file_absent "$HOME/.local/share/mise"


# --- case_system_tool_completions: docker, crictl, podman and gh (no network) ------------
# Stub tools on a private PATH; no mise is reachable, so each tool is found as the
# host's own binary. df_gen_completions must keep only output that starts with
# #compdef, call gh as `completion -s zsh`, run the tools with scratch XDG
# directories, and drop the file of a tool that is gone.
(
  # shellcheck source=/dev/null
  . /src/lib/log.sh
  # shellcheck source=/dev/null
  . /src/lib/tools.sh
  fx="$(mktemp -d)"
  export HOME="$fx"
  export PATH="$fx/bin:/usr/bin:/bin"
  mkdir -p "$fx/bin"
  comp="$fx/.cache/zsh/completions"
  # docker: a good script, and it records the XDG directory it was given.
  cat >"$fx/bin/docker" <<STUB
#!/bin/sh
[ "\$1 \$2" = "completion zsh" ] || exit 1
printf '%s\n' "\$XDG_CONFIG_HOME" >>"$fx/docker-xdg"
printf '%s\n' "\${DOCKER_CONFIG:-unset}" >>"$fx/docker-config"
# A real docker creates its config directory even for \`completion\`.
mkdir -p "\${DOCKER_CONFIG:-\$HOME/.docker}"
printf '#compdef docker\n_docker() { :; }\n'
STUB
  # gh: only `completion -s zsh` works.
  cat >"$fx/bin/gh" <<'STUB'
#!/bin/sh
[ "$1 $2 $3" = "completion -s zsh" ] || { echo 'unknown flag'; exit 1; }
printf '#compdef gh\n_gh() { :; }\n'
STUB
  # podman: exits 0 but prints something that is no completion script.
  printf '#!/bin/sh\necho "not a completion script"\n' >"$fx/bin/podman"
  chmod +x "$fx/bin/docker" "$fx/bin/gh" "$fx/bin/podman"
  # A leftover of a tool that is not installed (crictl) has to go.
  mkdir -p "$comp"
  printf '#compdef crictl\n' >"$comp/_crictl"
  printf 'x\n' >"$fx/.cache/zsh/zcompdump"
  out="$(df_gen_completions 2>&1)"
  assert_ok "docker completion is generated" -- grep -q '^#compdef docker' "$comp/_docker"
  assert_ok "gh completion is generated with -s zsh" -- grep -q '^#compdef gh' "$comp/_gh"
  assert_file_absent "$comp/_podman"
  assert_ok "garbage from podman is only a warning" -- grep -q 'no zsh completion from podman' <<<"$out"
  assert_fail "no warning for a tool that works" -- grep -q 'no zsh completion from docker' <<<"$out"
  assert_fail "no warning for a tool that is not installed" -- grep -q 'crictl' <<<"$out"
  assert_file_absent "$comp/_crictl"
  assert_file_absent "$fx/.cache/zsh/zcompdump"
  case "$(cat "$fx/docker-xdg")" in
    "$fx"/.cache/dotfiles.*/config) ;;
    *) _fail "docker ran with a scratch XDG_CONFIG_HOME, got: $(cat "$fx/docker-xdg")" ;;
  esac
  case "$(cat "$fx/docker-config")" in
    "$fx"/.cache/dotfiles.*/docker) ;;
    *) _fail "docker ran with a scratch DOCKER_CONFIG, got: $(cat "$fx/docker-config")" ;;
  esac
  assert_file_absent "$fx/.docker"
  assert_eq "$(find "$comp" -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" "_docker _gh " "only the working completions are left"
  assert_eq "$(find "$fx/.cache" -mindepth 1 -maxdepth 1 -printf '%f\n' | tr '\n' ' ')" "zsh " "the scratch directory is removed"

  # Unchanged output keeps the dump; a tool that goes away drops its file and the dump.
  printf 'x\n' >"$fx/.cache/zsh/zcompdump"
  assert_eq "$(df_gen_completions 2>&1 | grep -c 'completions updated' || true)" 0 "unchanged completions are not announced"
  assert_ok "unchanged completions keep the dump" -- test -e "$fx/.cache/zsh/zcompdump"
  rm -f "$fx/bin/docker"
  df_gen_completions >/dev/null 2>&1
  assert_file_absent "$comp/_docker"
  assert_ok "gh stays" -- test -e "$comp/_gh"
  assert_file_absent "$fx/.cache/zsh/zcompdump"
  rm -rf "$fx"
)
# --- case_elf_interp_helper: the check used for the musl assertions below -----------
assert_ok "a glibc binary names the glibc loader" -- grep -q 'ld-linux' <<<"$(elf_interp "$(command -v bash)")"

# --- case_env_shims_only_for_tool_profiles: no network, no install ------------------
# A mise shim of a removed or never wanted tool must not resolve on a minimal host.
fx="$(mktemp -d)"
mkdir -p "$fx/.config/dotfiles" "$fx/.local/share/mise/shims"
printf '#!/bin/sh\necho shim\n' >"$fx/.local/share/mise/shims/fakecmd"
chmod +x "$fx/.local/share/mise/shims/fakecmd"
shim_lookup() { env -i HOME="$fx" PATH=/usr/bin:/bin DOTFILES_DIR=/src sh -c ". /src/shell/env.sh; command -v fakecmd || echo none"; }
assert_eq "$(shim_lookup)" none "no saved profile: shims are not on PATH"
for p in minimal garbage; do
  echo "$p" >"$fx/.config/dotfiles/profile"
  assert_eq "$(shim_lookup)" none "profile $p: shims are not on PATH"
done
for p in server workstation; do
  echo "$p" >"$fx/.config/dotfiles/profile"
  assert_eq "$(shim_lookup)" "$fx/.local/share/mise/shims/fakecmd" "profile $p: shims are on PATH"
done
rm -rf "$fx"

# --- case_no_tools_downgrade_removes_tools: forged state, no network -----------------
# DOTFILES_NO_TOOLS only gates downloads: `install.sh --profile minimal` still
# takes back what a higher profile put there, and kubectl is gone afterwards.
fx="$(mktemp -d)"
inst() { HOME="$fx" DOTFILES_DIR="$fx/dots" DOTFILES_NO_TOOLS=1 bash /src/install.sh "$@" >/dev/null 2>&1; }
inst --profile server
mkdir -p "$fx/.local/bin" "$fx/.local/share/mise/shims" "$fx/.local/share/mise/installs/aqua-k/1/bin"
printf '#!/bin/sh\n:\n' >"$fx/.local/bin/mise"
printf '#!/bin/sh\necho fake kubectl\n' >"$fx/.local/share/mise/shims/kubectl"
chmod +x "$fx/.local/bin/mise" "$fx/.local/share/mise/shims/kubectl"
printf 'mise-bin\nmise-data\n' >"$fx/.config/dotfiles/tools"
# The install is recorded as ours, so that the data directory goes with the downgrade.
printf 'aqua-k/1\n' >"$fx/.config/dotfiles/mise-installs"
kubectl_lookup() { env -i HOME="$fx" PATH=/usr/bin:/bin bash -lc 'command -v kubectl || echo none'; }
assert_eq "$(kubectl_lookup)" "$fx/.local/share/mise/shims/kubectl" "server profile reaches kubectl through the shims"
inst --profile minimal
assert_eq "$(kubectl_lookup)" none "NO_TOOLS downgrade: kubectl is gone from PATH"
assert_file_absent "$fx/.local/bin/mise"
assert_file_absent "$fx/.local/share/mise"
assert_file_absent "$fx/.config/dotfiles/tools"
assert_file_absent "$fx/.config/mise/config.toml"
assert_file_absent "$fx/.config/mise/conf.d/dotfiles.toml"
rm -rf "$fx"

# --- minimal rows: offline, nothing tool-related ---------------------------------
if [ "$DF_PROFILE" = minimal ]; then
  bash /src/install.sh --profile minimal >/dev/null 2>&1
  for p in .local/bin/mise .local/bin/zsh .local/share/mise .local/state/mise .cache/mise \
           .cache/zsh/completions .cache/dotfiles/init .config/mise .config/starship.toml \
           .config/dotfiles/tools .config/dotfiles/mise-installs .config/dotfiles/zsh-bin-files; do
    assert_file_absent "$HOME/$p"
  done
  assert_eq "$(bash -lc 'command -v kubectl || echo none')" none "no kubectl on minimal"
  assert_eq "$(bash -lc 'command -v starship || echo none')" none "no starship on minimal"
  return 0
fi


# --- server rows ------------------------------------------------------------------
# What a purge has to restore: the home tree before the first install. Histories
# are the shell's own files, not the installer's.
tree_of() {
  (
    cd "$HOME" || exit 1
    find . -mindepth 1 ! -path './.dotfiles-backup' ! -path './.dotfiles-backup/*' \
      ! -name '*_history' ! -name '.lesshst' ! -name '.viminfo' | LC_ALL=C sort
  )
}
tree_before="$(tree_of)"

log="$(mktemp)"
install_server() {
  bash /src/install.sh --profile server >"$log" 2>&1 || { cat "$log" >&2; _fail "install.sh --profile server failed"; }
}
t0=$(date +%s)
install_server
printf 'full server install took %ss\n' "$(( $(date +%s) - t0 ))" >&2
# Generating the completions runs k9s, which creates ~/.local/state/k9s when it
# runs normally; the installer must not leave that behind. The test has run no
# tool yet, so it existing would be the installer's doing. (starship's own cache
# is not checked: the doctor at the end of the install starts an interactive zsh,
# which runs starship, as every real session does.)
assert_file_absent "$HOME/.local/state/k9s"

# case_tools_run: every tool of the config runs here (u20-* has glibc 2.31),
# found through the login shell's PATH like a real session would.
tool_cmds=(
  'github:starship/starship|starship --version'
  'aqua:junegunn/fzf|fzf --version'
  'aqua:ajeetdsouza/zoxide|zoxide --version'
  'aqua:kubernetes/kubernetes/kubectl|kubectl version --client'
  'aqua:helm/helm|helm version --short'
  'aqua:helmfile/helmfile|helmfile --version'
  'aqua:derailed/k9s|k9s version --short'
  'aqua:argoproj/argo-cd|argocd version --client --short'
  'aqua:siderolabs/talos|talosctl version --client --short'
  'aqua:ahmetb/kubectx|kubectx -h'
  'aqua:ahmetb/kubectx/kubens|kubens -h'
  'aqua:jqlang/jq|jq --version'
  'aqua:mikefarah/yq|yq --version'
  'github:sharkdp/fd|fd --version'
  'aqua:BurntSushi/ripgrep|rg --version'
  'github:sharkdp/bat|bat --version'
  'aqua:mr-karan/doggo|doggo --version'
  'aqua:ducaale/xh|xh --version'
  'aqua:fullstorydev/grpcurl|grpcurl --version'
  'aqua:vi/websocat|websocat --version'
  'aqua:smallstep/cli|step version'
  'aqua:stern/stern|stern --version'
  'github:fujiapple852/trippy|trip --version'
  'aqua:go-task/task|task --version'
  'aqua:getsops/sops|sops --version --disable-version-check'
  'aqua:FiloSottile/age|age --version'
  'aqua:micro-editor/micro|micro -version'
)
for entry in "${tool_cmds[@]}"; do
  key="${entry%%|*}"
  cmd="${entry#*|}"
  case "$key" in
    github:*)
      # The github backend takes the first asset that fits, which is the glibc
      # build here; the pattern has to ask for the musl one.
      assert_ok "config pins $key to a musl asset" -- \
        grep -Eq "^\"$key\" = \{ version = \"[0-9][0-9.]*\", asset_pattern = \"[^\"]*x86_64-unknown-linux-musl[^\"]*\" \}$" "$cfg"
      ;;
    *) assert_ok "config pins $key" -- grep -Eq "^\"$key\" = \"[0-9][0-9.]*\"$" "$cfg" ;;
  esac
  assert_ok "$cmd runs" -- bash -lc "$cmd"
done
assert_eq "$(grep -Ec '^"(aqua|github):' "$cfg")" "${#tool_cmds[@]}" "this test covers every tool in the config"
assert_eq "$(bash -lc 'zoxide --version')" "zoxide 0.10.0" "zoxide is the pinned version"
# helm stays on 3.x on purpose (the charts, plugins and GitOps repos in use are
# helm 3): moving to 4 has to be a decision, not a side effect of a bump.
assert_ok "config pins helm to 3.x" -- grep -Eq '^"aqua:helm/helm" = "3\.[0-9.]+"$' "$cfg"
assert_ok "helm reports a v3 release" -- bash -lc 'helm version --short | grep -Eq "^v3\."'
assert_eq "$(wc -l <"$HOME/.config/dotfiles/mise-installs" | tr -d ' ')" "${#tool_cmds[@]}" "every install is recorded"
# Our mise config is a conf.d fragment; config.toml stays the user's (mise writes there).
assert_symlink "$HOME/.config/mise/conf.d/dotfiles.toml" "$HOME/.dotfiles/config/mise/config.toml"
assert_file_absent "$HOME/.config/mise/config.toml"
assert_eq "$(bash -lc 'echo ok' 2>&1)" ok "login shell stays silent with tools installed"
assert_eq "$(bash -c '. ~/.bashrc; echo ok' 2>&1)" ok "ssh-like shell stays silent with tools installed"

# case_tools_are_static_or_musl: none of them may depend on the glibc of the host
# (the config says so, and the oldest host has the oldest glibc). A tool with no
# interpreter is static; otherwise the interpreter has to be musl's.
for entry in "${tool_cmds[@]}"; do
  cmd="${entry#*|}"
  tool="${cmd%% *}"
  bin="$(bash -lc "mise which $tool")"
  assert_ok "$tool resolves to a file" -- test -f "$bin"
  interp="$(elf_interp "$bin")"
  case "$interp" in
    '' | *musl*) ;;
    *) _fail "$tool is not static or musl: $bin wants $interp" ;;
  esac
done


# case_zsh_bin: only the row without a system zsh gets one, in ~/.local.
case "$DF_ROW" in
  u20-nozsh)
    assert_ok "zsh-bin lands in ~/.local/bin" -- test -x "$HOME/.local/bin/zsh"
    assert_ok "zsh-bin runs" -- "$HOME/.local/bin/zsh" -fc 'exit 0'
    assert_ok "zsh-bin is recorded as ours" -- grep -qx zsh-bin "$HOME/.config/dotfiles/tools"
    ;;
  *)
    assert_file_absent "$HOME/.local/bin/zsh"
    assert_fail "system zsh is not recorded as ours" -- grep -qx zsh-bin "$HOME/.config/dotfiles/tools"
    ;;
esac
zsh_bin="$(PATH="$HOME/.local/bin:$PATH" command -v zsh)"
assert_ok "a usable zsh exists" -- "$zsh_bin" -fc 'exit 0'

# case_starship_prod_is_red
fx="$(mktemp -d)"
kubeconfig() { # <file> <context>
  printf 'apiVersion: v1\nkind: Config\ncurrent-context: %s\ncontexts:\n- context:\n    cluster: c\n    namespace: argocd\n    user: u\n  name: %s\n' "$2" "$2" >"$1"
}
kubeconfig "$fx/prod" gke-prod
kubeconfig "$fx/upper" GKE-PROD-1
kubeconfig "$fx/dev" homelab
prompt_of() { KUBECONFIG="$1" bash -lc 'starship prompt' 2>&1; }
# Either spelling of bold red; fixed strings, because "[" would be a bracket expression.
red1="$(printf '\033[1;31m')"
red2="$(printf '\033[31;1m')"
out="$(prompt_of "$fx/prod")"
assert_ok "prod context is bold red" -- grep -aqF -e "$red1" -e "$red2" <<<"$out"
assert_ok "prompt shows context/namespace" -- grep -aFq 'gke-prod/argocd' <<<"$out"
assert_ok "prod in any case is red" -- grep -aqF -e "$red1" -e "$red2" <<<"$(prompt_of "$fx/upper")"
out="$(prompt_of "$fx/dev")"
assert_fail "non-prod context is not red" -- grep -aqF -e "$red1" -e "$red2" <<<"$out"
assert_ok "non-prod context is shown" -- grep -aFq 'homelab/argocd' <<<"$out"
assert_fail "starship reports no config problem" -- grep -aqi 'warn\|error' <<<"$out"

# case_interactive_shells
# Interactive shells need a terminal (fzf only loads with one), so run them on a pty.
pty() { timeout 60 script -qec "$1" /dev/null </dev/null | tr -d '\r'; }
zsh_i() { pty "TERM=xterm-256color $zsh_bin -i -c '$1'"; }
bash_i() { pty "DOTFILES_IN_ZSH=1 TERM=xterm-256color bash -i -c '$1'"; }
assert_eq "$(zsh_i exit)" "" "interactive zsh prints nothing"
assert_ok "zsh prompt comes from starship" -- grep -q starship <<<"$(zsh_i 'print -r -- $PROMPT')"
assert_ok "zsh Ctrl-R is fzf" -- grep -q fzf-history-widget <<<"$(zsh_i 'bindkey "^R"')"
assert_ok "zsh runs tools from the mise install, not the slow shim" -- \
  grep -q '/installs/' <<<"$(zsh_i 'print -r -- ${commands[kubectl]}')"
assert_ok "bash prompt comes from starship" -- \
  grep -q starship_precmd <<<"$(bash_i 'echo "$PROMPT_COMMAND"')"
assert_ok "bash Ctrl-R is fzf" -- \
  grep -q function <<<"$(bash_i 'type -t __fzf_history__')"
assert_eq "$(bash_i 'type -t mise')" function "bash activates mise"
assert_eq "$(bash_i 'true')" "" "interactive bash prints nothing"

# case_zoxide_fzf_tab_and_k: the shell additions that need the real tools.
# zoxide: `z` and `zi` are functions, cd is left alone.
assert_eq "$(zsh_i 'whence -w z zi cd')" "z: function
zi: function
cd: builtin" "zsh: z and zi come from zoxide, cd stays the builtin"
assert_eq "$(bash_i 'type -t z zi' | tr '\n' ' ')" "function function " "bash: z and zi come from zoxide"
assert_fail "bash: cd is not replaced by zoxide" -- grep -q zoxide <<<"$(bash_i 'declare -f cd')"
assert_ok "the zoxide init script is cached" -- grep -q '^# df-init bin=.*/zoxide$' "$HOME/.cache/dotfiles/init/zoxide-zsh"
# fzf-tab is loaded after compinit and before autosuggestions and fzf's bindings.
# Those save the widget behind Tab as fzf_default_completion, which must be
# fzf-tab's, so that plain Tab goes to fzf-tab and `**<Tab>` still opens fzf.
assert_eq "$(zsh_load_order "$(pty "TERM=xterm-256color $zsh_bin -i -x -c exit")")" "compinit fzf-tab autosuggestions tools" "load order: compinit, fzf-tab, autosuggestions, tools.sh (fzf)"
assert_eq "$(zsh_i 'print -r -- $+functions[fzf-tab-complete]')" 1 "fzf-tab is loaded"
assert_eq "$(zsh_i 'bindkey "^I"')" '"^I" fzf-completion' "Tab is fzf's completion widget"
assert_eq "$(zsh_i 'print -r -- $fzf_default_completion')" fzf-tab-complete "which falls back to fzf-tab, not to the stock widget"
assert_eq "$(zsh_i 'zstyle -L ":completion:*" menu')" "zstyle ':completion:*' menu no" "fzf-tab sees the whole list: no zsh menu"
assert_eq "$(zsh_i 'print -r -- ${_comps[kubectl]}')" "_kubectl" "kubectl completion is known"
# k is kubectl, with kubectl's completion.
assert_eq "$(zsh_i 'alias k')" "k=kubectl" "zsh: k is an alias of kubectl"
assert_eq "$(zsh_i 'print -r -- ${_comps[k]}')" "_kubectl" "zsh: k completes like kubectl"
assert_eq "$(bash_i 'type -t k')" alias "bash: k is an alias"
assert_eq "$(bash_i 'alias k')" "alias k='kubectl'" "bash: k is an alias of kubectl"
assert_eq "$(zsh_i 'exit')" "" "interactive zsh still prints nothing"
assert_eq "$(bash_i 'true')" "" "interactive bash still prints nothing"

# case_completions
for t in kubectl helm k9s argocd talosctl task mise; do
  assert_ok "completion generated for $t" -- grep -q '^#compdef' "$HOME/.cache/zsh/completions/_$t"
done
assert_eq "$(zsh_i 'print -r -- ${_comps[kubectl]}')" "_kubectl" "zsh knows the kubectl completion"
assert_eq "$(zsh_i 'print -r -- ${_comps[task]}')" "_task" "zsh knows the task completion"

# case_completion_change_drops_the_zsh_dump: compinit -C never refreshes, so the
# installer must delete the dump when the completion set changes, and only then.
printf 'x\n' >"$HOME/.cache/zsh/zcompdump"
install_server
assert_ok "unchanged completions keep the dump" -- test -e "$HOME/.cache/zsh/zcompdump"
rm -f "$HOME/.cache/zsh/completions/_kubectl"
install_server
assert_ok "a changed completion set regenerates the file" -- grep -q '^#compdef' "$HOME/.cache/zsh/completions/_kubectl"
# The doctor at the end of the install starts a zsh, which writes a fresh dump:
# what must be gone is the old one.
assert_fail "a changed completion set drops the old zsh dump" -- grep -qx x "$HOME/.cache/zsh/zcompdump"
assert_eq "$(wc -l <"$HOME/.config/dotfiles/mise-installs" | tr -d ' ')" "${#tool_cmds[@]}" "a second install records nothing twice"
assert_eq "$(zsh_i 'print -r -- ${_comps[kubectl]}')" "_kubectl" "the rebuilt dump knows kubectl"

# case_docker_completion_in_the_install: a docker of the host (a stub here) is
# completed by the install like our own tools, and its file goes with the binary.
printf '#!/bin/sh\nprintf "#compdef docker\n_docker() { :; }\n"\n' >"$HOME/.local/bin/docker"
chmod +x "$HOME/.local/bin/docker"
install_server
assert_ok "the install generates the docker completion" -- grep -q '^#compdef docker' "$HOME/.cache/zsh/completions/_docker"
assert_eq "$(zsh_i 'print -r -- ${_comps[docker]}')" "_docker" "zsh knows the docker completion after the install"
rm -f "$HOME/.local/bin/docker"
install_server
assert_file_absent "$HOME/.cache/zsh/completions/_docker"
assert_eq "$(zsh_i 'print -r -- ${+_comps[docker]}')" "0" "and forgets it when docker is gone"

# case_zsh_startup_median: warm up once (init caches, dump), then 10 starts.
zsh_i exit >/dev/null
times=()
for _ in 1 2 3 4 5 6 7 8 9 10; do
  s=$(date +%s%N)
  zsh_i exit >/dev/null
  times+=($(( ($(date +%s%N) - s) / 1000000 )))
done
median="$(printf '%s\n' "${times[@]}" | sort -n | sed -n 5p)"
printf 'zsh -i startup ms: %s (median %s)\n' "${times[*]}" "$median" >&2
assert_ok "zsh startup median ${median}ms < 300ms" -- test "$median" -lt 300

# case_doctor_finds_the_real_tools: the doctor's command list (config/mise/commands.*)
# against what mise really installed. Only the tool lines are asserted here: the
# other checks depend on the host (packages, ping, zsh) and are covered by 60-cli.sh.
doctor_out="$("$HOME/.local/bin/dotfiles" doctor 2>&1 || true)"
echo "$doctor_out" >&2
assert_ok "doctor reports the tools" -- grep -Eq '^OK +tools: all [0-9]+ found' <<<"$doctor_out"
# grep -E: in a basic regular expression "+" is a literal, which made the old
# pattern match nothing. The sanity line proves the pattern can see a FAIL.
assert_eq "$(printf 'FAIL tool: x not found\n' | grep -cE '^FAIL +tool' || true)" 1 "the FAIL pattern matches a FAIL line"
assert_eq "$(grep -cE '^FAIL +tool' <<<"$doctor_out" || true)" 0 "doctor finds every real tool"

# --- case_purge_removes_what_was_installed ------------------------------------------
# Running the tools above made state of their own (k9s state, starship cache);
# that is the user's, not the installer's, and the test clears it so the listing
# below sees only what the install created.
rm -rf "$HOME/.local/state/k9s" "$HOME/.cache/starship"
# The zoxide database is the user's, like the shell history: a purge keeps it.
mkdir -p "$HOME/.local/share/zoxide"
printf 'db\n' >"$HOME/.local/share/zoxide/db.zo"
# Not a list of paths we know about: everything the install created, including
# what the tools themselves create on the side (k9s state, the sigstore cache),
# must be gone, so the home tree equals the one before the first install.
bash "$HOME/.dotfiles/uninstall.sh" --purge >/dev/null 2>&1
assert_eq "$(cat "$HOME/.local/share/zoxide/db.zo" 2>/dev/null)" db "purge keeps the zoxide database"
rm -rf "$HOME/.local/share/zoxide"
# The directories that held it (the purge could not remove them) go too, unless
# they existed before the install.
for d in .local/share .local; do
  grep -qx "./$d" <<<"$tree_before" || rmdir "$HOME/$d" 2>/dev/null || true
done
assert_eq "$(tree_of)" "$tree_before" "purge restores the home tree of before the first install"
assert_fail "no zcompdump left" -- bash -c 'ls ~/.cache/zsh/zcompdump* 2>/dev/null | grep -q .'
assert_eq "$(bash -lc 'command -v kubectl || echo none')" none "no kubectl after purge"

# --- small tool set -------------------------------------------------------------------
# The downgrade and isolation scenarios do not need 19 tools, only some. They
# run the real installer from a copy of the repo whose mise config lists three
# (about 70 MB), so the full download happens once per row.
small_src="$(mktemp -d)"
cp -a /src/. "$small_src/"
cat >"$small_src/config/mise/config.toml" <<'TOML'
[settings]
download_cache = false

[tools]
"github:starship/starship" = { version = "1.27.0", asset_pattern = "*x86_64-unknown-linux-musl.tar.gz" }
"aqua:junegunn/fzf" = "0.75.0"
"aqua:kubernetes/kubernetes/kubectl" = "1.37.2"
TOML
# The install ends with the doctor, which expects every command of the profile's
# list: the copy lists the three tools it installs.
printf 'starship github:starship/starship\nfzf aqua:junegunn/fzf\nkubectl aqua:kubernetes/kubernetes/kubectl\n' >"$small_src/config/mise/commands.server"
small_install() { DOTFILES_SRC="$small_src" bash "$small_src/install.sh" "$@"; }
install_small() {
  small_install --profile server >"$log" 2>&1 || { cat "$log" >&2; _fail "small install.sh --profile server failed"; }
}

# What a downgrade to minimal must leave: no tool on PATH, no link to the mise or
# starship configuration, nothing of what the installer downloaded or generated.
assert_downgraded() { # <scenario>
  assert_file_absent "$HOME/.config/mise/conf.d/dotfiles.toml"
  assert_file_absent "$HOME/.config/starship.toml"
  assert_eq "$(bash -lc 'command -v kubectl || echo none')" none "$1: kubectl is gone from PATH"
  assert_eq "$(bash -lc 'command -v starship || echo none')" none "$1: starship is gone from PATH"
  for p in .local/bin/mise .local/bin/zsh .local/share/mise .local/state/mise .cache/mise \
           .cache/zsh/completions .cache/dotfiles/init .config/dotfiles/tools .config/dotfiles/mise-installs \
           .config/dotfiles/zsh-bin-files; do
    assert_file_absent "$HOME/$p"
  done
  # The doctor at the end of the install starts a zsh, which writes a dump again;
  # it must not know the completions that were taken away.
  assert_fail "$1: no kubectl completion in the zsh dump" -- grep -q kubectl "$HOME/.cache/zsh/zcompdump"
  assert_eq "$(cat "$HOME/.config/dotfiles/profile")" minimal "$1: profile is minimal again"
  assert_ok "$1: minimal links are still in place" -- test -L "$HOME/.bashrc"
  assert_eq "$(bash -c '. ~/.bashrc; echo ok' 2>&1)" ok "$1: shell works after the downgrade"
}

# --- case_mise_install_only_our_config ------------------------------------------------
# Whatever else mise would read must neither be installed nor recorded as ours:
# ~/.tool-versions, ~/mise.toml (not even trusted), conf.d next to our config,
# and the system config (redirected into a scratch dir; the test user cannot write /etc).
sys_cfg="$(mktemp -d)"
printf '[tools]\n"aqua:FiloSottile/age" = "1.3.2"\n' >"$sys_cfg/config.toml"
printf 'jq 1.8.2\n' >"$HOME/.tool-versions"
printf '[tools]\n"aqua:FiloSottile/age" = "1.3.2"\n' >"$HOME/mise.toml"
mkdir -p "$HOME/.config/mise/conf.d"
printf '[tools]\n"aqua:mikefarah/yq" = "4.54.3"\n' >"$HOME/.config/mise/conf.d/extra.toml"
# The user's own global config (what `mise use -g` writes) is not ours either.
printf '[tools]\n"aqua:BurntSushi/ripgrep" = "15.2.0"\n' >"$HOME/.config/mise/config.toml"
t0=$(date +%s)
MISE_SYSTEM_CONFIG_DIR="$sys_cfg" install_small
printf 'small server install took %ss\n' "$(( $(date +%s) - t0 ))" >&2
assert_ok "kubectl is installed from our config" -- bash -lc 'command -v kubectl'
assert_eq "$(find "$HOME/.local/share/mise/installs" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" \
  "aqua-junegunn-fzf aqua-kubernetes-kubernetes-kubectl github-starship-starship " "only our three tools are installed"
assert_eq "$(wc -l <"$HOME/.config/dotfiles/mise-installs" | tr -d ' ')" 3 "only our three installs are recorded"
assert_fail "no foreign tool is recorded" -- grep -Eq 'jq|age/|yq|ripgrep' "$HOME/.config/dotfiles/mise-installs"
assert_eq "$(cat "$HOME/.config/mise/config.toml")" "$(printf '[tools]\n"aqua:BurntSushi/ripgrep" = "15.2.0"')" "the user's global config is unchanged by the install"

# --- case_profile_downgrade_to_minimal, with --no-tools -------------------------------
# A prod host that got "server" by mistake: going back to minimal must leave no
# tool on PATH even when the downgrade is run with DOTFILES_NO_TOOLS=1 (it only
# gates downloads). Files that are not ours stay.
DOTFILES_NO_TOOLS=1 small_install --profile minimal >/dev/null 2>&1
assert_downgraded "NO_TOOLS downgrade"
assert_eq "$(cat "$HOME/.tool-versions")" "jq 1.8.2" "the user's ~/.tool-versions is untouched"
assert_ok "the user's ~/mise.toml is untouched" -- test -f "$HOME/mise.toml"
assert_ok "the user's conf.d file is untouched" -- test -f "$HOME/.config/mise/conf.d/extra.toml"
assert_ok "the user's global mise config is untouched" -- grep -q ripgrep "$HOME/.config/mise/config.toml"
rm -rf "$HOME/.tool-versions" "$HOME/mise.toml" "$HOME/.config/mise"

# --- case_profile_downgrade_to_minimal ------------------------------------------------
install_small
assert_ok "kubectl is there before the downgrade" -- bash -lc 'command -v kubectl'
small_install --profile minimal >/dev/null 2>&1
assert_downgraded "plain downgrade"

# --- case_mise_use_g_writes_to_the_user_config -------------------------------------------
# `mise use -g` and `mise set -g` write into ~/.config/mise/config.toml. That
# file is the user's: the repo file behind conf.d/dotfiles.toml must not change
# (an update would lose the edit, and a token could end up in a public repo), the
# tools added that way are not ours to record, and a purge keeps them.
install_small
repo_cfg="$HOME/.dotfiles/config/mise/config.toml"
user_cfg="$HOME/.config/mise/config.toml"
repo_sum="$(sha256sum <"$repo_cfg")"
bash -lc 'mise use -g aqua:FiloSottile/age@1.3.1' >"$log" 2>&1 || { cat "$log" >&2; _fail "mise use -g failed"; }
bash -lc 'mise set -g DF_TEST_TOKEN=not-a-real-token' >"$log" 2>&1 || { cat "$log" >&2; _fail "mise set -g failed"; }
assert_ok "mise use -g wrote the user's config" -- grep -q 'FiloSottile/age' "$user_cfg"
assert_ok "mise set -g wrote the user's config" -- grep -q 'DF_TEST_TOKEN' "$user_cfg"
assert_ok "the user's config is a real file" -- test -f "$user_cfg" -a ! -L "$user_cfg"
assert_eq "$(sha256sum <"$repo_cfg")" "$repo_sum" "the repo file is untouched by mise use -g and mise set -g"
assert_ok "our fragment is still a link into the checkout" -- test -L "$HOME/.config/mise/conf.d/dotfiles.toml"
assert_fail "the tool the user added is not recorded as ours" -- grep -qi 'age' "$HOME/.config/dotfiles/mise-installs"
age_bin="$(bash -lc 'mise which age')"
assert_ok "the user's tool runs" -- "$age_bin" --version
user_sum="$(sha256sum <"$user_cfg")"
install_small
assert_eq "$(sha256sum <"$user_cfg")" "$user_sum" "an update leaves the user's config alone"
assert_fail "and still does not record the user's tool" -- grep -qi 'age' "$HOME/.config/dotfiles/mise-installs"
assert_ok "our tools are still found" -- bash -lc 'command -v kubectl'
bash "$HOME/.dotfiles/uninstall.sh" --purge >"$log" 2>&1 || { cat "$log" >&2; _fail "purge failed"; }
assert_ok "purge keeps the tool the user installed" -- "$age_bin" --version
assert_ok "purge keeps the user's config" -- grep -q 'FiloSottile/age' "$user_cfg"
assert_file_absent "$HOME/.config/mise/conf.d/dotfiles.toml"
assert_file_absent "$HOME/.local/bin/mise"
assert_eq "$(find "$HOME/.local/share/mise/installs" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f\n' | grep -vci age || true)" 0 "purge removed every install of ours"
rm -rf "$HOME/.local/share/mise" "$HOME/.local/state/mise" "$HOME/.cache/mise" "$HOME/.cache/sigstore-rust" "$HOME/.config/mise"
