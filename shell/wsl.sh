# shellcheck shell=sh
# WSL tweaks. env.sh sources this file when /proc/version says WSL, which means
# every shell runs it, including `ssh host cmd` and scripts: POSIX sh, no
# output, no network, no cost worth measuring, and sourcing it twice changes
# nothing. It does three things:
#   - drops the Windows directories that `appendWindowsPath` puts on PATH
#     (each lookup in a missing command walks them over the slow 9p/drvfs
#     mount), except the ones that hold a tool people really use from WSL;
#   - turns a umask of 0000 (what WSL1 starts shells with) into 022;
#   - makes sure the session has a UTF-8 locale.
# Test-only knobs: DF_WSL_MNT_PREFIX (default /mnt/) and DF_WSL_LOCALE_DIR
# (default /usr/lib/locale).

# _df_wsl_filter <path string>: set _df_wf_result to the filtered PATH. No
# subshell: a shell start pays for no fork here. Entries are split on ":" only,
# so directories with spaces ("Microsoft VS Code") are fine, and empty entries
# are kept as they are.
_df_wsl_filter() {
  _df_wf_prefix="${DF_WSL_MNT_PREFIX:-/mnt/}"
  _df_wf_result=
  _df_wf_first=1
  _df_wf_rest="$1:"
  while [ -n "$_df_wf_rest" ]; do
    _df_wf_dir="${_df_wf_rest%%:*}"
    _df_wf_rest="${_df_wf_rest#*:}"
    _df_wf_keep=1
    case "$_df_wf_dir" in
      "$_df_wf_prefix"*)
        _df_wf_keep=0
        for _df_wf_f in code explorer.exe clip.exe powershell.exe wsl.exe docker; do
          if [ -e "$_df_wf_dir/$_df_wf_f" ]; then
            _df_wf_keep=1
            break
          fi
        done
        ;;
    esac
    if [ "$_df_wf_keep" = 1 ]; then
      if [ "$_df_wf_first" = 1 ]; then
        _df_wf_result="$_df_wf_dir"
        _df_wf_first=0
      else
        _df_wf_result="$_df_wf_result:$_df_wf_dir"
      fi
    fi
  done
  unset _df_wf_prefix _df_wf_first _df_wf_rest _df_wf_dir _df_wf_keep _df_wf_f
}

# df_wsl_filter_path <path string>: print the string without the directories
# under the Windows mount (/mnt/ by default) that hold none of code,
# explorer.exe, clip.exe, powershell.exe, wsl.exe or docker. Everything else
# keeps its place.
df_wsl_filter_path() {
  _df_wsl_filter "$1"
  printf '%s\n' "$_df_wf_result"
  unset _df_wf_result
}

# PATH: nothing to do (and nothing to stat) when no entry is under the mount.
case ":$PATH:" in
  *":${DF_WSL_MNT_PREFIX:-/mnt/}"*)
    _df_wsl_filter "$PATH"
    PATH="$_df_wf_result"
    export PATH
    unset _df_wf_result
    ;;
esac

# umask: the shells have a builtin that prints it as 0000 (zsh: 000).
case "$(umask)" in
  0 | 00 | 000 | 0000) umask 022 ;;
esac

# Locale. A session that already has one of our values (a child of a shell that
# ran this) needs no work. Otherwise the answer comes from a one-line cache in
# ~/.cache/dotfiles/init, valid until the locale directory or the archive in it
# changes (installing a locale touches them), so `locale -a` runs once per
# change and not once per shell.
case "${LC_ALL:-}" in
  en_US.UTF-8 | C.UTF-8) ;;
  *)
    _df_wl_dir="${DF_WSL_LOCALE_DIR:-/usr/lib/locale}"
    _df_wl_cache="${HOME:-}/.cache/dotfiles/init/wsl-locale"
    _df_wl_val=
    if [ -r "$_df_wl_cache" ]; then
      read -r _df_wl_val <"$_df_wl_cache" || :
      if [ "$_df_wl_dir" -nt "$_df_wl_cache" ] || [ "$_df_wl_dir/locale-archive" -nt "$_df_wl_cache" ]; then
        _df_wl_val=
      fi
    fi
    case "$_df_wl_val" in
      en_US.UTF-8 | C.UTF-8) ;;
      *)
        _df_wl_val=C.UTF-8
        case "$(locale -a 2>/dev/null)" in
          *en_US.utf8*) _df_wl_val=en_US.UTF-8 ;;
        esac
        # Best effort: an unwritable HOME just means no cache.
        {
          mkdir -p "${_df_wl_cache%/*}" &&
            printf '%s\n' "$_df_wl_val" >"$_df_wl_cache.$$" &&
            mv -f "$_df_wl_cache.$$" "$_df_wl_cache"
        } 2>/dev/null || :
        ;;
    esac
    LANG="$_df_wl_val"
    LC_ALL="$_df_wl_val"
    export LANG LC_ALL
    unset _df_wl_dir _df_wl_cache _df_wl_val
    ;;
esac
