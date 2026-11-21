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
fake_pat="github_pat_$(rep c 30)"

# --- case_history_filter -----------------------------------------------------
. /src/shell/history.sh
for s in 'echo -----BEGIN CERTIFICATE-----' 'export TOKEN=abc' 'curl -H "Authorization: Bearer x" u' \
         "aws $fake_akia" "git push https://$fake_ghp@github.com/x" \
         "git clone https://oauth2:$fake_glpat@gitlab.example/x" \
         'mysql --password=hunter2' 'PASSWD=x ./run' 'export Api_Key=x' 'curl --api-key=x u' 'SECRET=x cmd' \
         'curl -H "authorization: Bearer x" u' $'echo a\nexport TOKEN=abc' \
         'export AWS_SECRET_ACCESS_KEY=abc' 'ACCESS_KEY=x aws s3 ls' 'export DB_PASSWORD_FILE=x' "echo $fake_pat"; do
  assert_ok "secret: $s" -- df_history_is_secret "$s"; done
for s in 'kubectl create token sa' 'kubectl get secret -n x' 'task --list' 'echo password' \
         'kubectl create token sa --duration 1h' 'echo ghp_short' 'echo AKIAshort' 'ls api-key' \
         'token = 1' 'kubectl get secret --namespace=x' 'kubectl get secrets --namespace=x -o name' \
         'kubectl create token sa --duration=1h' 'echo github_pat_short'; do
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

# --- case_prompt_formats_and_cost --------------------------------------------
# kubeconfig dialects: CRLF (WSL users point at Windows files), nested lists,
# trailing comments, indented lists, GKE-style names
mkdir -p ~/.kube; unset KUBECONFIG
printf 'contexts:\r\n- context:\r\n    cluster: c\r\n    namespace: argocd\r\n  name: dev\r\ncurrent-context: dev\r\n' >~/.kube/config
assert_eq "$(df_kube_context)" "dev" "CRLF: context has no carriage return"
assert_eq "$(df_kube_namespace dev)" "argocd" "CRLF: namespace parsed"
_df_kube_segment; assert_eq "$_df_kube_label" "dev/argocd" "CRLF: segment label"
printf 'current-context: dev # note\ncontexts:\n  - name: dev\n    context:\n      namespace: x\n' >~/.kube/config
assert_eq "$(df_kube_context)" "dev" "trailing comment stripped"
assert_eq "$(df_kube_namespace dev)" "x" "indented list entries"
cat >~/.kube/config <<'EOF'
contexts:
- context:
    cluster: minikube
    extensions:
    - extension:
        provider: minikube.sigs.k8s.io
      name: context_info
    namespace: team-a
    user: minikube
  name: minikube
current-context: minikube
EOF
assert_eq "$(df_kube_namespace minikube)" "team-a" "nested extension lists do not confuse the parser"
printf 'contexts:\n- context:\n    cluster: c\n    namespace: argo_cd\n  name: gke_proj_europe-west1_prod-1\ncurrent-context: gke_proj_europe-west1_prod-1\n' >~/.kube/config
_df_kube_segment
assert_eq "$_df_kube_label|$_df_kube_prod" "gke_proj_europe-west1_prod-1/argo_cd|1" "GKE-style context name"

# a large kubectl-ordered kubeconfig (certificate data comes before current-context)
fx="$(mktemp -d)"
{
  echo 'apiVersion: v1'; echo 'clusters:'
  for i in $(seq 55); do
    echo '- cluster:'; printf '    certificate-authority-data: %s\n' "$(head -c 2250 /dev/zero | base64 -w0)"
    echo "    server: https://c$i.example.invalid"; echo "  name: c$i"
  done
  echo 'contexts:'
  for i in $(seq 55); do echo '- context:'; echo "    cluster: c$i"; echo "    namespace: ns$i"; echo "    user: u$i"; echo "  name: ctx$i"; done
  echo 'current-context: ctx55'; echo 'kind: Config'; echo 'users:'
  for i in $(seq 55); do echo "- name: u$i"; echo '  user:'; printf '    token: %s\n' "$(head -c 1500 /dev/zero | base64 -w0)"; done
} >"$fx/big"
assert_ok "big kubeconfig is at least 200 KB" -- test "$(wc -c <"$fx/big")" -ge 200000
bigcfg="$fx/big"
touch -d '5 seconds ago' "$fx/big"
KUBECONFIG="$fx/big"
render_ms() { # average ms over 10 renders; $1 = cache dir
  local t0 i
  t0=$(date +%s%N)
  for i in 1 2 3 4 5 6 7 8 9 10; do XDG_CACHE_HOME="$1" _df_kube_segment; done
  echo $(( ($(date +%s%N) - t0) / 10000000 ))
}
rm -rf "$fx/cache"
XDG_CACHE_HOME="$fx/cache" _df_kube_segment
assert_eq "$_df_kube_label" "ctx55/ns55" "big kubeconfig: label"
render_ms_value=$(render_ms "$fx/cache")
printf '  big kubeconfig render in bash: %s ms (average of 10)\n' "$render_ms_value"
assert_ok "bash render < 50 ms on a 200 KB kubeconfig (was $render_ms_value)" -- test "$render_ms_value" -lt 50
sed -i 's/^current-context: ctx55$/current-context: ctx7-prod/' "$fx/big"
XDG_CACHE_HOME="$fx/cache" _df_kube_segment
assert_eq "$_df_kube_label|$_df_kube_prod" "ctx7-prod/default|1" "an edited kubeconfig is picked up"

