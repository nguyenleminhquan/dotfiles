# Interactive shell: history secret filter, kube-aware prompt, aliases and
# the app configs (git, micro, screen). Unit-style checks source the repo files
# from /src; the end-to-end ones use the installed setup on a pty.
/src/install.sh --profile "$DF_PROFILE" >/dev/null 2>&1

has_zsh=0
command -v zsh >/dev/null && has_zsh=1
has_git=0
command -v git >/dev/null && has_git=1

# Secrets are assembled at runtime so no committed literal looks like one.
rep() { local i out=''; for ((i = 0; i < $2; i++)); do out+=$1; done; printf '%s' "$out"; }
fake_ghp="ghp_$(rep a 36)"
fake_akia="AKIA$(rep A 16)"
fake_glpat="glpat-$(rep b 20)"

# --- case_history_filter -----------------------------------------------------
. /src/shell/history.sh
for s in 'echo -----BEGIN CERTIFICATE-----' 'export TOKEN=abc' 'curl -H "Authorization: Bearer x" u' \
         "aws $fake_akia" "git push https://$fake_ghp@github.com/x" \
         "git clone https://oauth2:$fake_glpat@gitlab.example/x" \
         'mysql --password=hunter2' 'PASSWD=x ./run' 'export Api_Key=x' 'curl --api-key=x u' 'SECRET=x cmd' \
         'curl -H "authorization: Bearer x" u' $'echo a\nexport TOKEN=abc'; do
  assert_ok "secret: $s" -- df_history_is_secret "$s"; done
for s in 'kubectl create token sa' 'kubectl get secret -n x' 'task --list' 'echo password' \
         'kubectl create token sa --duration 1h' 'echo ghp_short' 'echo AKIAshort' 'ls api-key' \
         'token = 1'; do
  assert_fail "not secret: $s" -- df_history_is_secret "$s"; done

# --- case_prompt_kubeconfig_edge ---------------------------------------------
. /src/shell/prompt-minimal.sh
unset KUBECONFIG; rm -rf ~/.kube
assert_eq "$(df_kube_context)" "" "no kubeconfig → empty"
assert_eq "$(df_kube_context 2>&1; echo rc=$?)" "rc=0" "no kubeconfig → no output, exit 0"
mkdir -p ~/.kube; printf 'apiVersion: v1\nkind: Config\n' > ~/.kube/a
printf 'current-context: gke-prod\ncontexts:\n- name: gke-prod\n  context:\n    namespace: argocd\n' > ~/.kube/b
KUBECONFIG=~/.kube/a:~/.kube/b; assert_eq "$(df_kube_context)" "gke-prod" "first file with current-context"
assert_eq "$(df_kube_namespace gke-prod)" "argocd" "namespace parsed"
assert_ok "prod detected" -- df_kube_is_prod gke-prod
assert_ok "prod detected, any case" -- df_kube_is_prod GKE-PROD-1
assert_fail "non-prod" -- df_kube_is_prod homelab

# the first file that has the field wins, even when later files differ
printf 'current-context: other\n' > ~/.kube/c
KUBECONFIG=~/.kube/a:~/.kube/c:~/.kube/b; assert_eq "$(df_kube_context)" "other" "first current-context wins"
KUBECONFIG=/nonexistent/x:~/.kube/b; assert_eq "$(df_kube_context)" "gke-prod" "missing file in the list is skipped"
KUBECONFIG=:~/.kube/b:; assert_eq "$(df_kube_context)" "gke-prod" "empty list entries are skipped"
KUBECONFIG=~/.kube; assert_eq "$(df_kube_context 2>&1; echo rc=$?)" "rc=0" "a directory is not a kubeconfig"
KUBECONFIG=; rm -f ~/.kube/config
assert_eq "$(df_kube_context)" "" "empty KUBECONFIG and no default file"
printf 'current-context: "quoted-ctx"   \n' > ~/.kube/config
assert_eq "$(df_kube_context)" "quoted-ctx" "empty KUBECONFIG falls back to ~/.kube/config; quotes stripped"
unset KUBECONFIG; assert_eq "$(df_kube_context)" "quoted-ctx" "unset KUBECONFIG uses ~/.kube/config"
printf 'current-context: ""\n' > ~/.kube/config
assert_eq "$(df_kube_context)" "" "empty current-context value counts as none"

