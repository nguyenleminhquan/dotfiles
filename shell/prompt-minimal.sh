# shellcheck shell=bash
# Pure-shell prompt for the minimal profile and for hosts without starship:
#   user@host cwd [context/namespace] $
# The kubernetes part is bold red when the context name contains "prod". It
# reads the kubeconfig files directly and never runs kubectl, so a slow or
# unreachable cluster cannot slow the prompt down.
# Sourced from ~/.bashrc and ~/.zshrc; defines functions and sets the prompt.

# df_kube_context: print current-context of the first file in $KUBECONFIG
# (colon-separated) that sets one, or of ~/.kube/config when KUBECONFIG is
# empty. Prints nothing and succeeds when there is none.
df_kube_context() {
  local list="${KUBECONFIG:-$HOME/.kube/config}:" file line
  while [[ -n $list ]]; do
    file="${list%%:*}"
    list="${list#*:}"
    [[ -n $file && -f $file && -r $file ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line == current-context:* ]] || continue
      line="${line#current-context:}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      line="${line#[\"\']}"
      line="${line%[\"\']}"
      if [[ -n $line ]]; then
        printf '%s\n' "$line"
        return 0
      fi
      break
    done <"$file"
  done
  return 0
}

# df_kube_namespace <context>: print the namespace set on that context in the
# kubeconfig files (first definition wins), or "default".
df_kube_namespace() {
  local want="${1:-}" list="${KUBECONFIG:-$HOME/.kube/config}:" file ns
  [[ -n $want ]] || {
    printf 'default\n'
    return 0
  }
  set --
  while [[ -n $list ]]; do
    file="${list%%:*}"
    list="${list#*:}"
    [[ -n $file && -f $file && -r $file ]] && set -- "$@" "$file"
  done
  if [[ $# -gt 0 ]] && ns="$(_df_kube_awk_namespace "$want" "$@")"; then
    printf '%s\n' "${ns:-default}"
  else
    printf 'default\n'
  fi
  return 0
}

# _df_kube_awk_namespace <context> <files...>: exit 0 and print the namespace
# (possibly empty) when a `contexts:` entry with that name exists. Handles
# `name:` before or after `context:` inside the entry.
_df_kube_awk_namespace() {
  local want="$1"
  shift
  # The name goes through the environment because awk -v would process
  # backslash escapes in it.
  DF_KUBE_WANT="$want" awk '
    function clean(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      sub(/^["\047]/, "", s); sub(/["\047]$/, "", s)
      return s
    }
    function flush() {
      if (inentry && name == ENVIRON["DF_KUBE_WANT"]) { print ns; found = 1 }
      inentry = 0; name = ""; ns = ""
    }
    FNR == 1 { flush(); if (found) exit; incontexts = 0 }
    /^[ \t]*#/ { next }
    /^[A-Za-z]/ {
      flush()
      if (found) exit
      incontexts = ($0 ~ /^contexts:/)
      next
    }
    !incontexts { next }
    {
      line = $0
      if (line ~ /^[ \t]*-([ \t]|$)/) {
        flush()
        if (found) exit
        inentry = 1
        sub(/^[ \t]*-[ \t]*/, "", line)
      }
      if (line ~ /^[ \t]*name:/) { sub(/^[ \t]*name:/, "", line); name = clean(line) }
      else if (line ~ /^[ \t]*namespace:/) { sub(/^[ \t]*namespace:/, "", line); ns = clean(line) }
    }
    END { if (!found) flush(); exit (found ? 0 : 1) }
  ' "$@"
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
  local ctx ns
  _df_kube_label=''
  _df_kube_prod=0
  ctx="$(df_kube_context)"
  [[ -n $ctx ]] || return 0
  ns="$(df_kube_namespace "$ctx")"
  if df_kube_is_prod "$ctx"; then _df_kube_prod=1; fi
  ctx="${ctx//[^A-Za-z0-9._:@\/-]/?}"
  ns="${ns//[^A-Za-z0-9._:@\/-]/?}"
  _df_kube_label="$ctx/$ns"
}

if [[ -n ${ZSH_VERSION:-} ]]; then
  _df_prompt_precmd() {
    local seg=''
    _df_kube_segment
    if [[ -n $_df_kube_label ]]; then
      if [[ $_df_kube_prod == 1 ]]; then
        seg=" %B%F{red}[$_df_kube_label]%f%b"
      else
        seg=" [$_df_kube_label]"
      fi
    fi
    PROMPT="%n@%m %~${seg} %(!.#.\$) "
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _df_prompt_precmd
  # shellcheck disable=SC2034
  PROMPT='%n@%m %~ %(!.#.$) '
else
  _df_prompt_update() {
    _df_ps1_kube=''
    _df_kube_segment
    [[ -n $_df_kube_label ]] || return 0
    # \001 and \002 tell readline the enclosed bytes take no screen width.
    if [[ $_df_kube_prod == 1 ]]; then
      _df_ps1_kube=$' \001\e[1;31m\002'"[$_df_kube_label]"$'\001\e[0m\002'
    else
      _df_ps1_kube=" [$_df_kube_label]"
    fi
  }
  if ! declare -F _df_prompt_command_add >/dev/null 2>&1; then
    _df_prompt_command_add() {
      # shellcheck disable=SC2178
      case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
        *"$1"*) return 0 ;;
        "declare -a"*) PROMPT_COMMAND+=("$1") ;;
        *) PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND%;}; }$1" ;;
      esac
    }
  fi
  _df_prompt_command_add _df_prompt_update
  # The segment sits in a variable so its value is never itself expanded.
  # shellcheck disable=SC2016
  PS1='\u@\h \w${_df_ps1_kube} \$ '
fi