# Replacing a kubeconfig must always be noticed, also by something OLDER than
# the cache (cp -p, mv, rsync -t, tar x, a symlink swap): the prod red must
# never be lost. Same script in bash and zsh; zsh additionally caches.
cat >"$fx/identity.sh" <<'EOF'
. /src/shell/prompt-minimal.sh
d="$1"; mkdir -p "$d"
export XDG_CACHE_HOME="$d/cache" KUBECONFIG="$d/config"
show() { _df_kube_segment; printf '%s=%s|%s\n' "$1" "$_df_kube_label" "$_df_kube_prod"; }
printf 'current-context: staging\n' >"$d/a"; touch -d '1 hour ago' "$d/a"
printf 'current-context: really-prod\n' >"$d/b"; touch -d '2 hours ago' "$d/b"
printf 'current-context: dev\n' >"$d/c"; touch -d '3 hours ago' "$d/c"
cp -p "$d/a" "$d/config"; show start
show again
cp -p "$d/b" "$d/config"; show cp_p_older_in_place
cp -p "$d/c" "$d/config"; show cp_p_dev
mv "$d/b" "$d/config"; show mv_older_file
cp -p "$d/c" "$d/config"; show back_to_dev
rm -f "$d/config"; ln -s "$d/c" "$d/config"; show link_dev
printf 'current-context: really-prod\n' >"$d/b2"; touch -d '4 hours ago' "$d/b2"
ln -sfn "$d/b2" "$d/config"; show link_swapped_to_prod
ln -sfn "$d/c" "$d/config"; show link_swapped_back
EOF
want_identity="start=staging/default|0
again=staging/default|0
cp_p_older_in_place=really-prod/default|1
cp_p_dev=dev/default|0
mv_older_file=really-prod/default|1
back_to_dev=dev/default|0
link_dev=dev/default|0
link_swapped_to_prod=really-prod/default|1
link_swapped_back=dev/default|0"
assert_eq "$(bash "$fx/identity.sh" "$fx/id-bash")" "$want_identity" "bash: replaced or re-linked kubeconfigs are noticed"

# the zsh cache: no rescans while nothing changes, a rescan after an edit or a
# different file list
cat >"$fx/cache.zsh" <<'EOF'
. /src/shell/prompt-minimal.sh
fx="$1"
export XDG_CACHE_HOME="$fx/zcache" KUBECONFIG="$fx/big"
PATH="$fx/bin:$PATH"
scans() { wc -l <"$fx/awk-count" | tr -d ' '; }
for i in 1 2 3 4 5 6; do _df_kube_segment; done
print "scans_after_6_renders=$(scans) label=$_df_kube_label"
sed -i 's/^current-context: ctx7-prod$/current-context: ctx8-prod/' "$fx/big"
_df_kube_segment
print "scans_after_edit=$(scans) label=$_df_kube_label"
printf 'current-context: ctx9\n' >"$fx/other"; touch -d '5 seconds ago' "$fx/other" "$fx/big"
KUBECONFIG="$fx/other:$fx/big"
_df_kube_segment
print "different_file_list=$_df_kube_label"
EOF
if [ "$has_zsh" = 1 ]; then
  mkdir "$fx/bin"
  printf '#!/bin/sh\necho x >>"%s/awk-count"\nexec "%s" "$@"\n' "$fx" "$(command -v awk)" >"$fx/bin/awk"; chmod +x "$fx/bin/awk"
  rm -f "$fx/awk-count"; : >"$fx/awk-count"
  touch -d '5 seconds ago' "$fx/big"
  assert_eq "$(zsh -f "$fx/cache.zsh" "$fx")" "scans_after_6_renders=1 label=ctx7-prod/default
