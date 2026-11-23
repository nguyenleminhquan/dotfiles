# shellcheck shell=sh
# Table of cases for the PATH helper of shell/env.sh. POSIX sh, sourced by dash, bash and zsh after
# env.sh (30-shell-startup.sh runs it in each of them). Prints one "FAIL: ..." line per wrong
# result and "path-cases-done" at the end, so a shell that never got there is noticed.
#
# Every case is: t <name> <mode> <argument> <PATH before> <PATH after>. The functions under test
# are _df_path_add (every shell) and _df_path_add_list (only where env.sh left it, that is in
# interactive shells); both take front|back|drop and a list of directories.

_pc_fails=0
_pc_ifs0="$IFS"
_pc_fn=_df_path_add

_pc_fail() {
  _pc_fails=$((_pc_fails + 1))
  # The first few are enough to see what broke.
  if [ "$_pc_fails" -le 4 ]; then printf 'FAIL: %s\n' "$1"; fi
}

t() {
  PATH="$4"
  "$_pc_fn" "$2" "$3"
  if [ "$PATH" != "$5" ]; then
    _pc_fail "$_pc_fn $1: $2 $3 on [$4] gave [$PATH], wanted [$5]"
  fi
}

# Cases of a single directory: the contract the helper has always had.
single_cases() {
  t "front adds" front /opt/a "/usr/bin:/bin" "/opt/a:/usr/bin:/bin"
  t "front moves from end" front /opt/a "/usr/bin:/bin:/opt/a" "/opt/a:/usr/bin:/bin"
  t "front moves from middle" front /opt/a "/usr/bin:/opt/a:/bin" "/opt/a:/usr/bin:/bin"
  t "front keeps the start" front /opt/a "/opt/a:/usr/bin:/bin" "/opt/a:/usr/bin:/bin"
  t "front removes duplicates" front /opt/a "/opt/a:/usr/bin:/opt/a:/bin:/opt/a" "/opt/a:/usr/bin:/bin"
  t "front adjacent duplicates" front /opt/a "/usr/bin:/opt/a:/opt/a:/bin" "/opt/a:/usr/bin:/bin"
  t "front on a PATH of one" front /opt/a "/opt/a" "/opt/a"
  t "front on an empty PATH" front /opt/a "" "/opt/a"
  t "back appends" back /opt/a "/usr/bin:/bin" "/usr/bin:/bin:/opt/a"
  t "back never moves (start)" back /opt/a "/opt/a:/usr/bin:/bin" "/opt/a:/usr/bin:/bin"
  t "back never moves (middle)" back /opt/a "/usr/bin:/opt/a:/bin" "/usr/bin:/opt/a:/bin"
  t "back never moves (end)" back /opt/a "/usr/bin:/bin:/opt/a" "/usr/bin:/bin:/opt/a"
  t "back keeps duplicates" back /opt/a "/opt/a:/usr/bin:/opt/a" "/opt/a:/usr/bin:/opt/a"
  t "back on an empty PATH" back /opt/a "" "/opt/a"
  # A directory that is the prefix of another entry is not that entry.
  t "front, prefix of an entry" front /usr/bin "/usr/bin2:/bin" "/usr/bin:/usr/bin2:/bin"
  t "front, prefix, entry present" front /usr/bin "/usr/bin2:/usr/bin:/usr/bin3" "/usr/bin:/usr/bin2:/usr/bin3"
  t "front, entry is a prefix" front /usr/bin2 "/usr/bin:/bin" "/usr/bin2:/usr/bin:/bin"
  t "back, prefix of an entry" back /usr/bin "/usr/bin2:/bin" "/usr/bin2:/bin:/usr/bin"
  t "back, entry is a prefix" back /usr/bin2 "/usr/bin" "/usr/bin:/usr/bin2"
  t "front, suffix match" front /bin "/usr/bin:/sbin" "/bin:/usr/bin:/sbin"
  # Glob characters and spaces: the directory matches only itself.
  t "front, star and space" front "/opt/we ird*dir" "/usr/bin:/opt/we ird*dir:/opt/we irdXdir:/bin" "/opt/we ird*dir:/usr/bin:/opt/we irdXdir:/bin"
  t "front, star is no wildcard" front "/opt/a*" "/opt/abc:/bin" "/opt/a*:/opt/abc:/bin"
  t "front, question mark" front "/opt/q?x" "/bin:/opt/qZx:/opt/q?x" "/opt/q?x:/bin:/opt/qZx"
  t "front, question mark not matched" front "/opt/q?x" "/bin:/opt/qZx" "/opt/q?x:/bin:/opt/qZx"
  t "front, bracket" front "/opt/[ab]" "/opt/a:/opt/[ab]:/bin" "/opt/[ab]:/opt/a:/bin"
  t "front, bracket not matched" front "/opt/[ab]" "/opt/a:/opt/b:/bin" "/opt/[ab]:/opt/a:/opt/b:/bin"
  t "back, star present" back "/opt/a*" "/opt/abc:/opt/a*" "/opt/abc:/opt/a*"
  t "back, star not matched" back "/opt/a*" "/opt/abc:/bin" "/opt/abc:/bin:/opt/a*"
  t "back, bracket not matched" back "/opt/[ab]" "/opt/a:/bin" "/opt/a:/bin:/opt/[ab]"
  t "back, space" back "/opt/two words" "/bin" "/bin:/opt/two words"
  t "front, space present" front "/opt/two words" "/bin:/opt/two words:/opt/two" "/opt/two words:/bin:/opt/two"
  t "front, backslash" front '/opt/a\b' '/bin:/opt/a\b:/opt/ab' '/opt/a\b:/bin:/opt/ab'
  t "front, quote and dollar" front '/opt/$HOME"x' '/bin:/opt/$HOME"x' '/opt/$HOME"x:/bin'
  # Empty entries of PATH (the current directory to the shell) stay where they are.
  t "front keeps a middle empty entry" front /opt/a "/usr/bin::/bin" "/opt/a:/usr/bin::/bin"
  t "front keeps it past a removal" front /opt/a "/usr/bin::/opt/a:/bin" "/opt/a:/usr/bin::/bin"
  t "front keeps it next to the removal" front /opt/a "/usr/bin:/opt/a::/bin" "/opt/a:/usr/bin::/bin"
  t "front keeps a leading empty entry" front /opt/a ":/opt/a:/bin" "/opt/a::/bin"
  t "front keeps a trailing empty entry" front /opt/a "/bin::/opt/a" "/opt/a:/bin:"
  t "front keeps a trailing empty entry (kept)" front /opt/a "/bin:" "/opt/a:/bin:"
  t "back after a trailing empty entry" back /opt/a "/bin:" "/bin::/opt/a"
  t "back after a leading empty entry" back /opt/a ":/bin" ":/bin:/opt/a"
}

