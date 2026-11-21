# shellcheck shell=bash
# Command history for interactive bash and zsh: sizes, sharing between
# sessions, and a filter that keeps secrets out of the history file.
# Sourced from ~/.bashrc and ~/.zshrc; it defines functions and settings only
# and prints nothing.

# df_history_is_secret <line>: succeed when the command line looks like it
# carries a secret. Only assignments such as `token=...` and key-shaped strings
# count, so `kubectl create token sa` is still remembered. Keyword classes are
# spelled out as [Aa] pairs because bash and zsh disagree on how to ignore case.
df_history_is_secret() {
  local line="$1"
  local re_pem='-----BEGIN'
  local re_assign='([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy])='
  local re_header='[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:'
  local re_aws='AKIA[0-9A-Z]{16}'
  local re_github='ghp_[A-Za-z0-9]{36}'
  local re_gitlab='glpat-[A-Za-z0-9_-]{20}'
  [[ $line =~ $re_pem ]] && return 0
  [[ $line =~ $re_assign ]] && return 0
  [[ $line =~ $re_header ]] && return 0
  [[ $line =~ $re_aws ]] && return 0
  [[ $line =~ $re_github ]] && return 0
  [[ $line =~ $re_gitlab ]] && return 0
  return 1
}

if [[ -n ${ZSH_VERSION:-} ]]; then
  HISTFILE="$HOME/.zsh_history"
  HISTSIZE=100000
  # shellcheck disable=SC2034
  SAVEHIST=100000
  setopt share_history hist_ignore_space hist_ignore_all_dups

  # A non-zero status from a zshaddhistory hook keeps the line out of the
  # history list and file.
  _df_zsh_addhistory() {
    df_history_is_secret "$1" && return 1
    return 0
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook zshaddhistory _df_zsh_addhistory
else
  HISTSIZE=100000
  HISTFILESIZE=100000
  HISTCONTROL=ignoreboth
  shopt -s histappend

  # Runs before every prompt: drop the command that just finished from the
  # in-memory history when it is a secret, then append the new lines to the
  # history file (which also shares them with other sessions).
  _df_bash_history_filter() {
    local entry num cmd
    # "  123* the command line": number (starred when edited), then the text.
    entry="$(HISTTIMEFORMAT='' history 1)"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    num="${entry%%[[:space:]]*}"
    cmd="${entry#"$num"}"
    num="${num%\*}"
    if [[ $num =~ ^[0-9]+$ ]] && df_history_is_secret "$cmd"; then
      history -d "$num"
    fi
    history -a
  }

  # Append a function to PROMPT_COMMAND once, whether it is a string or an array.
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
  _df_prompt_command_add _df_bash_history_filter
fi