scans_after_edit=2 label=ctx8-prod/default
different_file_list=ctx9/ns9" "zsh: unchanged kubeconfig is scanned once; an edit or a different file list rescans"
  assert_eq "$(zsh -f "$fx/identity.sh" "$fx/id-zsh")" "$want_identity" "zsh: replaced or re-linked kubeconfigs are noticed"
fi
rm -rf "$HOME/.kube" "$HOME/.cache/dotfiles"; unset KUBECONFIG

# $? survives the hooks, and PROMPT_COMMAND joins stay valid
assert_eq "$(bash -c '. /src/shell/history.sh; . /src/shell/prompt-minimal.sh; false; _df_bash_history_filter; echo $?')" "1" "history hook keeps \$?"
assert_eq "$(bash -c '. /src/shell/history.sh; . /src/shell/prompt-minimal.sh; (exit 7); _df_prompt_update; echo $?')" "7" "prompt hook keeps \$?"
for pc in $'echo a\n' 'echo a;' 'echo a;  ' 'echo a'; do
  out="$(PROMPT_COMMAND=$pc bash -c '. /src/shell/prompt-command.sh; _df_prompt_command_add _df_zz; _df_prompt_command_add _df_zz; printf "%s" "$PROMPT_COMMAND"')"
  assert_eq "$out" "echo a; _df_zz" "PROMPT_COMMAND join after $(printf %q "$pc")"
  assert_ok "joined PROMPT_COMMAND parses" -- bash -n -c "$out"
