# Interactive shell: history secret filter, kube-aware prompt, aliases and
# the app configs (git, micro, screen). Unit-style checks source the repo files
# from /src; the end-to-end ones use the installed setup on a pty.
export DOTFILES_NO_TOOLS=1 # tools are covered by 50-server-tools.sh
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

# --- case_skeleton_parity: what the distro skeleton ~/.bashrc gave, and readline keys ---
bi() { DOTFILES_IN_ZSH=1 bash -ic "$1" 2>/dev/null </dev/null; }
assert_eq "$(bi 'alias ls grep')" "alias ls='ls --color=auto'
alias grep='grep --color=auto'" "bash colours ls and grep"
if [ "$has_zsh" = 1 ]; then
  assert_eq "$(zsh -ic 'alias ls grep' 2>/dev/null </dev/null)" "ls='ls --color=auto'
grep='grep --color=auto'" "zsh colours ls and grep"
fi
assert_eq "$(bi 'echo "${LS_COLORS:-none}"')" "none" "no dircolors run without a ~/.dircolors"
printf 'DIR 01;35\n' >~/.dircolors
assert_ok "a ~/.dircolors of the user's is used" -- grep -q 'di=01;35' <<<"$(bi 'echo "$LS_COLORS"')"
rm -f ~/.dircolors
if [ -x /usr/bin/lesspipe ]; then
  assert_eq "$(bi 'echo "$LESSOPEN|$LESSCLOSE"')" "| /usr/bin/lesspipe %s|/usr/bin/lesspipe %s %s" "lesspipe is set up"
else
  assert_eq "$(bi 'echo "${LESSOPEN:-unset}"')" "unset" "no lesspipe, no LESSOPEN"
fi
printf "alias dfprobe='echo from-bash-aliases'\n" >~/.bash_aliases
assert_eq "$(bi 'alias dfprobe')" "alias dfprobe='echo from-bash-aliases'" "~/.bash_aliases is read"
rm -f ~/.bash_aliases
assert_eq "$(bi 'echo "$HISTTIMEFORMAT"')" "%F %T " "bash history keeps timestamps"
binds="$(bi 'bind -p; bind -v')"
for key in '"\e[A": history-search-backward' '"\e[B": history-search-forward' \
  '"\eOA": history-search-backward' '"\eOB": history-search-forward' \
  'set completion-ignore-case on' 'set enable-bracketed-paste on'; do
  assert_ok "bash readline: $key" -- grep -qxF "$key" <<<"$binds"
done
if [ "$has_zsh" = 1 ]; then
  for key in '^[[A' '^[OA'; do
    assert_eq "$(zsh -ic "bindkey '$key'" 2>/dev/null </dev/null)" "\"$key\" up-line-or-beginning-search" "zsh: $key searches back by prefix"
  done
  for key in '^[[B' '^[OB'; do
    assert_eq "$(zsh -ic "bindkey '$key'" 2>/dev/null </dev/null)" "\"$key\" down-line-or-beginning-search" "zsh: $key searches forward by prefix"
  done
fi

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
assert_ok "bash prompt has user@host" -- grep -aEq "$(id -un)@[^ ]+ " <<<"$out"
# Two lines: the prompt char starts a line of its own (after terminal escapes
# such as bracketed paste) and is not on the user@host line.
esc="$(printf '\033')"
prompt_line_re="^($esc\\[[?0-9;]*[a-zA-Z])*[\$#] "
assert_ok "bash prompt char starts the second line" -- grep -aEq "$prompt_line_re" <<<"$out"
assert_fail "bash prompt char is not on the user@host line" -- grep -aEq "$(id -un)@[^ ]+ .* [\$#] " <<<"$out"
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
  assert_ok "zsh prompt char starts the second line" -- grep -aEq "$prompt_line_re" <<<"$out"
  assert_fail "zsh prompt char is not on the user@host line" -- grep -aEq "$(id -un)@[^ ]+ .* [\$#] " <<<"$out"
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

# --- case_tool_additions: zoxide, fzf-tab and the k completion -----------------
# Stand-ins for the real tools (50-server-tools.sh runs the real ones): on the
# minimal profile none of them may have any effect, whatever the host has on
# PATH; on a profile with tools they are loaded, and fzf-tab before the rest.
fx="$(mktemp -d)"
mkdir "$fx/bin"
cat >"$fx/bin/fzf" <<'STUB'
#!/bin/sh
# Like fzf 0.48+: `fzf --zsh` remembers the widget that Tab is bound to (the way
# its completion.zsh does), then binds Tab itself.
[ "$1" = --zsh ] || exit 0
cat <<'ZSH'
binding=$(bindkey '^I')
[[ $binding =~ 'undefined-key' ]] || fzf_default_completion=$binding[(s: :w)2]
unset binding
fzf-completion() { :; }
zle -N fzf-completion
bindkey '^I' fzf-completion
ZSH
STUB
printf '#!/bin/sh\nprintf "z() { :; }\nzi() { :; }\n"\n' >"$fx/bin/zoxide"
printf '#!/bin/sh\n:\n' >"$fx/bin/kubectl"
chmod +x "$fx/bin/fzf" "$fx/bin/zoxide" "$fx/bin/kubectl"
rm -rf ~/.cache/dotfiles/init

