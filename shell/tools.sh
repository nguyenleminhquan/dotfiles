# shellcheck shell=bash
# Interactive tool integration, shared by ~/.bashrc and ~/.zshrc: mise
# activation, starship (or the pure-shell prompt), fzf and zoxide. Defines
# nothing that stays behind except what the tools' own init scripts define.
#
# The server and workstation profiles use the tools; minimal never does (a
# system fzf or starship on a prod host must not change its prompt or keys).
# Each tool that is missing is skipped, so a half-installed host still works.
#
# Startup cost: the init scripts of starship, fzf and zoxide are cached in
# ~/.cache/dotfiles/init/, so a shell start reads a file instead of running three
# programs. mise is the exception: its activation script embeds the current PATH
# and cannot be cached.

_df_tools_profile=''
if [[ -r $HOME/.config/dotfiles/profile ]]; then
  read -r _df_tools_profile <"$HOME/.config/dotfiles/profile" || :
fi

_df_sh=bash
[[ -n ${ZSH_VERSION:-} ]] && _df_sh=zsh

# _df_tool_path <tool>: set _df_tp to the executable's path, empty when there is none.
_df_tool_path() {
  if [[ -n ${ZSH_VERSION:-} ]]; then
    _df_tp="${commands[$1]:-}"
  else
    _df_tp="$(type -P "$1" 2>/dev/null)" || _df_tp=''
  fi
}

# _df_init_cache <tool> <cache name> <args...>: make sure the output of
# `<tool> <args>` is cached and set _df_init_file to the cache file. The first
# line records which binary produced it, so a new version (a new path) or a
# different install regenerates it. Fails, leaving nothing behind, when the
# tool cannot print an init script (for example an fzf older than 0.48).
_df_init_cache() {
  local tool="$1" name="$2" first='' dir="$HOME/.cache/dotfiles/init" cache tmp
  shift 2
  _df_tool_path "$tool"
  [[ -n $_df_tp ]] || return 1
  cache="$dir/$name"
  if [[ -r $cache ]]; then IFS= read -r first <"$cache" || :; fi
  if [[ $first != "# df-init bin=$_df_tp" ]]; then
    mkdir -p "$dir" 2>/dev/null || return 1
    tmp="$cache.$$"
    if { printf '# df-init bin=%s\n' "$_df_tp"; "$_df_tp" "$@"; } >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$cache" || return 1
    else
      rm -f "$tmp"
      return 1
    fi
  fi
  _df_init_file="$cache"
}

_df_use_tools=0
case $_df_tools_profile in
  server | workstation) _df_use_tools=1 ;;
esac

# mise first: its PATH entries put the real binaries in front of the shims,
# and the lookups below (and every later command) then skip the shim
# indirection, which costs about 40 ms per call.
if [[ $_df_use_tools == 1 ]]; then
  _df_tool_path mise
  if [[ -n $_df_tp ]]; then
    eval "$("$_df_tp" activate "$_df_sh")"
  fi
fi

# Prompt: starship when it can print its init script, the pure-shell prompt
# otherwise. Its kube helpers (df_kube_*) are loaded either way.
_df_tdir="${DOTFILES_DIR:-$HOME/.dotfiles}"
_df_starship=0
if [[ $_df_use_tools == 1 && ${TERM:-} != dumb ]] && _df_init_cache starship "starship-$_df_sh" init "$_df_sh" --print-full-init; then
  _df_starship=1
fi
if [[ $_df_starship == 1 ]]; then
  _df_starship_file="$_df_init_file"
  # Read by shell/prompt-minimal.sh.
  # shellcheck disable=SC2034
  DF_PROMPT_FUNCTIONS_ONLY=1
fi
if [[ -r $_df_tdir/shell/prompt-minimal.sh ]]; then
  # shellcheck source=/dev/null
  source "$_df_tdir/shell/prompt-minimal.sh"
fi
if [[ $_df_starship == 1 ]]; then
  unset DF_PROMPT_FUNCTIONS_ONLY
  # shellcheck source=/dev/null
  source "$_df_starship_file"
fi

# fzf key bindings and completion (fzf 0.48 or newer prints its own scripts).
# In zsh this replaces the Ctrl-R binding from ~/.zshrc. Only with a terminal on
# stdin: without one the line editor cannot be enabled, the scripts would print
# warnings, and key bindings are useless anyway (`ssh host zsh -ic cmd`).
if [[ $_df_use_tools == 1 && -t 0 ]] && _df_init_cache fzf "fzf-$_df_sh" "--$_df_sh"; then
  # shellcheck source=/dev/null
  source "$_df_init_file"
fi

# zoxide: `z` and `zi` (cd is left alone). Last, because its directory hook has
# to come after the prompt's own. Its data (~/.local/share/zoxide) is the user's,
# like the shell history: uninstall never removes it.
if [[ $_df_use_tools == 1 ]] && _df_init_cache zoxide "zoxide-$_df_sh" init "$_df_sh"; then
  # shellcheck source=/dev/null
  source "$_df_init_file"
fi

unset -f _df_tool_path _df_init_cache
unset _df_tools_profile _df_sh _df_tp _df_use_tools _df_tdir _df_starship _df_starship_file _df_init_file