# namespace: kubectl's own layout puts `context:` before `name:`; default when unset
cat > ~/.kube/config <<'EOF'
apiVersion: v1
clusters:
- cluster:
    server: https://example.invalid
  name: c1
contexts:
- context:
    cluster: c1
    user: u1
  name: homelab
- context:
    cluster: c1
    namespace: kube-system
    user: u1
  name: ops
current-context: ops
kind: Config
users:
- name: ops
  user:
    token: x
EOF
unset KUBECONFIG
assert_eq "$(df_kube_context)" "ops" "kubectl-style file"
assert_eq "$(df_kube_namespace ops)" "kube-system" "namespace, context before name"
assert_eq "$(df_kube_namespace homelab)" "default" "namespace defaults to default"
assert_eq "$(df_kube_namespace nosuch)" "default" "unknown context defaults to default"
assert_eq "$(df_kube_namespace)" "default" "no context argument defaults to default"

# the prompt segment never runs kubectl and costs nothing without a kubeconfig
fx="$(mktemp -d)"; mkdir "$fx/bin"
printf '#!/bin/sh\ntouch "%s/kubectl-ran"\n' "$fx" >"$fx/bin/kubectl"; chmod +x "$fx/bin/kubectl"
PATH="$fx/bin:$PATH" _df_kube_segment
assert_eq "$_df_kube_label" "ops/kube-system" "segment label"
assert_eq "$_df_kube_prod" "0" "segment not prod"
printf 'current-context: GKE-Prod\n' > ~/.kube/config
PATH="$fx/bin:$PATH" _df_kube_segment
assert_eq "$_df_kube_label" "GKE-Prod/default" "segment label with default namespace"
assert_eq "$_df_kube_prod" "1" "segment prod"
assert_file_absent "$fx/kubectl-ran"
rm -rf ~/.kube; unset KUBECONFIG
_df_kube_segment
assert_eq "$_df_kube_label" "" "segment empty without kubeconfig"
assert_eq "$_df_kube_prod" "0" "segment not prod without kubeconfig"
t0=$(date +%s%N)
for _ in $(seq 50); do _df_kube_segment; done
assert_ok "50 prompts without kubeconfig take < 1s" -- test $(( ($(date +%s%N) - t0) / 1000000 )) -lt 1000
# characters that could change the prompt are neutralised
mkdir ~/.kube; printf 'current-context: x$(touch %s/pwned)\\u%%F{red}\n' "$fx" >~/.kube/config
_df_kube_segment
case "$_df_kube_label" in *'$'* | *'('* | *'\'* | *'%'*) _fail "label keeps prompt metacharacters: $_df_kube_label" ;; esac
rm -rf ~/.kube

# --- case_aliases_and_editor -------------------------------------------------
assert_eq "$(DOTFILES_IN_ZSH=1 bash -ic 'alias k t ll' 2>/dev/null </dev/null)" \
"alias k='kubectl'
alias t='task'
alias ll='ls -alhF --color=auto'" "bash has the aliases"
if [ "$has_zsh" = 1 ]; then
  assert_eq "$(zsh -ic 'alias k t ll' 2>/dev/null </dev/null)" \
"k=kubectl
t=task
ll='ls -alhF --color=auto'" "zsh has the aliases"
fi
fx="$(mktemp -d)"; mkdir "$fx/bin"
bash_bin="$(command -v bash)"
editor_for() { env PATH="$fx/bin" "$bash_bin" -c '. /src/shell/aliases.sh; echo "$EDITOR:$VISUAL"'; }
assert_eq "$(editor_for)" "vi:vi" "EDITOR falls back to vi"
printf '#!/bin/sh\n' >"$fx/bin/nano"; chmod +x "$fx/bin/nano"
assert_eq "$(editor_for)" "nano:nano" "EDITOR prefers nano over vi"
printf '#!/bin/sh\n' >"$fx/bin/micro"; chmod +x "$fx/bin/micro"
assert_eq "$(editor_for)" "micro:micro" "EDITOR prefers micro"
assert_eq "$(env PATH="$fx/bin" "$bash_bin" -c '. /src/shell/aliases.sh; export -p' | grep -c -E 'declare -x (EDITOR|VISUAL)=')" "2" "EDITOR and VISUAL exported"
rm -rf "$fx"

