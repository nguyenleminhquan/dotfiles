# shellcheck shell=sh
# The cache of the mise environment that WSL1 mode reads instead of running
# `mise activate` (see shell/env.sh and shell/tools.sh). Sourced by an
# interactive shell that finds the cache stale or missing, and by
# lib/tools.sh at the end of an install or update. POSIX sh, so bash and zsh
# can both source it, and silent: a shell start must never print.
#
# The file, ~/.cache/dotfiles/mise-env.sh, is valid sh whose first two lines are
# comments that shell/env.sh reads without sourcing it:
#   # df-mise-dirs <dir>:<dir>:...   what mise puts in front of PATH, in order
#   # df-mise-bin <path>             the mise binary that wrote the cache
# followed by the other `export` lines of `mise env`, which an interactive shell
# sources (the venv of the workstation profile gives VIRTUAL_ENV). The PATH of the
# shell that generated it is never in it: mise runs with a PATH that holds one
# placeholder directory, and only what it puts in front of that is kept.

# df_mise_cache_regen <mise>: write the cache from the global mise config (mise
# runs in $HOME, with the caller's MISE_ENV). Atomic (a temporary file, then mv).
# Fails, leaving nothing behind, when mise fails or prints something unexpected
# (a PATH that is not a plain single-quoted value), so that the caller can fall
# back to `mise activate`.
df_mise_cache_regen() {
  _df_mg_exe="$1"
  _df_mg_dir="$HOME/.cache/dotfiles"
  _df_mg_file="$_df_mg_dir/mise-env.sh"
  _df_mg_base=/df-mise-base
  _df_mg_dirs=
  _df_mg_path=
  _df_mg_rest=
  _df_mg_bad=
  if [ ! -x "$_df_mg_exe" ] || ! mkdir -p "$_df_mg_dir" 2>/dev/null; then
    _df_mg_clean
    return 1
  fi
  if _df_mg_out="$(cd "$HOME" 2>/dev/null && PATH="$_df_mg_base" "$_df_mg_exe" env -s bash 2>/dev/null)"; then
    while IFS= read -r _df_mg_line; do
      case "$_df_mg_line" in
        "export PATH='"*"'")
          _df_mg_path="${_df_mg_line#export PATH=\'}"
          _df_mg_path="${_df_mg_path%\'}"
          ;;
        # Any other form of PATH would replace the shell's PATH when the cache is sourced.
        "export PATH="* | "PATH="* | "unset PATH"*) _df_mg_bad=1 ;;
        '') ;;
        *) _df_mg_rest="$_df_mg_rest$_df_mg_line
" ;;
      esac
    done <<EOF
$_df_mg_out
EOF
  else
    _df_mg_path=
  fi
  # What mise put in front of the placeholder; a quote in it, or no placeholder at
  # the end, is something this parser does not understand.
  [ -z "$_df_mg_bad" ] || _df_mg_path=
  case "$_df_mg_path" in
    *"'"* | '') _df_mg_path= ;;
    "$_df_mg_base") ;;
    *":$_df_mg_base") _df_mg_dirs="${_df_mg_path%":$_df_mg_base"}" ;;
    *) _df_mg_path= ;;
  esac
  _df_mg_ok=1
  if [ -n "$_df_mg_path" ]; then
    _df_mg_tmp="$_df_mg_file.$$"
    if {
      printf '# df-mise-dirs %s\n# df-mise-bin %s\n' "$_df_mg_dirs" "$_df_mg_exe"
      printf '%s' "$_df_mg_rest"
    } 2>/dev/null >"$_df_mg_tmp" && mv -f "$_df_mg_tmp" "$_df_mg_file" 2>/dev/null; then
      _df_mg_ok=0
    else
      rm -f "$_df_mg_tmp" 2>/dev/null
    fi
  fi
  if [ "$_df_mg_ok" = 0 ]; then
    _df_mg_clean
    return 0
  fi
  _df_mg_clean
  return 1
}

_df_mg_clean() {
  unset _df_mg_exe _df_mg_dir _df_mg_file _df_mg_base _df_mg_dirs _df_mg_path _df_mg_rest \
    _df_mg_out _df_mg_line _df_mg_tmp _df_mg_ok _df_mg_bad
}
