# shellcheck shell=bash
# Pure-shell prompt for the minimal profile and for hosts without starship:
#   user@host cwd [context/namespace] $
# The kubernetes part is bold red when the context name contains "prod". It
# reads the kubeconfig files directly and never runs kubectl, so a slow or
# unreachable cluster cannot slow the prompt down.
# Sourced from ~/.bashrc and ~/.zshrc; defines functions and sets the prompt.
#
# Cost: kubeconfigs can be large (certificate data comes before
# current-context) and zsh reads a file one byte at a time, so the files are
# never read with a shell loop. One awk pass reads them in blocks, and the
# result is cached in ~/.cache/dotfiles/kube-prompt until a file changes.

# _df_kube_list: set _df_kube_key to the colon-separated list of kubeconfig
# files that exist ($KUBECONFIG, or ~/.kube/config when it is empty). No forks.
_df_kube_list() {
  local list="${KUBECONFIG:-$HOME/.kube/config}:" file
  _df_kube_key=''
  while [[ -n $list ]]; do
    file="${list%%:*}"
    list="${list#*:}"
    [[ -n $file && -f $file && -r $file ]] && _df_kube_key="${_df_kube_key:+$_df_kube_key:}$file"
  done
  return 0
}

# _df_kube_scan <context>: for the files in _df_kube_key print
# "<current-context>\t<namespace>". current-context comes from the first file
# that sets one; the namespace is the one of <context> (default: the current
# one) from the first file that defines that context. Handles `name:` before
# or after `context:`, nested lists such as minikube's extensions, quoted
# values, trailing comments and CRLF line endings.
_df_kube_scan() {
  local want="${1:-}" rest="$_df_kube_key:"
  set --
  while [[ -n $rest ]]; do
    set -- "$@" "${rest%%:*}"
    rest="${rest#*:}"
  done
  # The name goes through the environment because awk -v would process
  # backslash escapes in it.
  DF_KUBE_WANT="$want" awk '
    function clean(s) {
      sub(/^[ \t]+/, "", s)
      if (s ~ /^"/) { sub(/^"/, "", s); sub(/".*$/, "", s) }
      else if (s ~ /^\047/) { sub(/^\047/, "", s); sub(/\047.*$/, "", s) }
      else { sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s) }
      return s
    }
    function flush() {
      if (inentry && name != "" && !(name in nsof)) nsof[name] = ns
      inentry = 0; name = ""; ns = ""
    }
    { sub(/\r$/, "") }
    FNR == 1 { flush(); incontexts = 0; dashind = -1 }
    /^[ \t]*(#|$)/ { next }
    /^[A-Za-z]/ {
      flush()
      if ($0 ~ /^current-context:/ && ctx == "") {
        v = $0; sub(/^current-context:/, "", v); ctx = clean(v)
      }
      incontexts = ($0 ~ /^contexts:/)
      dashind = -1
      next
    }
    !incontexts { next }
    {
      line = $0
      match(line, /[^ \t]/); ind = RSTART - 1
      if (line ~ /^[ \t]*-([ \t]|$)/) {
        if (dashind < 0) dashind = ind
        if (ind != dashind) next
        flush()
        inentry = 1
        rest = line; sub(/^[ \t]*-[ \t]*/, "", rest)
        keyind = length(line) - length(rest)
        line = rest; ind = keyind
      }
      if (!inentry) next
      sub(/^[ \t]+/, "", line)
      if (ind == keyind && line ~ /^name:/) { sub(/^name:/, "", line); name = clean(line) }
      else if (ind > keyind && line ~ /^namespace:/) { sub(/^namespace:/, "", line); ns = clean(line) }
    }
    END {
      flush()
      w = ENVIRON["DF_KUBE_WANT"]
      if (w == "") w = ctx
      printf "%s\t%s\n", ctx, ((w in nsof) ? nsof[w] : "")
    }
  ' "$@"
}

# df_kube_context: print current-context of the first file in $KUBECONFIG
# (colon-separated) that sets one, or of ~/.kube/config when KUBECONFIG is
# empty. Prints nothing and succeeds when there is none.
df_kube_context() {
  local out
  _df_kube_list
  [[ -n $_df_kube_key ]] || return 0
  out="$(_df_kube_scan '')"
  printf '%s\n' "${out%%$'\t'*}"
  return 0
}

# df_kube_namespace <context>: print the namespace set on that context in the
# kubeconfig files (first definition wins), or "default".
df_kube_namespace() {
  local out ns=''
  if [[ -n ${1:-} ]]; then
    _df_kube_list
    if [[ -n $_df_kube_key ]]; then
      out="$(_df_kube_scan "$1")"
      ns="${out#*$'\t'}"
    fi
  fi
  printf '%s\n' "${ns:-default}"
  return 0
}

# df_kube_is_prod <context>: succeed when the name contains "prod", any case.
df_kube_is_prod() {
  local re='[Pp][Rr][Oo][Dd]'
  [[ ${1:-} =~ $re ]]
}

# _df_kube_segment: set _df_kube_label ("context/namespace", or empty when
# there is no kubeconfig) and _df_kube_prod (1 or 0). Characters outside a
# conservative set become "?" so a hostile context name cannot inject escape
# sequences or expansions into the prompt.
_df_kube_segment() {
  local ctx='' ns='' out dir cache key='' f fresh=0
  _df_kube_label=''
  _df_kube_prod=0
  _df_kube_list
  [[ -n $_df_kube_key ]] || return 0

  dir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
  cache="$dir/kube-prompt"
  # Cache: line 1 the file list, line 2 the context, line 3 the namespace. It
  # holds while every file is strictly older than the cache file (an edit in
  # the same second as the cache write therefore counts as a change).
  if [[ -f $cache ]] && { IFS= read -r key && IFS= read -r ctx && IFS= read -r ns; } <"$cache" 2>/dev/null &&
    [[ $key == "$_df_kube_key" && -n $ns ]]; then
    fresh=1
    local rest="$_df_kube_key:"
    while [[ -n $rest ]]; do
      f="${rest%%:*}"
      rest="${rest#*:}"
      [[ $f -ot $cache ]] || { fresh=0; break; }
    done
  fi
  if [[ $fresh == 0 ]]; then
    out="$(_df_kube_scan '')"
    ctx="${out%%$'\t'*}"
    ns="${out#*$'\t'}"
    ns="${ns:-default}"
    [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null || :
    { printf '%s\n%s\n%s\n' "$_df_kube_key" "$ctx" "$ns" >"$cache"; } 2>/dev/null || :
  fi

  [[ -n $ctx ]] || return 0
  if df_kube_is_prod "$ctx"; then _df_kube_prod=1; fi
  ctx="${ctx//[^A-Za-z0-9._:@\/-]/?}"
  ns="${ns//[^A-Za-z0-9._:@\/-]/?}"
  _df_kube_label="$ctx/$ns"
  return 0
}

if [[ -n ${ZSH_VERSION:-} ]]; then
  _df_prompt_precmd() {
    local rc=$? seg=''
    _df_kube_segment
    if [[ -n $_df_kube_label ]]; then
      if [[ $_df_kube_prod == 1 ]]; then
        seg=" %B%F{red}[$_df_kube_label]%f%b"
      else
        seg=" [$_df_kube_label]"
      fi
    fi
    PROMPT="%n@%m %~${seg} %(!.#.\$) "
    return "$rc"
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _df_prompt_precmd
  # shellcheck disable=SC2034
  PROMPT='%n@%m %~ %(!.#.$) '
else
  _df_prompt_update() {
    local rc=$?
    _df_ps1_kube=''
    _df_kube_segment
    if [[ -n $_df_kube_label ]]; then
      # \001 and \002 tell readline the enclosed bytes take no screen width.
      if [[ $_df_kube_prod == 1 ]]; then
        _df_ps1_kube=$' \001\e[1;31m\002'"[$_df_kube_label]"$'\001\e[0m\002'
      else
        _df_ps1_kube=" [$_df_kube_label]"
      fi
    fi
    return "$rc"
  }
  if ! declare -F _df_prompt_command_add >/dev/null 2>&1 && [[ -r ${BASH_SOURCE[0]%/*}/prompt-command.sh ]]; then
    # shellcheck source=/dev/null
    . "${BASH_SOURCE[0]%/*}/prompt-command.sh"
  fi
  _df_prompt_command_add _df_prompt_update
  # The segment sits in a variable so its value is never itself expanded.
  # shellcheck disable=SC2016
  PS1='\u@\h \w${_df_ps1_kube} \$ '
fi