# Cases of a list: front keeps the list's order (the first entry first), back appends what is
# missing in order, a directory is on PATH once, empty entries of the list are skipped.
list_cases() {
  t "list front" front "/opt/a:/opt/b:/opt/c" "/usr/bin" "/opt/a:/opt/b:/opt/c:/usr/bin"
  t "list front moves" front "/opt/a:/opt/b" "/usr/bin:/opt/b:/bin:/opt/a" "/opt/a:/opt/b:/usr/bin:/bin"
  t "list front, all present, reordered" front "/opt/a:/opt/b:/opt/c" "/opt/c:/opt/b:/opt/a:/bin" "/opt/a:/opt/b:/opt/c:/bin"
  t "list front, some present" front "/opt/a:/opt/b:/opt/c" "/usr/bin:/opt/b:/bin" "/opt/a:/opt/b:/opt/c:/usr/bin:/bin"
  t "list front, duplicates in the list" front "/opt/a:/opt/b:/opt/a" "/usr/bin" "/opt/a:/opt/b:/usr/bin"
  t "list front, duplicates on PATH too" front "/opt/a:/opt/b" "/opt/b:/usr/bin:/opt/a:/opt/b:/opt/a" "/opt/a:/opt/b:/usr/bin"
  t "list front, empty entries skipped" front "/opt/a::/opt/b:" "/usr/bin" "/opt/a:/opt/b:/usr/bin"
  t "list front, empty list" front "" "/usr/bin:/bin" "/usr/bin:/bin"
  t "list front on an empty PATH" front "/opt/a:/opt/b" "" "/opt/a:/opt/b"
  t "list front, one entry" front "/opt/a" "/usr/bin" "/opt/a:/usr/bin"
  # A lone empty entry is dropped when nothing else is left of PATH after the first removal (as it always was).
  t "front, only an empty entry is left" front /opt/a "/opt/a:" "/opt/a"
  t "front, only an empty entry is left (first)" front /opt/a ":/opt/a" "/opt/a"
  t "front, two empty entries are two" front /opt/a "/opt/a::" "/opt/a::"
  t "list front, last entry removed, empty entry lost" front "/opt/a:/usr/bin" "/usr/bin:" "/opt/a:/usr/bin"
  t "list front, empty entry kept when the last entry is not on PATH" front "/usr/bin:/opt/a" "/usr/bin:" "/usr/bin:/opt/a:"
  t "list front keeps empty entries" front "/opt/a:/opt/b" "/usr/bin::/opt/b:/bin:" "/opt/a:/opt/b:/usr/bin::/bin:"
  t "list front, prefixes" front "/usr/bin:/usr/bin2" "/usr/bin2:/bin:/usr/bin3" "/usr/bin:/usr/bin2:/bin:/usr/bin3"
  t "list front, glob and space" front "/opt/we ird*dir:/opt/q?x:/opt/[ab]" "/opt/weXird:/opt/q?x:/opt/a:/opt/[ab]" "/opt/we ird*dir:/opt/q?x:/opt/[ab]:/opt/weXird:/opt/a"
  t "list back" back "/opt/a:/opt/b:/opt/c" "/usr/bin" "/usr/bin:/opt/a:/opt/b:/opt/c"
  t "list back, some present" back "/opt/a:/opt/b:/opt/c" "/usr/bin:/opt/b" "/usr/bin:/opt/b:/opt/a:/opt/c"
  t "list back, all present" back "/opt/a:/opt/b" "/opt/b:/usr/bin:/opt/a" "/opt/b:/usr/bin:/opt/a"
  t "list back, duplicates in the list" back "/opt/a:/opt/b:/opt/a" "/usr/bin" "/usr/bin:/opt/a:/opt/b"
  t "list back, empty entries skipped" back ":/opt/a::/opt/b" "/usr/bin" "/usr/bin:/opt/a:/opt/b"
  t "list back, empty list" back "" "/usr/bin" "/usr/bin"
  t "list back on an empty PATH" back "/opt/a:/opt/b" "" "/opt/a:/opt/b"
  t "list back, glob and space" back "/opt/we ird*dir:/opt/[ab]" "/opt/weXird:/opt/a" "/opt/weXird:/opt/a:/opt/we ird*dir:/opt/[ab]"
}