# Non-interactive shells print nothing and load nothing, in every profile.
assert_eq "$(PATH="$fx/bin:$PATH" bash -c '. ~/.bashrc; echo ok' 2>&1)" ok "ssh-like bash with the tools on PATH prints nothing"
assert_eq "$(PATH="$fx/bin:$PATH" bash -lc 'echo ok' 2>&1)" ok "bash -lc with the tools on PATH prints nothing"
assert_file_absent "$HOME/.cache/dotfiles/init"

# bash: z is zoxide's on a tools profile only; k completes like kubectl once its
# completion function is there (a file of ~/.bashrc.d, here), and not before.
# The answer is picked out between markers: the Rocky /etc/bashrc prints a
# terminal title before every prompt.
bash_probe() {
  printf 'echo "@@$(%s)@@"\nexit\n' "$1" | PATH="$fx/bin:$PATH" DOTFILES_IN_ZSH=1 TERM=xterm-256color bash -i 2>/dev/null |
    grep -ao '@@.*@@' | head -n 1 | sed 's/^@@//; s/@@$//'
}
if [ "$DF_PROFILE" = minimal ]; then
  assert_eq "$(bash_probe 'type -t z')" "" "minimal bash: no zoxide"
  assert_file_absent "$HOME/.cache/dotfiles/init"
else
  assert_eq "$(bash_probe 'type -t z')" function "tools profile bash: zoxide is initialised"
  assert_ok "and cached" -- test -r "$HOME/.cache/dotfiles/init/zoxide-bash"
fi
assert_eq "$(bash_probe 'complete -p k 2>&1 || true')" "bash: complete: k: no completion specification" "bash: no completion for k without kubectl's function"
mkdir -p ~/.bashrc.d
printf '__start_kubectl() { :; }\n' >~/.bashrc.d/kubectl-completion.sh
assert_eq "$(bash_probe 'complete -p k')" "complete -o default -F __start_kubectl k" "bash: k completes with kubectl's function"
rm -rf ~/.bashrc.d

if [ "$has_zsh" = 1 ]; then
  zsh_stub() { timeout 30 script -qec "TERM=xterm-256color PATH=$fx/bin:\$PATH zsh -i -c '$1'" /dev/null </dev/null | tr -d '\r'; }
  # The xtrace of a whole start, for the order in which ~/.zshrc loads things.
  zsh_stub_x() { timeout 30 script -qec "TERM=xterm-256color PATH=$fx/bin:\$PATH zsh -i -x -c exit" /dev/null </dev/null | tr -d '\r'; }
  if [ "$DF_PROFILE" = minimal ]; then
    assert_eq "$(zsh_load_order "$(zsh_stub_x)")" "compinit autosuggestions tools" "minimal zsh: the load order has no fzf-tab"
    assert_eq "$(zsh_stub 'print -r -- $+functions[fzf-tab-complete]')" 0 "minimal zsh: fzf-tab is not loaded"
    assert_eq "$(zsh_stub 'bindkey "^I"')" '"^I" expand-or-complete' "minimal zsh: Tab is the stock widget"
    assert_eq "$(zsh_stub 'whence -w z')" "z: none" "minimal zsh: no zoxide"
    assert_eq "$(zsh_stub 'zstyle -L ":completion:*" menu')" "zstyle ':completion:*' menu select" "minimal zsh: completion menu unchanged"
    assert_file_absent "$HOME/.cache/dotfiles/init"
  else
    assert_eq "$(zsh_stub 'print -r -- $+functions[fzf-tab-complete]')" 1 "tools profile zsh: fzf-tab is loaded"
    assert_eq "$(zsh_stub 'bindkey "^I"')" '"^I" fzf-completion' "fzf's bindings come last"
    assert_eq "$(zsh_stub 'print -r -- $fzf_default_completion')" fzf-tab-complete "fzf falls back to fzf-tab, so fzf-tab was loaded before it"
    assert_eq "$(zsh_load_order "$(zsh_stub_x)")" "compinit fzf-tab autosuggestions tools" "load order: compinit, fzf-tab, autosuggestions, tools.sh (fzf)"
    assert_eq "$(zsh_stub 'whence -w z')" "z: function" "tools profile zsh: zoxide is initialised"
    assert_ok "and cached" -- test -r "$HOME/.cache/dotfiles/init/zoxide-zsh"
    # fzf-tab needs an fzf that works: one that cannot print its zsh script (older than 0.48)
    # is no reason to load it, and tools.sh skips that fzf too, so Tab stays the stock widget.
    cp -p "$fx/bin/fzf" "$fx/fzf.good"
    printf '#!/bin/sh\nexit 2\n' >"$fx/bin/fzf"
    rm -rf ~/.cache/dotfiles/init
    assert_eq "$(zsh_stub 'print -r -- $+functions[fzf-tab-complete]')" 0 "tools profile with an fzf that has no --zsh: fzf-tab is not loaded"
    assert_eq "$(zsh_stub 'bindkey "^I"')" '"^I" expand-or-complete' "tools profile with an fzf that has no --zsh: Tab is the stock widget"
    mv "$fx/fzf.good" "$fx/bin/fzf"
    # fzf-tab needs fzf: a profile with tools but no fzf keeps the stock Tab.
    rm "$fx/bin/fzf"
    assert_eq "$(zsh_stub 'print -r -- $+functions[fzf-tab-complete]')" 0 "tools profile without fzf: fzf-tab is not loaded"
    assert_eq "$(zsh_stub 'bindkey "^I"')" '"^I" expand-or-complete' "tools profile without fzf: Tab is the stock widget"
  fi
  assert_eq "$(PATH="$fx/bin:$PATH" zsh -c 'echo ok' 2>&1 </dev/null)" ok "non-interactive zsh with the tools on PATH prints nothing"
  assert_eq "$(PATH="$fx/bin:$PATH" zsh -lc 'echo ok' 2>&1 </dev/null)" ok "zsh -lc with the tools on PATH prints nothing"
  # Not on a terminal: nothing to bind keys on, same gate as fzf.
  assert_eq "$(PATH="$fx/bin:$PATH" zsh -ic 'print -r -- $+functions[fzf-tab-complete]' 2>&1 </dev/null)" 0 "no terminal on stdin: fzf-tab is not loaded"

  # k completes like kubectl when kubectl and its completion exist; a k alias of
  # the user's (~/.zshrc.local) replaces the alias but not the completion.
  mkdir -p ~/.cache/zsh/completions
  printf '#compdef kubectl\n_kubectl() { :; }\n' >~/.cache/zsh/completions/_kubectl
  rm -f ~/.cache/zsh/zcompdump*
  assert_eq "$(zsh_stub 'print -r -- ${_comps[k]}')" "_kubectl" "zsh: k completes like kubectl"
  assert_eq "$(zsh_stub 'alias k')" "k=kubectl" "zsh: k is the kubectl alias"
  printf "alias k='kubectl -n kube-system'\n" >~/.zshrc.local
  assert_eq "$(zsh_stub 'alias k; print -r -- ${_comps[k]}')" "k='kubectl -n kube-system'
