# shellcheck shell=bash
# Interactive tool integration, shared by ~/.bashrc and ~/.zshrc: mise
# activation, starship (or the pure-shell prompt), fzf and zoxide. Defines
# nothing that stays behind except what the tools' own init scripts define (and,
# in WSL1 mode, the hook that switches to `mise activate` inside a project).
#
# The server and workstation profiles use the tools; minimal never does (a
# system fzf or starship on a prod host must not change its prompt or keys).
# Each tool that is missing is skipped, so a half-installed host still works.
#
# Startup cost: the init scripts of starship, fzf and zoxide are cached in
# ~/.cache/dotfiles/init/, so a shell start reads a file instead of running three
# programs. mise is the exception: its activation script embeds the current PATH
# and cannot be cached. On WSL1, where starting a process is slow, mise is replaced
# by a cache of the environment it would set up (see "WSL1 mode" below).

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
#
# WSL1 mode: starting a process is slow on WSL1 (`mise hook-env` takes about
# 0.6 s there, and `mise activate` runs it at start and before every prompt), so
# an interactive shell on WSL1 does not run `mise activate` at start. It applies
# a cache of what activation would put in place (shell/mise-cache.sh) and reads
# it with shell builtins only; see _df_mise_wsl1_start. Native Linux and WSL2 keep
# `mise activate`, which is upstream's documented mode and costs about 10 ms there.

# _df_mise_in_project: succeed when $PWD or a directory above it holds a mise
# project config. Builtins only; walks up to /. The global config under
# ~/.config/mise is not a project config, wherever the walk meets it.
_df_mise_in_project() {
  local d="$PWD" n p
  while :; do
    for n in mise.toml .mise.toml mise.local.toml .mise/config.toml mise/config.toml \
      .config/mise.toml .config/mise/config.toml .tool-versions; do
      p="${d%/}/$n"
      [[ $p == "$HOME/.config/mise/config.toml" ]] && continue
      [[ -f $p ]] && return 0
    done
    [[ -z $d || $d == / ]] && return 1
    d="${d%/*}"
    [[ -n $d ]] || d=/
  done
}

# _df_mise_switch: leave WSL1 mode for the normal `mise activate`, once, as soon as
# the shell is inside a project tree. The cached directories go off PATH first, so
# that the activation starts from the PATH it would have had; after it nothing of
# WSL1 mode is left, and mise's own hooks take over.
_df_mise_switch() {
  _df_mise_in_project || return 0
  local exe="$_df_mise_wsl1_bin" rest="$_df_mise_wsl1_dirs" d p sh=bash
  [[ -x $exe ]] || exe="$(command -v mise)"
  [[ -n $exe ]] || return 0
  [[ -n ${ZSH_VERSION:-} ]] && sh=zsh
  if [[ $sh == zsh ]]; then
    add-zsh-hook -d chpwd _df_mise_chpwd
    unfunction _df_mise_chpwd
  else
    _df_mise_prompt_stop
  fi
  while [[ -n $rest ]]; do
    d="${rest%%:*}"
    if [[ $rest == *:* ]]; then rest="${rest#*:}"; else rest=''; fi
    [[ -n $d ]] || continue
    p=":$PATH:"
    while [[ $p == *":$d:"* ]]; do p="${p/":$d:"/:}"; done
    p="${p#:}"
    PATH="${p%:}"
  done
  export PATH
  unset _df_mise_wsl1_bin _df_mise_wsl1_dirs _df_mise_pwd
  unset -f _df_mise_switch _df_mise_in_project
  [[ $sh == bash ]] && unset -f _df_mise_prompt_stop
  eval "$("$exe" activate "$sh")"
}