# drop <list>: take every occurrence of the directories off PATH (shell/tools.sh uses it when the
# cached mise dirs give way to the real activation).
drop_cases() {
  t "drop one" drop /opt/a "/usr/bin:/opt/a:/bin" "/usr/bin:/bin"
  t "drop at the start" drop /opt/a "/opt/a:/usr/bin" "/usr/bin"
  t "drop at the end" drop /opt/a "/usr/bin:/opt/a" "/usr/bin"
  t "drop every occurrence" drop /opt/a "/opt/a:/usr/bin:/opt/a:/bin:/opt/a" "/usr/bin:/bin"
  t "drop a list" drop "/opt/a:/opt/c" "/opt/a:/usr/bin:/opt/b:/opt/c:/bin:/opt/a" "/usr/bin:/opt/b:/bin"
  t "drop what is absent" drop /opt/z "/usr/bin:/bin" "/usr/bin:/bin"
  t "drop on an empty PATH" drop /opt/a "" ""
  t "drop everything" drop "/opt/a:/opt/b" "/opt/b:/opt/a" ""
  t "drop the only entry" drop /opt/a "/opt/a" ""
  t "drop, only an empty entry is left" drop /opt/a "/opt/a:" ""
  t "drop, two empty entries are two" drop /opt/a "/opt/a::" ":"
  t "drop, empty list" drop "" "/usr/bin:/bin" "/usr/bin:/bin"
  t "drop, empty list entries" drop "::" "/usr/bin::/bin" "/usr/bin::/bin"
  t "drop keeps empty entries" drop /opt/a "/bin::/opt/a:/usr/bin:" "/bin::/usr/bin:"
  t "drop keeps a leading empty entry" drop /opt/a ":/opt/a:/bin" ":/bin"
  t "drop, prefix of an entry" drop /usr/bin "/usr/bin2:/usr/bin:/usr/bin3" "/usr/bin2:/usr/bin3"
  t "drop, glob and space" drop "/opt/we ird*dir:/opt/[ab]" "/opt/weXird:/opt/we ird*dir:/opt/a:/opt/[ab]:/bin" "/opt/weXird:/opt/a:/bin"
}