_kubectl" "zsh: the user's own k alias wins, the completion stays"
  rm -f ~/.zshrc.local
  assert_eq "$(zsh_stub 'print -r -- ${+_comps[k]}')" 1 "zsh: and the completion is there without the local file"
  rm "$fx/bin/kubectl"
  rm -f ~/.cache/zsh/zcompdump*
  assert_eq "$(zsh_stub 'print -r -- ${+_comps[k]}')" 0 "zsh: no kubectl, no completion for k"
  rm -rf ~/.cache/zsh/completions ~/.cache/zsh/zcompdump*
fi
rm -rf "$fx" ~/.cache/dotfiles/init

# --- case_wsl1_mise_mode: no mise process per start or per prompt on WSL1 ------
# A counting stand-in for mise logs one line per call (the real one is covered by
# 70-workstation.sh). The WSL1 pretence is DF_PROC_VERSION_FILE, which works on
# every row. The cache is ~/.cache/dotfiles/mise-env.sh.
fxw="$(mktemp -d)"
mkdir -p "$fxw/bin" "$fxw/tools/a" "$fxw/tools/b" "$fxw/venv/bin" "$fxw/plain" "$fxw/proj/sub"
cat >"$fxw/bin/mise" <<'STUB'
#!/bin/sh
# Counting stand-in for mise: one log line per call.
printf '%s\n' "$*" >>"${DF_TEST_MISE_LOG:?}"
case "${1:-}" in
  env)
    [ -z "${DF_TEST_MISE_FAIL:-}" ] || exit 1
    if [ -n "${DF_TEST_MISE_DQ:-}" ]; then
      printf 'export PATH="%s:%s"\n' "$DF_TEST_MISE_DIRS" "$PATH"
    else
      printf "export PATH='%s:%s'\n" "$DF_TEST_MISE_DIRS" "$PATH"
    fi
    printf 'export VIRTUAL_ENV=%s\n' "$DF_TEST_VENV"
    ;;
  activate)
    printf 'export DF_TEST_ACTIVATED=1\n_mise_hook() { "%s" hook-env; }\n' "$0"
    case "${2:-}" in
      zsh) printf 'autoload -Uz add-zsh-hook\nadd-zsh-hook precmd _mise_hook\n' ;;
      bash) printf 'PROMPT_COMMAND="_mise_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"\n' ;;
    esac
    ;;
