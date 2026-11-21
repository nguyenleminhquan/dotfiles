# shellcheck shell=bash
# Bash only. Defines _df_prompt_command_add <function>, which appends a
# function to PROMPT_COMMAND once. Sourced by history.sh and prompt-minimal.sh
# so that either works on its own.

_df_prompt_command_add() {
  local pc
  if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    for pc in "${PROMPT_COMMAND[@]}"; do
      [[ $pc == "$1" ]] && return 0
    done
    PROMPT_COMMAND+=("$1")
    return 0
  fi
  pc="${PROMPT_COMMAND-}"
  [[ $pc == *"$1"* ]] && return 0
  # An existing value may end in ";" or a newline; joining must stay valid.
  while [[ $pc == *[[:space:]] || $pc == *';' ]]; do pc="${pc%?}"; done
  # shellcheck disable=SC2178
  PROMPT_COMMAND="${pc:+$pc; }$1"
}
