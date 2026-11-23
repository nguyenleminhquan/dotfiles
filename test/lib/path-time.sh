# shellcheck shell=sh
# Times _df_path_add_list on a long PATH. Sourced by an interactive bash or zsh after env.sh;
# DF_FX_PATH is the PATH of the host and DF_FX_DIRS the directories to put in front of it, which
# a non-interactive start has already appended (so every one of them is removed again).
# Prints "ms: <a> <b> <c>" (three runs, each from the same PATH) and "WRONG" when the result is
# not the dirs followed by the rest.

# _pt_now: the time in microseconds, as an integer, in _pt_t. bash has EPOCHREALTIME as a string
# "seconds.micro"; zsh's is a float with more digits (and needs zsh/datetime).
if [ -n "${ZSH_VERSION:-}" ]; then
  zmodload zsh/datetime zsh/mathfunc
  eval '_pt_now() { _pt_t=$(( int(EPOCHREALTIME * 1000000) )); }'
else
  _pt_now() { _pt_t="${EPOCHREALTIME/[.,]/}"; }
fi
_pt_ms=
_pt_bad=
for _pt_i in 1 2 3; do
  PATH="$DF_FX_PATH:$DF_FX_DIRS"
  _pt_now
  _pt_s="$_pt_t"
  _df_path_add_list front "$DF_FX_DIRS"
  _pt_now
  _pt_ms="$_pt_ms $(((_pt_t - _pt_s) / 1000))"
  [ "$PATH" = "$DF_FX_DIRS:$DF_FX_PATH" ] || _pt_bad=1
done
printf 'ms:%s\n' "$_pt_ms"
if [ -n "$_pt_bad" ]; then echo WRONG; fi