esac
STUB
# Like fzf 0.48+: `fzf --zsh` remembers Tab's widget, then binds Tab itself. Counts its calls.
cat >"$fxw/bin/fzf" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${DF_TEST_FZF_LOG:?}"
[ "$1" = --zsh ] || exit 0
cat <<'ZSH'
binding=$(bindkey '^I')
[[ $binding =~ 'undefined-key' ]] || fzf_default_completion=$binding[(s: :w)2]
unset binding
fzf-completion() { :; }
zle -N fzf-completion
bindkey '^I' fzf-completion
ZSH
STUB
chmod +x "$fxw/bin/mise" "$fxw/bin/fzf"
printf '[tools]\n' >"$fxw/proj/mise.toml"
export DF_TEST_MISE_LOG="$fxw/log" DF_TEST_FZF_LOG="$fxw/fzf-log"
export DF_TEST_VENV="$fxw/venv" DF_TEST_MISE_DIRS="$fxw/venv/bin:$fxw/tools/a:$fxw/tools/b"
unset DF_TEST_MISE_FAIL
dirs="$DF_TEST_MISE_DIRS"
wsl1="/src/test/fixtures/proc-version-wsl1"
wsl2="$fxw/proc-wsl2"
printf 'Linux version 5.15.153.1-microsoft-standard-WSL2\n' >"$wsl2"
cache="$HOME/.cache/dotfiles/mise-env.sh"
reset_logs() { : >"$fxw/log"; : >"$fxw/fzf-log"; }
calls() { wc -l <"$1" | tr -d ' '; }
# wz <zsh code>: interactive zsh on a pty in $WZ_DIR, the proc version file from $PV.
PV="$wsl1"
WZ_DIR="$HOME"
wz() { timeout 30 script -qec "cd '$WZ_DIR' && TERM=xterm-256color PATH='$fxw/bin':\$PATH DF_PROC_VERSION_FILE='$PV' zsh -i -c '$1'" /dev/null </dev/null | tr -d '\r'; }
# wb <bash lines>: interactive bash reading the lines from a pipe, so PROMPT_COMMAND runs
# before each of them; what is printed between @@ markers comes back, one per line.
wb() {
  printf '%s\nexit\n' "$1" | (cd "$WZ_DIR" && env PATH="$fxw/bin:$PATH" DF_PROC_VERSION_FILE="$PV" DOTFILES_IN_ZSH=1 TERM=xterm-256color bash -i 2>/dev/null || true) |
    { grep -ao '@@.*@@' || true; } | sed 's/^@@//; s/@@$//'
}
# ne <shell> <code>: a non-interactive shell with a bare environment (ssh host cmd), after ~/.bashrc
# or ~/.zshenv.
ne() { env -i HOME="$HOME" PATH="$fxw/bin:/usr/bin:/bin" DF_PROC_VERSION_FILE="$PV" "$1" -c "$2"; }
# path_tail <shell>: what follows ~/.local/bin in the PATH of such a shell (everything before it
# is the host's business). In bash the start file is sourced by hand, as sshd does.
path_tail() {
  local p
  if [ "$1" = bash ]; then p="$(ne bash '. ~/.bashrc; echo "$PATH"')"; else p="$(ne zsh 'echo "$PATH"')"; fi
  printf '%s' "${p#*:$HOME/.local/bin:}"
}

if [ "$DF_PROFILE" = minimal ]; then
  # Minimal never uses mise: nothing is cached, nothing is called.
  reset_logs
  if [ "$has_zsh" = 1 ]; then assert_eq "$(wz 'print -r -- ${+functions[_mise_hook]}')" 0 "minimal zsh on WSL1: no mise activation"; fi
  assert_eq "$(wb 'echo "@@$(declare -F _mise_hook)@@"')" "" "minimal bash on WSL1: no mise activation"
  assert_eq "$(calls "$fxw/log")" 0 "minimal on WSL1: mise is never called"
  assert_file_absent "$cache"