# --- case_app_configs --------------------------------------------------------
gitcfg=/src/config/git/config
assert_ok "git config includes the local identity file" -- grep -Eq '^[[:space:]]*path[[:space:]]*=[[:space:]]*~/\.gitconfig\.local' "$gitcfg"
assert_fail "git config carries no identity" -- grep -Eiq '^[[:space:]]*(name|email|signingkey|user)[[:space:]]*(=|$)|\[user\]|\[credential' "$gitcfg"
if [ "$has_git" = 1 ]; then
  g() { git config --file "$gitcfg" --get "$1"; }
  assert_eq "$(g core.editor)" "micro" "core.editor"
  assert_eq "$(g push.default)" "simple" "push.default"
  assert_eq "$(g init.defaultBranch)" "main" "init.defaultBranch"
  assert_eq "$(g include.path)" "~/.gitconfig.local" "include.path"
  assert_eq "$(g alias.s)" "status" "alias s"
  assert_eq "$(g alias.st)" "status" "alias st"
  assert_eq "$(g alias.stu)" "status --untracked-files=no" "alias stu"
  assert_eq "$(g alias.ci)" "commit" "alias ci"
  assert_eq "$(g alias.cim)" "commit --message" "alias cim"
  assert_eq "$(g alias.cima)" "commit --all --message" "alias cima"
  assert_eq "$(g alias.type)" "cat-file -t" "alias type"
  assert_eq "$(g alias.dump)" "cat-file -p" "alias dump"
  assert_eq "$(g alias.la)" '!git config -l | grep alias | cut -c 7-' "alias la"
  assert_eq "$(g alias.ec)" "config --global -e" "alias ec"
  # through the installed link, with an identity in the include file
  printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n' >"$HOME/.gitconfig.local"
  assert_eq "$(git config --global alias.ci)" "commit" "installed link is read by git"
  assert_eq "$(git config user.name)" "Test User" "~/.gitconfig.local is included"
  rm -f "$HOME/.gitconfig.local"
else
  assert_eq "$DF_ROW" "u24-nogit" "only the no-git row lacks git"
  for k in 's = status' 'st = status' 'stu = status --untracked-files=no' 'ci = commit' 'cim = commit --message' \
           'cima = commit --all --message' 'type = cat-file -t' 'dump = cat-file -p' 'ec = config --global -e' \
           'editor = micro' 'default = simple' 'defaultBranch = main'; do
    assert_ok "git config has: $k" -- grep -Fq -- "$k" "$gitcfg"
  done