# noglob has another letter in zsh (set -f is NO_RCS there), so it goes through these.
_pc_noglob_on() { if [ -n "${ZSH_VERSION:-}" ]; then setopt noglob; else set -f; fi; }
_pc_noglob_off() { if [ -n "${ZSH_VERSION:-}" ]; then unsetopt noglob; else set +f; fi; }
_pc_noglob_is_on() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    [[ -o noglob ]]
  else
    case "$-" in *f*) return 0 ;; *) return 1 ;; esac
  fi
}

# The caller's IFS and noglob state, and its variables, are the same after a call. A state of the
# shell that a cleanup forgets shows up here as a PATH that broke, a glob that expanded or a
# variable of the helper that is still set.
state_cases() {
  _pc_ifs_in=" :x
"
  IFS="$_pc_ifs_in"
  _pc_noglob_on
  PATH="/usr/bin:/opt/*:/opt/a b:/bin"
  "$_pc_fn" front "/opt/*:/opt/new dir"
  if [ "$PATH" != "/opt/*:/opt/new dir:/usr/bin:/opt/a b:/bin" ]; then
    _pc_fail "$_pc_fn: hostile IFS and noglob gave [$PATH]"
  fi
  "$_pc_fn" back "/opt/last*"
  if [ "$IFS" != "$_pc_ifs_in" ]; then _pc_fail "$_pc_fn changed IFS"; fi
  if ! _pc_noglob_is_on; then _pc_fail "$_pc_fn turned noglob off"; fi
  _pc_noglob_off
  "$_pc_fn" drop "/opt/last*"
  if _pc_noglob_is_on; then _pc_fail "$_pc_fn turned noglob on"; fi
  unset IFS
  "$_pc_fn" front /opt/x
  if [ "${IFS+set}" = set ]; then _pc_fail "$_pc_fn set an IFS that was unset"; fi
  IFS="$_pc_ifs0"
  # None of the helper's variables stays behind (the old and the new names).
  if [ -n "${_df_rest+x}${_df_pl+x}${_df_pe+x}${_df_pa_set+x}${_df_pa_rest+x}${_df_pa_e+x}${_df_pa_out+x}${_df_pa_hit+x}${_df_pa_ne+x}${_df_pa_ee+x}${_df_pa_last+x}${_df_pa_front+x}${_df_pa_p+x}${_df_pa_n+x}${_df_pa_prev+x}${_df_pa_keep+x}${_df_pa_ifs+x}${_df_pa_ifs_set+x}${_df_pa_noglob+x}" ]; then
    _pc_fail "$_pc_fn left a variable of its own set"
  fi
}

for _pc_fn in _df_path_add _df_path_add_list; do
  command -v "$_pc_fn" >/dev/null 2>&1 || continue
  single_cases
  list_cases
  drop_cases
  state_cases
done
if [ "$IFS" != "$_pc_ifs0" ]; then _pc_fail "IFS is not what it was at the start"; fi
if [ "$_pc_fails" != 0 ]; then printf 'FAIL: %s wrong results\n' "$_pc_fails"; fi
echo path-cases-done