else
  if [ "$has_zsh" = 1 ]; then
    # First start: one mise call writes the cache, which holds the dirs to prepend and the
    # other exports, never a PATH. The shell has them and has not activated mise.
    rm -f "$cache"; reset_logs
    assert_eq "$(wz 'exit')" "" "WSL1 zsh: the first start prints nothing"
    assert_eq "$(calls "$fxw/log")" 1 "WSL1 zsh: the first start calls mise once (to write the cache)"
    assert_ok "and that call is mise env" -- grep -q '^env ' "$fxw/log"
    assert_eq "$(sed -n 1p "$cache")" "# df-mise-dirs $dirs" "the cache's first line lists the dirs to prepend"
    assert_eq "$(sed -n 2p "$cache")" "# df-mise-bin $fxw/bin/mise" "its second line names the mise that wrote it"
    assert_ok "the other exports are in it" -- grep -qx "export VIRTUAL_ENV=$fxw/venv" "$cache"
    assert_eq "$(sed 1,2d "$cache" | grep -c '^export PATH=' || true)" 0 "no PATH of the generating shell is in it"
    assert_eq "$(wz 'print -r -- ${(j: :)${(s.:.)PATH}[1,3]}')" "$fxw/venv/bin $fxw/tools/a $fxw/tools/b" "WSL1 zsh: the tool dirs are in front of PATH"
    assert_eq "$(wz 'print -r -- $VIRTUAL_ENV')" "$fxw/venv" "WSL1 zsh: VIRTUAL_ENV comes from the cache"
    assert_eq "$(wz 'print -r -- ${+functions[_mise_hook]}')" 0 "WSL1 zsh: mise is not activated"
    # Later starts and the prompt hooks make no mise call at all.
    reset_logs
    wz 'exit' >/dev/null
    assert_eq "$(calls "$fxw/log")" 0 "WSL1 zsh: a start with a fresh cache makes zero mise calls"
    wz 'for f in $precmd_functions; do $f; done' >/dev/null
    assert_eq "$(calls "$fxw/log")" 0 "WSL1 zsh: the precmd hooks make zero mise calls"
    # A mise project config switches to the normal activation, at start or after a cd.
    assert_eq "$(wz "cd $fxw/proj/sub; print -r -- \${+functions[_mise_hook]} \${DF_TEST_ACTIVATED:-none}")" "1 1" "WSL1 zsh: cd into a project switches to mise activate"
    assert_ok "and activate was called" -- grep -q '^activate zsh' "$fxw/log"
    assert_eq "$(wz "cd $fxw/proj/sub; print -r -- \${chpwd_functions[(r)_df_mise_chpwd]:-gone}")" gone "WSL1 zsh: our chpwd hook is gone after the switch"
    assert_eq "$(wz "cd $fxw/proj; print -r -- \${+functions[_mise_hook]}")" 1 "WSL1 zsh: the project directory itself counts"
    reset_logs
    assert_eq "$(wz "cd $fxw/plain; print -r -- \${+functions[_mise_hook]}")" 0 "WSL1 zsh: cd into a plain directory stays cached"
    assert_eq "$(calls "$fxw/log")" 0 "WSL1 zsh: and calls no mise"
    WZ_DIR="$fxw/proj/sub"
    reset_logs
    assert_eq "$(wz 'print -r -- ${+functions[_mise_hook]}')" 1 "WSL1 zsh: started inside a project: activated"
    assert_eq "$(grep -c '^env ' "$fxw/log" || true)" 0 "WSL1 zsh: and the cache is not touched for it"
    WZ_DIR="$HOME"
    # The global config under ~/.config/mise is no project config, neither at $HOME nor inside it.
    mkdir -p ~/.config/mise
    printf '[settings]\n' >~/.config/mise/config.toml
    assert_eq "$(wz 'cd ~/.config/mise; print -r -- ${+functions[_mise_hook]}')" 0 "WSL1 zsh: ~/.config/mise is not a project"
    assert_eq "$(wz 'cd ~; print -r -- ${+functions[_mise_hook]}')" 0 "WSL1 zsh: \$HOME with a global config is not a project"
    assert_eq "$(wz 'cd ~/.config; print -r -- ${+functions[_mise_hook]}')" 0 "WSL1 zsh: ~/.config is not a project either"
    printf '[tools]\n' >~/mise.toml
    assert_eq "$(wz 'cd ~; print -r -- ${+functions[_mise_hook]}')" 1 "WSL1 zsh: a mise.toml in \$HOME is a project config"
    rm -f ~/mise.toml ~/.config/mise/config.toml
    # Staleness: a touched config, then a new install, each regenerate once.
    wz 'exit' >/dev/null # fresh again
    sleep 1
    touch ~/.config/mise/conf.d/dotfiles.toml
    reset_logs
    wz 'exit' >/dev/null
    assert_eq "$(calls "$fxw/log")" 1 "WSL1 zsh: a touched mise config regenerates the cache once"
    wz 'exit' >/dev/null
    assert_eq "$(calls "$fxw/log")" 1 "WSL1 zsh: and the next start makes no call"
    sleep 1
    mkdir -p ~/.local/share/mise/installs/stubtool/1.0
    reset_logs
    wz 'exit' >/dev/null
    assert_eq "$(calls "$fxw/log")" 1 "WSL1 zsh: a new tool install regenerates the cache once"
    wz 'exit' >/dev/null
    assert_eq "$(calls "$fxw/log")" 1 "WSL1 zsh: and then it is fresh again"
    # A mise that cannot print its environment: back to mise activate, silently, no cache left.
    rm -f "$cache"; reset_logs
    export DF_TEST_MISE_FAIL=1
    assert_eq "$(wz 'print -r -- ${+functions[_mise_hook]}')" 1 "WSL1 zsh: a failing mise env falls back to mise activate (silently)"
    unset DF_TEST_MISE_FAIL
    assert_file_absent "$cache"
    assert_eq "$(ls ~/.cache/dotfiles | grep -c mise-env || true)" 0 "no temporary file is left behind"
    # A PATH line in any other form than the plain single-quoted one is refused too: sourced from the
    # cache it would replace the whole PATH of the shell.
    rm -f "$cache"; reset_logs
    export DF_TEST_MISE_DQ=1
    assert_eq "$(wz 'print -r -- ${+functions[_mise_hook]}')" 1 "WSL1 zsh: a PATH line mise prints in another form falls back to mise activate"
    unset DF_TEST_MISE_DQ
    assert_file_absent "$cache"
    # Reloading with `source ~/.zshrc` (env.sh is not run again, so what it defined is gone after the
    # first start): clean, and a reload in WSL1 mode leaves WSL1 mode as it was, with no second
    # prepend of the dirs, no second chpwd hook and no mise call.
    wz 'exit' >/dev/null # a fresh cache
    reset_logs
    assert_eq "$(wz "source ~/.zshrc; print -r -- \${(j: :)\${(s.:.)PATH}[1,3]}")" "$fxw/venv/bin $fxw/tools/a $fxw/tools/b" "WSL1 zsh: source ~/.zshrc prints nothing and keeps the cached dirs in front"
    assert_eq "$(wz "source ~/.zshrc; print -r -- \${#\${(M)path:#$fxw/tools/a}} \${#\${(M)chpwd_functions:#_df_mise_chpwd}} \${+functions[_mise_hook]}")" "1 1 0" "WSL1 zsh: a reload prepends the dirs once, keeps one chpwd hook and does not activate"
    assert_eq "$(wz "source ~/.zshrc; source ~/.zshrc; print -r -- \$VIRTUAL_ENV")" "$fxw/venv" "WSL1 zsh: two reloads are clean too"
    assert_eq "$(calls "$fxw/log")" 0 "WSL1 zsh: a reload makes zero mise calls"
    assert_eq "$(wz "cd $fxw/proj/sub; source ~/.zshrc; print -r -- \${+functions[_mise_hook]}")" 1 "WSL1 zsh: a reload after the switch is clean and stays activated"
    # Native Linux and WSL2: mise activate as always, nothing cached.
    for PV in /nonexistent "$wsl2"; do
      rm -f "$cache"; reset_logs
      assert_eq "$(wz 'print -r -- ${+functions[_mise_hook]}')" 1 "zsh without WSL1 ($PV): mise is activated"
      assert_ok "and activate ran" -- grep -q '^activate zsh' "$fxw/log"
      assert_eq "$(grep -c '^env ' "$fxw/log" || true)" 0 "zsh without WSL1 ($PV): no cache is generated"
      assert_file_absent "$cache"
      assert_eq "$(wz 'source ~/.zshrc; print -r -- ${+functions[_mise_hook]}')" 1 "zsh without WSL1 ($PV): source ~/.zshrc is clean"
    done
    PV="$wsl1"
  fi

  # bash does the same through a PROMPT_COMMAND entry.
  rm -f "$cache"; reset_logs
  assert_eq "$(wb 'echo "@@$(declare -F _mise_hook)@@"')" "" "WSL1 bash: not activated"
  assert_eq "$(calls "$fxw/log")" 1 "WSL1 bash: the first start calls mise once"
  reset_logs
  assert_eq "$(wb 'IFS=: read -ra p <<<"$PATH"; echo "@@${p[0]} ${p[1]} ${p[2]}@@"; echo "@@$VIRTUAL_ENV@@"')" "$fxw/venv/bin $fxw/tools/a $fxw/tools/b
$fxw/venv" "WSL1 bash: tool dirs in front and VIRTUAL_ENV from the cache"
  assert_eq "$(calls "$fxw/log")" 0 "WSL1 bash: a start with a fresh cache and its prompts make zero mise calls"
  assert_eq "$(wb 'cd '"$fxw"'/proj/sub
echo "@@$(declare -F _mise_hook) ${DF_TEST_ACTIVATED:-none}@@"')" "_mise_hook 1" "WSL1 bash: cd into a project switches to mise activate"
  assert_ok "and activate was called" -- grep -q '^activate bash' "$fxw/log"
  reset_logs
  assert_eq "$(wb 'cd '"$fxw"'/plain
echo "@@$(declare -F _mise_hook)@@"')" "" "WSL1 bash: cd into a plain directory stays cached"
  assert_eq "$(calls "$fxw/log")" 0 "WSL1 bash: and calls no mise"
  # The entry hands the status of the last command on to the next one, whether the directory
  # changed (the hook does its work) or not. Called by hand, as the distributions' own entries
  # in front of it (the title of Rocky's /etc/bashrc) would change the status first.
  assert_eq "$(wb '_df_mise_pwd=elsewhere; (exit 3); _df_mise_prompt; echo "@@rc=$?@@"
(exit 4); _df_mise_prompt; echo "@@rc=$?@@"')" "rc=3
rc=4" "WSL1 bash: the prompt hook hands the exit status on"
  reset_logs
  WZ_DIR="$fxw/proj"
  assert_eq "$(wb 'echo "@@$(declare -F _mise_hook)@@"')" "_mise_hook" "WSL1 bash: started inside a project: activated"
  WZ_DIR="$HOME"
  # `source ~/.bashrc`: no stderr, the cached dirs still in front (env.sh puts the shims there
  # first), one PROMPT_COMMAND entry of ours, no activation and no mise call.
  wb 'true' >/dev/null # a fresh cache
  reset_logs
  assert_eq "$(wb 'source ~/.bashrc 2>'"$fxw"'/err
IFS=: read -ra p <<<"$PATH"; echo "@@${p[0]} ${p[1]} ${p[2]}@@"
echo "@@$(wc -c <'"$fxw"'/err | tr -d " ")@@"
echo "@@$(grep -o _df_mise_prompt <<<"$PROMPT_COMMAND" | wc -l | tr -d " ") $(declare -F _mise_hook | wc -l | tr -d " ")@@"')" "$fxw/venv/bin $fxw/tools/a $fxw/tools/b
0
1 0" "WSL1 bash: source ~/.bashrc keeps WSL1 mode (dirs in front, no stderr, one hook entry, not activated)"
  assert_eq "$(calls "$fxw/log")" 0 "WSL1 bash: a reload makes zero mise calls"
  assert_eq "$(wb 'cd '"$fxw"'/proj/sub
source ~/.bashrc 2>'"$fxw"'/err
echo "@@$(wc -c <'"$fxw"'/err | tr -d " ")@@"
echo "@@$(declare -F _mise_hook)@@"')" "0
_mise_hook" "WSL1 bash: a reload after the switch is clean and stays activated"
  # Non-interactive shells: the real dirs replace the shims, appended last, nothing printed, no mise.
  wb 'true' >/dev/null
  sleep 1
  touch ~/.config/mise/conf.d/dotfiles.toml
  wb 'true' >/dev/null # regenerates
  reset_logs
  assert_eq "$(path_tail bash)" "$dirs" "WSL1 non-interactive bash: the real tool dirs come last, in place of the shims"
  assert_eq "$(ne bash '. ~/.bashrc; echo ok')" ok "WSL1 non-interactive bash prints nothing"
  assert_eq "$(ne bash '. ~/.bashrc; echo "${VIRTUAL_ENV:-unset}"')" unset "WSL1 non-interactive bash: only the dirs are applied, no other export"
  if [ "$has_zsh" = 1 ]; then
    assert_eq "$(path_tail zsh)" "$dirs" "WSL1 non-interactive zsh: the real tool dirs come last"
    assert_eq "$(ne zsh 'echo ok')" ok "WSL1 non-interactive zsh prints nothing"
  fi
  assert_eq "$(calls "$fxw/log")" 0 "WSL1 non-interactive shells never call mise"
  sleep 1
  touch ~/.config/mise/conf.d/dotfiles.toml
  assert_eq "$(path_tail bash)" "$HOME/.local/share/mise/shims" "WSL1 non-interactive bash with a stale cache: the shims, as before"
  if [ "$has_zsh" = 1 ]; then
    assert_eq "$(path_tail zsh)" "$HOME/.local/share/mise/shims" "WSL1 non-interactive zsh with a stale cache: the shims"
  fi
  assert_eq "$(calls "$fxw/log")" 0 "and still no mise call"
  PV=/nonexistent
  rm -f "$cache"
  assert_eq "$(path_tail bash)" "$HOME/.local/share/mise/shims" "native non-interactive bash: the shims"
  reset_logs
  assert_eq "$(wb 'echo "@@$(declare -F _mise_hook)@@"')" "_mise_hook" "native bash: mise activate runs"
  assert_eq "$(wb 'source ~/.bashrc 2>'"$fxw"'/err
echo "@@$(wc -c <'"$fxw"'/err | tr -d " ")@@"')" "0" "native bash: source ~/.bashrc has no stderr"
  assert_ok "and activate was called" -- grep -q '^activate bash' "$fxw/log"
  assert_file_absent "$cache"
  PV="$wsl1"

  # case_wsl1_long_path: on WSL the terminal's PATH has the Windows entries appended (60 entries,
  # 2.8 KB here), and a non-interactive shell that ran env.sh before it had appended the 32 cached
  # dirs. Putting them in front is then 32 removals from a long PATH: with the old pattern loop
  # that took seconds (zsh -i 3.5 s, bash -i 1.4 s on the docker host with one cpu; a start is
  # about 0.3 s). The fixture's /mnt/ entries are not filtered (DF_WSL_MNT_PREFIX points
  # elsewhere), as on a host whose Windows directories are not under /mnt/.
  many="$(many_dirs "$fxw/many")"
  lp="$(long_path)"
  many1="${many%%:*}"
  many3="$(IFS=: read -r a b c _ <<<"$many"; printf '%s %s %s' "$a" "$b" "$c")"
  long_env() { ( export PATH="$lp:$HOME/.local/bin:$many" DF_WSL_MNT_PREFIX=/nowhere/; "$@" ); }
  # start_ms <command...>: milliseconds the command takes under the long environment.
  start_ms() {
    local t0
    t0=$(date +%s%N)
    long_env "$@" >/dev/null
    echo $((($(date +%s%N) - t0) / 1000000))
  }
  rm -f "$cache"
  DF_TEST_MISE_DIRS="$many" wb 'true' >/dev/null # the cache now lists the 32 dirs
  assert_eq "$(sed -n 1p "$cache")" "# df-mise-dirs $many" "the long-path cache holds the 32 dirs"
  reset_logs
  assert_eq "$(long_env wb 'IFS=: read -ra p <<<"$PATH"; echo "@@${p[0]} ${p[1]} ${p[2]}@@"; n=0; m=0; for e in "${p[@]}"; do case $e in *Vendor-*) n=$((n + 1)) ;; */installs/tool-*) m=$((m + 1)) ;; esac; done; echo "@@$n $m@@"')" \
    "$many3
54 32" "long PATH, bash: the cached dirs are in front, each once, and none of the 54 host entries was lost"
  assert_eq "$(calls "$fxw/log")" 0 "long PATH, bash: and mise is not called"
  times=()
  for _ in 1 2 3; do times+=("$(start_ms wb 'true')"); done
  median="$(median_ms "${times[@]}")"
  printf '  bash -i, long PATH, 32 cached dirs: %s ms (%s)\n' "$median" "${times[*]}" >&2
  assert_ok "bash -i on a long WSL PATH starts in ${median} ms, under 600 ms" -- test "$median" -lt 600
  if [ "$has_zsh" = 1 ]; then
    assert_eq "$(long_env wz 'print -r -- ${(j: :)${(s.:.)PATH}[1,3]}; print -r -- ${#${(M)path:#*Vendor-*}} ${#${(M)path:#*/installs/tool-*}}')" \
      "$many3
54 32" "long PATH, zsh: the cached dirs are in front, each once, and none of the 54 host entries was lost"
    times=()
    for _ in 1 2 3; do times+=("$(start_ms wz exit)"); done
    median="$(median_ms "${times[@]}")"
    printf '  zsh -i, long PATH, 32 cached dirs: %s ms (%s)\n' "$median" "${times[*]}" >&2
    assert_ok "zsh -i on a long WSL PATH starts in ${median} ms, under 1000 ms" -- test "$median" -lt 1000
    # The first cd into a project drops the cached dirs again (32 more removals in the old code).
    assert_eq "$(long_env wz "cd $fxw/proj/sub; print -r -- \${#\${(M)path:#*Vendor-*}} \${#\${(M)path:#*/installs/tool-*}} \${+functions[_mise_hook]}")" "54 0 1" "long PATH, zsh: the switch to mise activate takes the cached dirs off and nothing else"
  fi
  rm -f "$cache"
  unset -f long_env start_ms

  # case_fzf_tab_gate_without_a_process: the cache of tools.sh decides, not `fzf --zsh`.
  if [ "$has_zsh" = 1 ]; then
    PV=/nonexistent
    rm -rf ~/.cache/dotfiles/init; reset_logs
    assert_eq "$(wz 'print -r -- $+functions[fzf-tab-complete]')" 1 "fzf-tab gate without a cache: the old check runs once and fzf-tab loads"
    assert_ok "and that start wrote fzf's init cache" -- grep -qx "# df-init bin=$fxw/bin/fzf" "$HOME/.cache/dotfiles/init/fzf-zsh"
    cp -p "$HOME/.cache/dotfiles/init/fzf-zsh" "$fxw/fzf-zsh.saved"
    reset_logs
    assert_eq "$(wz 'print -r -- $+functions[fzf-tab-complete]')" 1 "fzf-tab gate with the cache: fzf-tab is loaded"
    assert_eq "$(calls "$fxw/fzf-log")" 0 "fzf-tab gate with the cache: zsh -i runs fzf zero times"
    assert_eq "$(wz 'bindkey "^I"')" '"^I" fzf-completion' "fzf's bindings still come last"
    assert_eq "$(wz 'print -r -- $fzf_default_completion')" fzf-tab-complete "fzf still falls back to fzf-tab"
    assert_eq "$(wz 'zstyle -L ":completion:*" menu')" "zstyle ':completion:*' menu no" "fzf-tab still sees the whole list"
    assert_eq "$(cat "$HOME/.cache/dotfiles/init/fzf-zsh")" "$(cat "$fxw/fzf-zsh.saved")" "the gate does not touch the cache"
    assert_eq "$(zsh_load_order "$(timeout 30 script -qec "TERM=xterm-256color PATH='$fxw/bin':\$PATH zsh -i -x -c exit" /dev/null </dev/null | tr -d '\r')")" "compinit fzf-tab autosuggestions tools" "the load order is unchanged"
    # A cache whose binary is gone proves nothing: the old check decides, and tools.sh re-keys the cache.
    { printf '# df-init bin=%s/gone/fzf\n' "$fxw"; sed 1d "$fxw/fzf-zsh.saved"; } >"$HOME/.cache/dotfiles/init/fzf-zsh"
    reset_logs
    assert_eq "$(wz 'print -r -- $+functions[fzf-tab-complete]')" 1 "fzf-tab gate with a cache of a vanished binary: the old check loads fzf-tab"
    assert_ok "and fzf was run" -- test "$(calls "$fxw/fzf-log")" -ge 1
    assert_ok "and the cache points at the fzf in use again" -- grep -qx "# df-init bin=$fxw/bin/fzf" "$HOME/.cache/dotfiles/init/fzf-zsh"
    PV="$wsl1"
  fi
fi
rm -rf "$fxw" ~/.cache/dotfiles/init "$cache" ~/.local/share/mise
unset DF_TEST_MISE_LOG DF_TEST_FZF_LOG DF_TEST_VENV DF_TEST_MISE_DIRS DF_TEST_MISE_FAIL DF_TEST_MISE_DQ

# --- non-interactive stays silent with the full bashrc ------------------------
assert_eq "$(bash -c '. ~/.bashrc; echo ok' 2>&1)" "ok" "ssh-like bashrc still silent and stderr-clean"
assert_eq "$(bash -lc 'echo ok' 2>&1)" "ok" "bash -lc still silent"