fi
assert_ok "micro settings look like JSON" -- bash -c '
  s=$(tr -d "[:space:]" </src/config/micro/settings.json); [[ $s == "{"*"}" && $s == *\"* ]]'
assert_ok "micro settings are valid JSON (python3 when present)" -- bash -c '
  ! command -v python3 >/dev/null || python3 -c "import json,sys; json.load(open(sys.argv[1]))" /src/config/micro/settings.json'
for k in 'startup_message off' 'defscrollback 10000' '%H'; do
  assert_ok "screenrc has: $k" -- grep -Fq -- "$k" /src/config/screen/screenrc
done

# --- case_vendor_recorded ----------------------------------------------------
assert_ok "autosuggestions vendored" -- test -r /src/vendor/zsh-autosuggestions/zsh-autosuggestions.zsh
assert_ok "autosuggestions license kept" -- test -r /src/vendor/zsh-autosuggestions/LICENSE
assert_ok "vendor README records the tag" -- grep -Fq 'v0.7.1' /src/vendor/README.md
assert_ok "vendor README records a commit hash" -- grep -Eq '[0-9a-f]{40}' /src/vendor/README.md

# --- case_bash_end_to_end (pty): history filter and prompt --------------------
# DOTFILES_IN_ZSH=1 keeps the interactive bash from handing over to zsh.
rm -f ~/.bash_history
printf 'export TOKEN=abc123\nkubectl create token sa\necho kept-line\nexit\n' |
  DOTFILES_IN_ZSH=1 timeout 30 script -qec 'bash -i' /dev/null >/dev/null 2>&1 || true
assert_ok "bash history keeps normal lines" -- grep -Fqx 'echo kept-line' ~/.bash_history
assert_ok "bash history keeps 'kubectl create token sa'" -- grep -Fqx 'kubectl create token sa' ~/.bash_history
assert_fail "bash history drops the secret line" -- grep -Fq 'TOKEN=abc123' ~/.bash_history
rm -f ~/.bash_history

fx="$(mktemp -d)"
printf 'current-context: gke-prod\ncontexts:\n- name: gke-prod\n  context:\n    namespace: argocd\n' >"$fx/prod"
printf 'current-context: homelab\n' >"$fx/dev"
bash_prompt() { printf 'exit\n' | DOTFILES_IN_ZSH=1 TERM=xterm-256color KUBECONFIG="$1" timeout 30 script -qec 'bash -i' /dev/null | tr -d '\r'; }
out="$(bash_prompt "$fx/prod")"
assert_ok "bash prompt shows ctx/ns in bold red for prod" -- grep -aFq "$(printf '\033[1;31m[gke-prod/argocd]')" <<<"$out"
assert_ok "bash prompt has user@host and ends with a prompt char" -- grep -aEq "$(id -un)@[^ ]+ .* [\$#] " <<<"$out"
out="$(bash_prompt "$fx/dev")"
assert_ok "bash prompt shows ctx/ns for non-prod" -- grep -aFq '[homelab/default]' <<<"$out"
assert_fail "bash prompt is not red for non-prod" -- grep -aFq "$(printf '\033[1;31m')" <<<"$out"
out="$(bash_prompt "$fx/missing")"
ctx_re='\[[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\]' # a [context/namespace] segment (terminal escapes also contain "[")
assert_fail "bash prompt has no [ctx] without a kubeconfig" -- grep -aEq "$ctx_re" <<<"$out"
printf 'current-context: x$(touch %s/pwned)\n' "$fx" >"$fx/evil"
bash_prompt "$fx/evil" >/dev/null
assert_file_absent "$fx/pwned"
rm -rf "$fx"

# --- zsh rows: startup, history hook, prompt, keys, autosuggestions -----------
if [ "$has_zsh" = 1 ]; then
  # the same functions behave the same under zsh (they are sourced by both shells)
  zsh_ok() { zsh -f -c ". /src/shell/history.sh; . /src/shell/prompt-minimal.sh; $1" >/dev/null 2>&1; }
  for s in 'echo -----BEGIN CERTIFICATE-----' 'export TOKEN=abc' 'curl -H "Authorization: Bearer x" u' \
           "aws $fake_akia" "git push https://$fake_ghp@github.com/x" "x $fake_glpat" 'mysql --password=hunter2' 'curl -H "authorization: x" u'; do
    assert_ok "zsh: secret: $s" -- zsh_ok "df_history_is_secret '$s'"; done
  for s in 'kubectl create token sa' 'kubectl get secret -n x' 'task --list' 'echo ghp_short'; do
    assert_fail "zsh: not secret: $s" -- zsh_ok "df_history_is_secret '$s'"; done
  zfx="$(mktemp -d)"
  printf 'apiVersion: v1\n' >"$zfx/a"
  printf 'current-context: gke-prod\ncontexts:\n- name: gke-prod\n  context:\n    namespace: argocd\n' >"$zfx/b"
  assert_eq "$(env -u KUBECONFIG HOME="$zfx" zsh -f -c ". /src/shell/prompt-minimal.sh; KUBECONFIG=$zfx/a:$zfx/b; _df_kube_segment; print -r -- \$_df_kube_label \$_df_kube_prod" 2>&1)" \
            "gke-prod/argocd 1" "zsh: first file with current-context, namespace, prod"
  assert_eq "$(env -u KUBECONFIG HOME="$zfx" zsh -f -c ". /src/shell/prompt-minimal.sh; _df_kube_segment; print -r -- \"[\$_df_kube_label] \$_df_kube_prod\"" 2>&1)" \
            "[] 0" "zsh: no kubeconfig → empty, no error"
  rm -rf "$zfx"

  assert_eq "$(zsh -ic exit 2>&1 </dev/null)" "" "zsh -i is silent"
  assert_file_absent "$HOME/.zcompdump"
  assert_ok "compinit dump lives under ~/.cache/zsh" -- bash -c 'ls ~/.cache/zsh/ | grep -q zcompdump'
  assert_eq "$(zsh -ic 'print $+functions[_zsh_autosuggest_start]' 2>/dev/null </dev/null)" "1" "autosuggestions loaded"
  assert_ok "Ctrl-R is the pattern search widget (minimal profile default)" -- bash -c '
    [[ $(zsh -ic "bindkey \"^R\"" 2>/dev/null </dev/null) == *history-incremental-pattern-search-backward* ]]'
  assert_eq "$(zsh -ic 'print $HISTSIZE $SAVEHIST $HISTFILE' 2>/dev/null </dev/null)" "100000 100000 $HOME/.zsh_history" "zsh history sizes and file"
  assert_ok "zsh history options" -- bash -c '
    o=$(zsh -ic "setopt" 2>/dev/null </dev/null); for w in sharehistory histignorespace histignorealldups; do [[ $o == *$w* ]] || exit 1; done'

  # case_zsh_history_hook: a real interactive zsh on a pty
  rm -f ~/.zsh_history
  printf 'export TOKEN=abc123\nkubectl create token sa\necho kept-line\nexit\n' |
    DOTFILES_IN_ZSH=1 timeout 30 script -qec 'zsh -i' /dev/null >/dev/null 2>&1 || true
  assert_ok "zsh history keeps normal lines" -- grep -Fq 'echo kept-line' ~/.zsh_history
  assert_ok "zsh history keeps 'kubectl create token sa'" -- grep -Fq 'kubectl create token sa' ~/.zsh_history
  assert_fail "zsh history drops the secret line" -- grep -Fq 'TOKEN=abc123' ~/.zsh_history
  rm -f ~/.zsh_history

  fx="$(mktemp -d)"
  printf 'current-context: gke-prod\ncontexts:\n- name: gke-prod\n  context:\n    namespace: argocd\n' >"$fx/prod"
  printf 'current-context: homelab\n' >"$fx/dev"
  zsh_prompt() { printf 'exit\n' | TERM=xterm-256color KUBECONFIG="$1" timeout 30 script -qec 'zsh -i' /dev/null | tr -d '\r'; }
  out="$(zsh_prompt "$fx/prod")"
  assert_ok "zsh prompt shows ctx/ns in bold red for prod" -- grep -aEq "$(printf '\033\\[1m\033\\[31m\\[gke-prod/argocd\\]')" <<<"$out"
  assert_ok "zsh prompt has user@host" -- grep -aEq "$(id -un)@[^ ]+ " <<<"$out"
  out="$(zsh_prompt "$fx/dev")"
  assert_ok "zsh prompt shows ctx/ns for non-prod" -- grep -aFq '[homelab/default]' <<<"$out"
  assert_fail "zsh prompt is not red for non-prod" -- grep -aFq "$(printf '\033[31m')" <<<"$out"
  out="$(zsh_prompt "$fx/missing")"
  assert_fail "zsh prompt has no [ctx] without a kubeconfig" -- grep -aEq "$ctx_re" <<<"$out"
  printf 'current-context: x$(touch %s/pwned)\n' "$fx" >"$fx/evil"
  zsh_prompt "$fx/evil" >/dev/null
  assert_file_absent "$fx/pwned"
  rm -rf "$fx"

  # case_startup_time: median of 10 `zsh -i -c exit` under 300 ms
  zsh -ic exit </dev/null >/dev/null 2>&1 || true # warm the completion dump
  times=()
  for _ in $(seq 10); do
    t0=$(date +%s%N)
    zsh -i -c exit </dev/null >/dev/null 2>&1 || true
    times+=($(( ($(date +%s%N) - t0) / 1000000 )))
  done
  median=$(printf '%s\n' "${times[@]}" | sort -n | sed -n '5p')
  printf '  zsh startup median: %s ms (all: %s)\n' "$median" "${times[*]}"
  assert_ok "zsh startup median < 300 ms (was ${median} ms)" -- test "$median" -lt 300
else
  assert_eq "$DF_ROW" "u20-nozsh" "only the no-zsh row lacks zsh"
fi

# --- non-interactive stays silent with the full bashrc ------------------------
assert_eq "$(bash -c '. ~/.bashrc; echo ok' 2>&1)" "ok" "ssh-like bashrc still silent and stderr-clean"
assert_eq "$(bash -lc 'echo ok' 2>&1)" "ok" "bash -lc still silent"
