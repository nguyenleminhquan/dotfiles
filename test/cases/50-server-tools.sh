# Profile server: zsh-bin where needed, the pinned mise tools, starship,
# fzf, completions, and the way back to minimal. Server rows download for real
# (twice: one full install is purged, one is downgraded); minimal rows run
# offline and only prove that nothing tool-related appears.
# SC2016: the zsh and bash snippets are meant to be expanded by the shell under test.
# SC2030/SC2031: HOME is changed in subshells on purpose.
# shellcheck disable=SC2016,SC2030,SC2031
cfg=/src/config/mise/config.toml

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

  # Recorded: mise itself and a data directory that did not exist before.
  printf 'mise-bin\nmise-data\n' >"$state/tools"
  df_tools_remove >/dev/null 2>&1
  assert_file_absent "$fx/.local/bin/mise"
  assert_file_absent "$fx/.local/share/mise"
  assert_file_absent "$state/tools"

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
log="$(mktemp)"
install_server() {
  bash /src/install.sh --profile server >"$log" 2>&1 || { cat "$log" >&2; _fail "install.sh --profile server failed"; }
}
t0=$(date +%s)
install_server
printf 'full server install took %ss\n' "$(( $(date +%s) - t0 ))" >&2

# case_tools_run: every tool of the config runs here (u20-* has glibc 2.31),
# found through the login shell's PATH like a real session would.
tool_cmds=(
  'aqua:starship/starship|starship --version'
  'aqua:junegunn/fzf|fzf --version'
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
  'aqua:sharkdp/fd|fd --version'
  'aqua:BurntSushi/ripgrep|rg --version'
  'aqua:sharkdp/bat|bat --version'
  'aqua:go-task/task|task --version'
  'aqua:getsops/sops|sops --version --disable-version-check'
  'aqua:FiloSottile/age|age --version'
  'aqua:micro-editor/micro|micro -version'
)
for entry in "${tool_cmds[@]}"; do
  key="${entry%%|*}"
  cmd="${entry#*|}"
  assert_ok "config pins $key" -- grep -Eq "^\"$key\" = \"[0-9][0-9.]*\"$" "$cfg"
  assert_ok "$cmd runs" -- bash -lc "$cmd"
done
assert_eq "$(grep -c '^"aqua:' "$cfg")" "${#tool_cmds[@]}" "this test covers every tool in the config"
assert_eq "$(wc -l <"$HOME/.config/dotfiles/mise-installs" | tr -d ' ')" "${#tool_cmds[@]}" "every install is recorded"
assert_symlink "$HOME/.config/mise/config.toml" "$HOME/.dotfiles/config/mise/config.toml"
assert_eq "$(bash -lc 'echo ok' 2>&1)" ok "login shell stays silent with tools installed"
assert_eq "$(bash -c '. ~/.bashrc; echo ok' 2>&1)" ok "ssh-like shell stays silent with tools installed"

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
assert_file_absent "$HOME/.cache/zsh/zcompdump"
assert_eq "$(wc -l <"$HOME/.config/dotfiles/mise-installs" | tr -d ' ')" "${#tool_cmds[@]}" "a second install records nothing twice"
assert_eq "$(zsh_i 'print -r -- ${_comps[kubectl]}')" "_kubectl" "the rebuilt dump knows kubectl"

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

# --- case_purge_removes_what_was_installed ------------------------------------------
bash "$HOME/.dotfiles/uninstall.sh" --purge >/dev/null 2>&1
for p in .local/bin/mise .local/bin/zsh .local/share/mise .local/state/mise .cache/mise \
         .cache/zsh/completions .cache/dotfiles/init .config/mise .config/starship.toml \
         .config/dotfiles .dotfiles; do
  assert_file_absent "$HOME/$p"
done
assert_fail "no zcompdump left" -- bash -c 'ls ~/.cache/zsh/zcompdump* 2>/dev/null | grep -q .'
assert_eq "$(bash -lc 'command -v kubectl || echo none')" none "no kubectl after purge"

# --- case_profile_downgrade_to_minimal -----------------------------------------------
# A prod host that got "server" by mistake: going back to minimal must leave no
# tool on PATH and no link to the mise or starship configuration.
install_server
assert_ok "kubectl is there before the downgrade" -- bash -lc 'command -v kubectl'
bash /src/install.sh --profile minimal >/dev/null 2>&1
assert_file_absent "$HOME/.config/mise/config.toml"
assert_file_absent "$HOME/.config/starship.toml"
assert_eq "$(bash -lc 'command -v kubectl || echo none')" none "kubectl is gone from PATH"
assert_eq "$(bash -lc 'command -v starship || echo none')" none "starship is gone from PATH"
for p in .local/bin/mise .local/bin/zsh .local/share/mise .local/state/mise .cache/mise \
         .cache/zsh/completions .cache/dotfiles/init .config/dotfiles/tools .config/dotfiles/mise-installs \
         .config/dotfiles/zsh-bin-files; do
  assert_file_absent "$HOME/$p"
done
assert_fail "no zcompdump left" -- bash -c 'ls ~/.cache/zsh/zcompdump* 2>/dev/null | grep -q .'
assert_eq "$(cat "$HOME/.config/dotfiles/profile")" minimal "profile is minimal again"
assert_ok "minimal links are still in place" -- test -L "$HOME/.bashrc"
assert_eq "$(bash -c '. ~/.bashrc; echo ok' 2>&1)" ok "shell works after the downgrade"