# bash: an entry of PROMPT_COMMAND that acts only when $PWD changed, and hands the
# exit status of the last command on to the next entry.
if [[ -z ${ZSH_VERSION:-} ]]; then
  _df_mise_prompt() {
    local rc=$?
    [[ $PWD == "$_df_mise_pwd" ]] && return "$rc"
    _df_mise_pwd="$PWD"
    _df_mise_switch
    return "$rc"
  }

  # After the switch the entry is taken out of PROMPT_COMMAND (the function stays, as
  # a no-op, for a PROMPT_COMMAND that was rebuilt by something else).
  _df_mise_prompt_stop() {
    local pc i
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
      for i in "${!PROMPT_COMMAND[@]}"; do
        [[ ${PROMPT_COMMAND[i]} == _df_mise_prompt ]] && unset 'PROMPT_COMMAND[i]'
      done
      PROMPT_COMMAND=("${PROMPT_COMMAND[@]}")
    else
      pc="${PROMPT_COMMAND-}"
      pc="${pc//"; _df_mise_prompt"/}"
      pc="${pc//"_df_mise_prompt; "/}"
      [[ $pc == _df_mise_prompt ]] && pc=''
      PROMPT_COMMAND="$pc"
    fi
    _df_mise_prompt() { return "$?"; }
  }
fi

# _df_mise_wsl1_start: WSL1 mode for an interactive shell with tools. Succeeds
# when it took the place of `mise activate`: the cache of the mise environment
# (regenerated here when stale or missing, by one mise call and silently) has been
# applied, the dirs in front of PATH and the other exports of the global config.
# Fails, so that the caller activates mise, when this is not WSL1, when the shell
# starts inside a project (the real activation is needed there anyway) or when
# the cache cannot be made. The helpers come from shell/env.sh.
_df_mise_wsl1_start() {
  typeset -f _df_mise_cache_read >/dev/null 2>&1 || return 1
  _df_wsl_detect
  [[ $_df_wsl == 1 ]] || return 1
  ! _df_mise_in_project || return 1
  if ! _df_mise_cache_read; then
    _df_tool_path mise
    [[ -n $_df_tp && -r $_df_tdir/shell/mise-cache.sh ]] || return 1
    # shellcheck source=shell/mise-cache.sh
    source "$_df_tdir/shell/mise-cache.sh"
    df_mise_cache_regen "$_df_tp" && _df_mise_cache_read || return 1
  fi
  _df_path_add_list front "$_df_mise_dirs"
  # shellcheck source=/dev/null
  source "$_df_mc"
  _df_mise_wsl1_dirs="$_df_mise_dirs"
  _df_mise_wsl1_bin="$_df_mise_bin"
  # The first cd into a project tree switches to the normal activation.
  if [[ -n ${ZSH_VERSION:-} ]]; then
    autoload -Uz add-zsh-hook
    _df_mise_chpwd() { _df_mise_switch; }
    add-zsh-hook chpwd _df_mise_chpwd
  else
    _df_mise_pwd="$PWD"
    _df_mise_hook_bash=1
  fi
  return 0
}

_df_tdir="${DOTFILES_DIR:-$HOME/.dotfiles}"
_df_mise_hook_bash=0
if [[ $_df_use_tools == 1 ]] && ! _df_mise_wsl1_start; then
  _df_tool_path mise
  if [[ -n $_df_tp ]]; then
    eval "$("$_df_tp" activate "$_df_sh")"
  fi
fi

# Prompt: starship when it can print its init script, the pure-shell prompt
# otherwise. Its kube helpers (df_kube_*) are loaded either way.
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

# WSL1 mode, bash: the PROMPT_COMMAND entry goes last, after what starship and zoxide
# did to PROMPT_COMMAND.
if [[ $_df_mise_hook_bash == 1 ]]; then
  if ! declare -F _df_prompt_command_add >/dev/null; then
    # shellcheck source=shell/prompt-command.sh
    source "$_df_tdir/shell/prompt-command.sh"
  fi
  _df_prompt_command_add _df_mise_prompt
fi

unset -f _df_tool_path _df_init_cache _df_mise_wsl1_start _df_wsl_detect _df_mise_cache_read _df_mise_cache_check _df_path_add_list
# Without WSL1 mode nothing of it stays behind (zsh complains about a function that
# was never defined, hence the loop).
if [[ -z ${_df_mise_wsl1_bin:-} ]]; then
  for _df_uf in _df_mise_switch _df_mise_in_project _df_mise_prompt _df_mise_prompt_stop; do
    unset -f "$_df_uf" 2>/dev/null
  done
  unset _df_uf
fi
unset _df_tools_profile _df_sh _df_tp _df_use_tools _df_tdir _df_starship _df_starship_file _df_init_file
unset _df_mc _df_mise_dirs _df_mise_bin _df_mise_hook_bash _df_wsl