done
assert_eq "$(bash -c 'PROMPT_COMMAND=(a b); . /src/shell/prompt-command.sh; _df_prompt_command_add c; _df_prompt_command_add c; echo "${#PROMPT_COMMAND[@]}"')" "3" "array PROMPT_COMMAND"
assert_eq "$(bash -c '. /src/shell/history.sh; . /src/shell/history.sh; . /src/shell/prompt-minimal.sh; . /src/shell/prompt-minimal.sh; printf "%s" "$PROMPT_COMMAND"')" \
          "_df_bash_history_filter; _df_prompt_update" "hooks are registered once, history first"

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
assert_fail "repo git config carries no identity" -- grep -Eiq '^[[:space:]]*(name|email|signingkey|user)[[:space:]]*(=|$)|\[user\]|\[credential' "$gitcfg"
assert_fail "repo git config sets no core.editor (prod hosts have no micro)" -- grep -Eq '^[[:space:]]*editor[[:space:]]*=' "$gitcfg"
# ~/.config/git/config is a generated REAL file, so `git config --global`
# writes never land in the tracked file of the repo.
gitglobal="$HOME/.config/git/config"
assert_ok "~/.config/git/config is a regular file, not a link" -- test -f "$gitglobal" -a ! -L "$gitglobal"
assert_ok "generated git config includes the repo settings (quoted, marked)" -- grep -qxF "$(printf '	path = "%s" # dotfiles:repo' "$HOME/.dotfiles/config/git/config")" "$gitglobal"
assert_ok "generated git config includes the local identity file" -- grep -Eq '^[[:space:]]*path[[:space:]]*=[[:space:]]*~/\.gitconfig\.local$' "$gitglobal"
assert_eq "$(grep -c -v -E '^(#|\[include\]|[[:space:]]*path = )' "$gitglobal" || true)" "0" "generated git config has nothing but the two includes"
if [ "$has_git" = 1 ]; then
  g() { git config --file "$gitcfg" --get "$1"; }
  assert_eq "$(g core.editor || true)" "" "core.editor unset in the repo file"
  assert_eq "$(g push.default)" "simple" "push.default"
  assert_eq "$(g init.defaultBranch)" "main" "init.defaultBranch"
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
  # the installed setup, with an identity in the include file
  printf '[user]\n\tname = Test User\n\temail = test@example.invalid\n' >"$HOME/.gitconfig.local"
  assert_eq "$(git config alias.ci)" "commit" "repo aliases reach git through the generated file"
  assert_eq "$(git config user.name)" "Test User" "~/.gitconfig.local is included"
  assert_eq "$(git config --get core.editor || true)" "" "core.editor unset, so git falls back to the environment"
  assert_eq "$(env -u VISUAL -u GIT_EDITOR EDITOR=my-editor git var GIT_EDITOR)" "my-editor" "git resolves the editor via \$EDITOR"
  rm -f "$HOME/.gitconfig.local"
  # global writes land in the real file and never in the repo copy
  repo_before="$(sha256sum <"$HOME/.dotfiles/config/git/config")"
  git config --global foo.bar baz
  git config --global --add safe.directory /nonexistent
  assert_eq "$(sha256sum <"$HOME/.dotfiles/config/git/config")" "$repo_before" "git config --global does not touch the repo file"
  assert_ok "global write landed in ~/.config/git/config" -- grep -Fq 'bar = baz' "$gitglobal"
  assert_eq "$(git config alias.s)" "status" "aliases still work after a global write"
  # leave the real file as the installer generated it
  git config --global --unset foo.bar
  git config --global --unset safe.directory
  git config --global --remove-section foo 2>/dev/null || true
  git config --global --remove-section safe 2>/dev/null || true
else
  assert_eq "$DF_ROW" "u24-nogit" "only the no-git row lacks git"
  for k in 's = status' 'st = status' 'stu = status --untracked-files=no' 'ci = commit' 'cim = commit --message' \
           'cima = commit --all --message' 'type = cat-file -t' 'dump = cat-file -p' 'ec = config --global -e' \
           'default = simple' 'defaultBranch = main'; do
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

# A secret command that is still running when the terminal hangs up must not
# reach the history file: bash saves the history on SIGHUP before any
# PROMPT_COMMAND could run. Send the hangup to bash and to the running command,
# as the kernel does when a terminal goes away.
rm -f ~/.bash_history
( printf 'echo before-hangup\nPASSWORD=x sleep 40\n'; sleep 14 ) |
  DOTFILES_IN_ZSH=1 timeout 45 script -qec 'bash -i' /dev/null >/dev/null 2>&1 &
pty_job=$!
spid=''
for _ in $(seq 60); do
  spid="$(pgrep -f 'sleep 40$' | head -n 1 || true)"
  [ -z "$spid" ] || break
  sleep 0.25
done
assert_ok "the secret command is running" -- test -n "$spid"
bpid="$(ps -o ppid= -p "$spid" | tr -d ' ')"
kill -HUP "$bpid" "$spid"
for _ in $(seq 60); do kill -0 "$bpid" 2>/dev/null || break; sleep 0.25; done
assert_fail "interactive bash exits on SIGHUP" -- kill -0 "$bpid"
wait "$pty_job" 2>/dev/null || true
assert_ok "hangup: earlier lines are saved" -- grep -Fqx 'echo before-hangup' ~/.bash_history
assert_fail "hangup: the running secret command is not saved" -- grep -Fq 'PASSWORD=x' ~/.bash_history
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
  for s in 'export AWS_SECRET_ACCESS_KEY=abc' "echo $fake_pat"; do
    assert_ok "zsh: secret: $s" -- zsh_ok "df_history_is_secret '$s'"; done
  for s in 'kubectl get secret --namespace=x' 'kubectl create token sa --duration=1h'; do
    assert_fail "zsh: not secret: $s" -- zsh_ok "df_history_is_secret '$s'"; done
  # zsh reads files byte by byte, so a big kubeconfig must never go through a read loop
  zsh_ms="$(env -u KUBECONFIG KUBECONFIG="$bigcfg" XDG_CACHE_HOME=/nonexistent-cache-dir zsh -f -c '. /src/shell/prompt-minimal.sh; t0=$(date +%s%N); for i in 1 2 3 4 5 6 7 8 9 10; do _df_kube_segment; done; print $(( ($(date +%s%N) - t0) / 10000000 ))')"
  printf '  big kubeconfig render in zsh (uncached): %s ms (average of 10)\n' "$zsh_ms"
  assert_ok "zsh render < 50 ms on a 200 KB kubeconfig (was $zsh_ms)" -- test "$zsh_ms" -lt 50
  printf 'contexts:\r\n- context:\r\n    namespace: argocd\r\n  name: dev\r\ncurrent-context: dev\r\n' >"$zfx/crlf"
  assert_eq "$(env KUBECONFIG="$zfx/crlf" XDG_CACHE_HOME="$zfx/cache" zsh -f -c '. /src/shell/prompt-minimal.sh; _df_kube_segment; print -r -- $_df_kube_label')" "dev/argocd" "zsh: CRLF kubeconfig"
  assert_eq "$(zsh -f -c '. /src/shell/history.sh; . /src/shell/prompt-minimal.sh; false; _df_prompt_precmd; print $?')" "1" "zsh: prompt hook keeps \$?"
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
