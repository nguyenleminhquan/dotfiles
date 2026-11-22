#!/usr/bin/env bash
# One-off migration from the old dotfiles (a clone of nobitagamer/dotfiles in
# ~/.dotfiles) to this repo. Spec section 6.8.
#
#   tools/migrate-from-nobitagamer.sh [--profile minimal|server|workstation] [--drop-linuxbrew] [--dry-run]
#
# The profile defaults to workstation under WSL (the rule install.sh uses); on
# any other host --profile is mandatory and a missing one is refused before
# anything is changed.
#
# What it does, in this order:
#   1. refuses unless ~/.dotfiles is the old setup (git origin nobitagamer/dotfiles
#      or a .dots file), is not migrated yet, and nothing it would write is in the way
#   2. backs everything up in ~/.dotfiles-backup/<timestamp>/ and writes
#      restore.sh and links.tsv there BEFORE changing anything
#   3. moves the old ~/.dotfiles into <backup>/old-dotfiles and removes every
#      symlink under $HOME that points into it (one walk, see collect_links)
#   4. filters ~/.config/zsh/.zsh_history (or $ZDOTDIR/.zsh_history) into
#      ~/.zsh_history: PEM blocks and everything df_history_is_secret flags are dropped
#   5. copies ~/.gitconfig to ~/.gitconfig.local (nothing private can reach the
#      public repo) without core.editor, without the include of an empty file and
#      without what config/git/config already sets, then removes ~/.gitconfig
#   6. carries the old local layer: when ~/.localrc exists, a marked block that
#      sources it goes into ~/.zshrc.local and ~/.bashrc.local (interactive
#      shells only, like the old setup; ~/.localrc itself is never touched), and
#      the old GNUPGHOME is exported from ~/.config/dotfiles/env.local when its
#      directory holds keys. Both are appended once and undone by restore.sh
#      Linuxbrew: when the old shells load it and commands exist only there (the
#      login shell, the doctor's packages, zsh, micro, nano; not what the profile
#      installs), a marked block in the same env.local appends it to PATH, last, so
#      that they stay reachable. --drop-linuxbrew writes no block and the report
#      lists what disappears instead. Linuxbrew itself is never touched.
#   7. prints what the old shells read that the new ones do not (sourced files,
#      relocated variables such as GNUPGHOME or ZDOTDIR); informational only
#   8. prints the old mise config against the new one (workstation: config.workstation.toml,
#      server: config.toml, minimal: nothing, it installs no tools; informational)
#   9. runs install.sh --profile <profile> (without linuxbrew on its PATH when nothing
#      keeps it, so that it judges the host the way a new terminal will see it)
#
# ~/.ssh and everything else outside that list are left alone, and
# links that point outside the old dotfiles are never touched. --dry-run prints
# every action and writes nothing at all.
#
# Roll back with `dotfiles uninstall` followed by <backup>/restore.sh.
#
# Environment: DOTFILES_REPO makes install.sh clone that repo; otherwise it
# installs from the checkout this script lives in.

# SC2016 and SC2088: a "$" or "~" in single quotes or in a message is meant literally
# (patterns for the old shell files, text that is printed or written into files).
# shellcheck disable=SC2016,SC2088
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: migrate-from-nobitagamer.sh [--profile minimal|server|workstation] [--drop-linuxbrew] [--dry-run]

  --profile P       profile to install; default workstation under WSL, mandatory elsewhere
  --drop-linuxbrew  do not keep linuxbrew on PATH (default: kept, appended last, when a command
                    exists only there); those commands then disappear, the report lists them
  --dry-run         print what would happen and write nothing
EOF
}

dry_run=0
profile=""
drop_brew=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --drop-linuxbrew)
      drop_brew=1
      shift
      ;;
    --profile)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        usage
        printf '[error] --profile needs a value\n' >&2
        exit 1
      fi
      profile="$2"
      shift 2
      ;;
    --profile=*)
      profile="${1#--profile=}"
      if [ -z "$profile" ]; then
        usage
        printf '[error] --profile needs a value\n' >&2
        exit 1
      fi
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      printf '[error] unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done
case "$profile" in
  "" | minimal | server | workstation) ;;
  *)
    usage
    printf '[error] unknown profile: %s (minimal|server|workstation)\n' "$profile" >&2
    exit 1
    ;;
esac

self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ ! -f "$self_root/lib/log.sh" ] || [ ! -f "$self_root/install.sh" ]; then
  printf '[error] %s is not a dotfiles checkout\n' "$self_root" >&2
  exit 1
fi
# shellcheck source=lib/log.sh
. "$self_root/lib/log.sh"
# shellcheck source=lib/detect.sh
. "$self_root/lib/detect.sh"
# The doctor's package list and the commands each profile's tools provide: the one definition
# of both (functions and variables only; nothing runs when it is sourced).
# shellcheck source=lib/doctor.sh
. "$self_root/lib/doctor.sh"
# shellcheck source=lib/backup.sh
. "$self_root/lib/backup.sh"
# The one definition of what counts as a secret command line. Sourcing it only
# defines functions and shell variables here; a script is not interactive.
# shellcheck source=shell/history.sh
. "$self_root/shell/history.sh"

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set to an existing directory"
OLD="$HOME/.dotfiles"
if [ -n "${DOTFILES_DIR:-}" ] && [ "${DOTFILES_DIR%/}" != "$OLD" ]; then
  die "DOTFILES_DIR is set to ${DOTFILES_DIR}: the old setup lives in $OLD, unset DOTFILES_DIR"
fi
# lib/backup.sh reads these two (DF_DRY_RUN is only ever 0: a dry run never calls it).
DOTFILES_DIR="$OLD"
# shellcheck disable=SC2034
DF_DRY_RUN=0

MARKER="$HOME/.config/dotfiles/migrated-from-nobitagamer"
# Separator of the values of one git key (the unit separator never appears in a value).
US=$'\x1f'
TILDE='~'
OLD_PHYS=""

# --- what the run is about to do (filled by the collect_* functions) ----------------------
LINK_PATHS=()
LINK_TARGETS=()
LINK_SCAN_SECS=0
declare -A LINKSET=()

HIST_SRC=""
HIST_TOTAL=0
HIST_KEPT=0

GIT_SRC=""
GIT_KIND=none
GIT_UNSET=()
GIT_DROPPED=()
GIT_SKIPPED=()
GIT_KEPT=()
GIT_WARN=()
GIT_INC_DROP=()
EXC_SRC=""
declare -A G=() R=()
G_ORDER=()
# shellcheck disable=SC2034 # filled through a nameref in read_cfg
R_ORDER=()

BK=""
# none: nothing was written yet; staged: backup dir exists; ready: restore.sh
# exists (the first destructive step may have run).
STAGE=none

# On any failure after restore.sh exists, say how to get back.
_on_exit() {
  local rc=$?
  [ "$rc" -ne 0 ] || return 0
  case "$STAGE" in
    ready)
      log_error "migration did not finish. Nothing is lost: everything is in $BK"
      log_error "to roll back: run 'dotfiles uninstall' (or ~/.dotfiles/uninstall.sh) if it was installed, then: bash $BK/restore.sh"
      ;;
    staged)
      log_error "migration stopped before anything was changed; $BK can be deleted"
      ;;
  esac
}
trap _on_exit EXIT

# norm_path <absolute path>: remove ".", ".." and "//" lexically (no symlink is
# followed). The result is in $NORM; no subshell, so no fork per link.
norm_path() {
  local -a parts
  local seg res=""
  IFS=/ read -ra parts <<<"$1"
  for seg in "${parts[@]}"; do
    case "$seg" in
      '' | .) ;;
      ..) res="${res%/*}" ;;
      *) res+="/$seg" ;;
    esac
  done
  NORM="${res:-/}"
}

# in_old <normalised absolute path>: the path is the old checkout or inside it.
in_old() {
  case "$1" in
    "$OLD" | "$OLD"/* | "$OLD_PHYS" | "$OLD_PHYS"/*) return 0 ;;
  esac
  return 1
}

# tilde <path>: "~/x" becomes "$HOME/x".
tilde() {
  case "$1" in
    "$TILDE") printf '%s' "$HOME" ;;
    "$TILDE"/*) printf '%s/%s' "$HOME" "${1#"$TILDE"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- preflight: read-only checks ----------------------------------------------------------
preflight() {
  local f

  if [ -f "$MARKER" ]; then
    f="$(sed -n 's/^restore=//p' "$MARKER" | head -n 1)"
    die "already migrated (or an earlier run did not finish): $MARKER exists. To roll back, run 'dotfiles uninstall' and then: bash ${f:-<backup>/restore.sh}"
  fi
  [ ! -f "$HOME/.config/dotfiles/links" ] || die "the new dotfiles are already installed (~/.config/dotfiles/links exists)"
  if [ -e "$HOME/.dotfiles-backup/original" ]; then
    die "$HOME/.dotfiles-backup/original exists: an install cycle is active. Run 'dotfiles uninstall' first"
  fi

  [ -e "$OLD" ] || [ -L "$OLD" ] || die "$OLD does not exist: there is no old setup to migrate"
  [ -d "$OLD" ] && [ ! -L "$OLD" ] || die "$OLD is not a plain directory: this is not the old dotfiles clone"
  if [ -f "$OLD/.dotfiles-managed" ]; then
    die "$OLD is the new dotfiles (it carries .dotfiles-managed): already migrated"
  fi
  if [ ! -f "$OLD/.dots" ] && ! grep -qsF 'nobitagamer/dotfiles' "$OLD/.git/config"; then
    die "$OLD is not the old dotfiles: its git origin is not nobitagamer/dotfiles and it has no .dots file"
  fi
  OLD_PHYS="$(cd "$OLD" && pwd -P)"
  case "$self_root/" in
    "$OLD"/* | "$OLD_PHYS"/*) die "this script runs from $self_root, inside the old $OLD, which is about to be moved: run it from a checkout elsewhere" ;;
  esac
  case "$PWD/" in
    "$OLD"/* | "$OLD_PHYS"/*) die "the current directory is inside the old $OLD, which is about to be moved: cd somewhere else" ;;
  esac

  df_detect
  df_platform_supported || exit 1

  # The same rule as install.sh: WSL defaults to workstation, anywhere else the
  # profile has to be named (a server must not get the workstation tools).
  if [ -z "$profile" ]; then
    if [ "${DF_WSL:-0}" != 0 ]; then
      profile=workstation
    else
      usage
      die "this is not WSL, so there is no default profile: pass --profile minimal|server|workstation"
    fi
  fi

  for f in .gitconfig.local .zsh_history; do
    if [ -L "$HOME/$f" ]; then
      die "$HOME/$f is a symlink: move it away first, the migration writes a real file there"
    fi
    if [ -s "$HOME/$f" ]; then
      die "$HOME/$f already has content and would be overwritten: move it away or merge it by hand, then run again"
    fi
  done
}

# --- the symlinks that point into the old dotfiles ------------------------------------------
# _glob_escape <text>: the text as a literal in a find -path pattern.
_glob_escape() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      "\\" | '*' | '?' | '[') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# find_all_links: "<path>\0<target>\0" for every symlink under $HOME. One walk;
# find does not follow symlinks (a symlinked directory such as ~/data is never
# entered) and -xdev keeps it on the filesystem of $HOME (no /mnt). Not entered:
# the old clone, the backups, caches, credentials and trees that tools manage
# (node_modules, git internals, mise's installs), none of which holds links
# into the old dotfiles.
find_all_links() {
  local h
  h="$(_glob_escape "$HOME")"
  find "$HOME" -xdev \( -path "$h/.dotfiles" -o -path "$h/.dotfiles-backup" -o -path "$h/.cache" \
    -o -path "$h/.ssh" -o -path "$h/.aws" -o -path "$h/data" -o -path "$h/.local/share/mise" \
    -o \( -type d \( -name node_modules -o -name .git \) \) \) -prune -o -type l -printf '%p\0%l\0'
}

# collect_links: every symlink under $HOME whose target is inside the old
# checkout (directly, lexically, or through other links).
collect_links() {
  local l t abs r t0=$SECONDS
  while IFS= read -r -d '' l && IFS= read -r -d '' t; do
    case "$l" in
      *$'\n'*)
        log_warn "skipping a link with a newline in its name"
        continue
        ;;
    esac
    [ -z "${LINKSET["$l"]+x}" ] || continue
    case "$t" in
      /*) abs="$t" ;;
      *) abs="${l%/*}/$t" ;;
    esac
    norm_path "$abs"
    abs="$NORM"
    if ! in_old "$abs"; then
      # A link to a link that ends up in the old checkout counts as well.
      case "$abs" in /mnt/*) continue ;; esac
      r="$(readlink -f -- "$l" 2>/dev/null || true)"
      if [ -z "$r" ] || ! in_old "$r"; then continue; fi
    fi
    LINK_PATHS+=("$l")
    LINK_TARGETS+=("$t")
    LINKSET["$l"]=1
  done < <(find_all_links 2>/dev/null)
  LINK_SCAN_SECS=$((SECONDS - t0))
  # ~/.gitconfig is removed in every case, so a link that is not one of the old
  # ones is recorded too (restore.sh recreates it).
  if [ -L "$HOME/.gitconfig" ] && [ -z "${LINKSET["$HOME/.gitconfig"]+x}" ]; then
    LINK_PATHS+=("$HOME/.gitconfig")
    LINK_TARGETS+=("$(readlink "$HOME/.gitconfig")")
    LINKSET["$HOME/.gitconfig"]=1
  fi
}

# --- values read from the old shell files ----------------------------------------------------------
# What an XDG variable means for the old shells: its default under $HOME, never the
# value in the environment of this run (which the old shells may not have seen).
declare -A XDG_REL=([CONFIG]=.config [DATA]=.local/share [CACHE]=.cache [STATE]=.local/state)
declare -A XDG_DIR=()
for _k in "${!XDG_REL[@]}"; do XDG_DIR[$_k]="$HOME/${XDG_REL[$_k]}"; done
unset _k

# resolve_value <raw text after "NAME="> [ZDOTDIR]: RESOLVED is the value as an absolute
# path, computed from the text alone: "…", '…', ~, $HOME, ${HOME}, $XDG_*_HOME (also as
# ${XDG_*_HOME:-default}, but only when the default is the XDG default itself: any other
# default depends on the environment) and, when given, $ZDOTDIR. Anything that would need
# a shell to evaluate (command substitution, another variable, a relative path, a glob, an
# operator) gives "".
resolve_value() {
  local v="$1" m kind def rel
  v="${v%%[[:space:]]\#*}"
  v="${v#"${v%%[![:space:]]*}"}" # trim, so that `"…"  # comment` is left with just the quotes
  v="${v%"${v##*[![:space:]]}"}"
  v="${v#\"}"
  v="${v%\"}"
  v="${v#\'}"
  v="${v%\'}"
  while [[ $v =~ \$\{XDG_(CONFIG|DATA|CACHE|STATE)_HOME:-([^}]*)\} ]]; do
    m="${BASH_REMATCH[0]}"
    kind="${BASH_REMATCH[1]}"
    def="${BASH_REMATCH[2]}"
    rel="${XDG_REL[$kind]}"
    case "$def" in
      "\$HOME/$rel" | "\${HOME}/$rel" | "~/$rel") v="${v/"$m"/"${XDG_DIR[$kind]}"}" ;;
      *) v="${v/"$m"/\$UNRESOLVED}" ;; # left with a "$" so that it is rejected below
    esac
  done
  for kind in CONFIG DATA CACHE STATE; do
    v="${v//\$\{XDG_${kind}_HOME\}/"${XDG_DIR[$kind]}"}"
    v="${v//\$XDG_${kind}_HOME/"${XDG_DIR[$kind]}"}"
  done
  v="${v//\$\{HOME\}/"$HOME"}"
  v="${v//\$HOME/"$HOME"}"
  if [ -n "${2:-}" ]; then
    v="${v//\$\{ZDOTDIR\}/"$2"}"
    v="${v//\$ZDOTDIR/"$2"}"
  fi
  v="$(tilde "$v")"
  case "$v" in
    "" | *\$* | *\`* | *\"* | *\'* | *\\* | *\;* | *\&* | *\|* | *\(* | *\)* | *\<* | *\>* | *\** | *\?*) RESOLVED="" ;;
    /*) RESOLVED="$v" ;;
    *) RESOLVED="" ;;
  esac
}

# --- history ------------------------------------------------------------------------------------
# locate_history: ZDOTDIR as the old ~/.zshenv sets it (parsed, never sourced),
# then ~/.config/zsh. Sets HIST_SRC to the first existing .zsh_history.
locate_history() {
  local line v="" cand
  HIST_SRC=""
  if [ -f "$HOME/.zshenv" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?ZDOTDIR=(.*)$ ]]; then
        v="${BASH_REMATCH[2]}"
      fi
    done <"$HOME/.zshenv"
  fi
  if [ -n "$v" ]; then
    resolve_value "$v"
    v="$RESOLVED"
  fi
  for cand in ${v:+"$v/.zsh_history"} "$HOME/.config/zsh/.zsh_history"; do
    if [ -f "$cand" ]; then
      HIST_SRC="$cand"
      return 0
    fi
  done
}

# Fate of one history entry (see filter_history). _h_* variables are its state.
_h_emit() {
  printf '%s\n' "$1" >&3
  HIST_KEPT=$((HIST_KEPT + 1))
}

# _h_release: the pending PEM block turned out not to be one; judge its entries one by one.
_h_release() {
  local e
  for e in "${_h_pend[@]}"; do
    if df_history_is_secret "$e"; then :; else _h_emit "$e"; fi
  done
  _h_pend=()
  _h_block=0
}

_h_entry() {
  local entry="$1" body="$1"
  HIST_TOTAL=$((HIST_TOTAL + 1))
  if [[ $entry =~ ^:\ [0-9]+:[0-9]+\; ]]; then
    body="${entry:${#BASH_REMATCH[0]}}"
  fi
  if [ "$_h_block" = 1 ]; then
    _h_pend+=("$entry")
    if [[ $entry == *-----END* ]]; then
      _h_pend=()
      _h_block=0
    elif [ "${#_h_pend[@]}" -ge 100 ]; then
      _h_release
    fi
    return 0
  fi
  # A key pasted into the prompt becomes one history entry per line: BEGIN
  # opens a block that runs up to the entry with END. It has to start the
  # command, or `grep -- -----BEGIN file` would swallow what follows.
  if [[ $body == -----BEGIN* && $body != *-----END* ]]; then
    _h_block=1
    _h_pend=("$entry")
    return 0
  fi
  if df_history_is_secret "$entry"; then :; else _h_emit "$entry"; fi
}

# filter_history <in> <out>: copy the extended-format history, entry by entry
# and in order, without the secrets. An entry is a line plus its continuation
# lines (a line ending in a backslash continues, as in zsh); plain lines of the
# older format are entries too. One pass, no fork per entry: the rules
# are df_history_is_secret itself, called as a function.
filter_history() {
  local in="$1" out="$2" line entry="" have=0 cont=0
  local LC_ALL=C
  _h_pend=()
  _h_block=0
  HIST_TOTAL=0
  HIST_KEPT=0
  exec 3>"$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$cont" = 1 ]; then
      entry+=$'\n'"$line"
    else
      if [ "$have" = 1 ]; then _h_entry "$entry"; fi
      entry="$line"
      have=1
    fi
    # Like zsh's reader (readhistline): any line ending in a backslash is
    # continued, whatever precedes it. zsh's writer puts a backslash before
    # every embedded newline and does not escape the backslashes already
    # there, so a typed `curl \<newline> -H x` is stored as `curl \\<newline> -H x`.
    cont=0
    if [[ $line == *\\ ]]; then cont=1; fi
  done <"$in"
  if [ "$have" = 1 ]; then _h_entry "$entry"; fi
  if [ "$_h_block" = 1 ]; then _h_release; fi
  exec 3>&-
}

# --- git ------------------------------------------------------------------------------------------
# read_cfg <file> <assoc> <order>: `git config --list -z` into <assoc> (key to its
# values, joined by US) and <order> (keys in first-seen order). git parses the
# file, so subsections and repeated keys come out right.
read_cfg() {
  local file="$1" rec key val
  local -n map="$2" order="$3"
  while IFS= read -r -d '' rec; do
    if [[ $rec == *$'\n'* ]]; then
      key="${rec%%$'\n'*}"
      val="${rec#*$'\n'}"
    else
      key="$rec"
      val=true # a key without "=" is a boolean true
    fi
    [ -n "${map["$key"]+x}" ] || order+=("$key")
    map["$key"]+="$val$US"
  done < <(git config --file "$file" --list -z)
}

# split_vals <US-joined values> <array>: the values as an array (newlines inside a value are fine).
split_vals() {
  local s="$1" v
  local -n _sv_out="$2"
  _sv_out=()
  while [ -n "$s" ]; do
    v="${s%%"$US"*}"
    _sv_out+=("$v")
    s="${s#*"$US"}"
  done
}

# _re_escape <text>: the text as a literal in an extended regular expression.
_re_escape() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      "\\" | '.' | '[' | ']' | '{' | '}' | '(' | ')' | '*' | '+' | '?' | '^' | '$' | '|') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# --- masking: what is printed must not carry a secret ------------------------------------------
# mask_userinfo <text>: any userinfo of a URL ("user:password@", a bare token@,
# a password that itself holds "@" or "/") becomes "<hidden>@". Everything between
# "://" and the last "@" of the same word is taken as userinfo: that can hide a
# little more than strictly needed (an "@" later in a path), never less. Result
# in $MASKED.
mask_userinfo() {
  local rest="$1" out='' m
  while [[ $rest =~ ://[^[:space:]]*@ ]]; do
    m="${BASH_REMATCH[0]}"
    out+="${rest%%"$m"*}://<hidden>@"
    rest="${rest#*"$m"}"
  done
  MASKED="$out$rest"
}

# looks_secret <text>: the history rules (the one definition), after removing the
# spaces around "=" that config files have and command lines do not.
looks_secret() {
  local s="${1// = /=}"
  s="${s// =/=}"
  s="${s//= /=}"
  df_history_is_secret "$s"
}

# masked_kv <key> <value>: "key = value" that is safe to print.
masked_kv() {
  local k v
  mask_userinfo "$1"
  k="$MASKED"
  mask_userinfo "$2"
  v="$MASKED"
  if looks_secret "$k"; then k="<hidden key>"; fi
  if looks_secret "$k=$v"; then v="<hidden>"; fi
  printf '%s = %s' "$k" "$v"
}

# check_old_ref <key> <values>: warn about a value that names the old checkout.
check_old_ref() {
  case "$2" in
    *"$OLD"* | *"~/.dotfiles"*)
      GIT_WARN+=("$1 mentions the old ~/.dotfiles, which is moved away: fix it in ~/.gitconfig.local")
      ;;
  esac
}

# plan_excludes <values>: core.excludesfile that points into the old checkout
# (usually the link ~/.gitignore_global) is replaced by git's own default,
# ~/.config/git/ignore. Returns 0 when the key is dropped.
plan_excludes() {
  local ex r
  ex="$(tilde "${1%%"$US"*}")"
  case "$ex" in /*) ;; *) return 1 ;; esac
  norm_path "$ex"
  ex="$NORM"
  if [ -z "${LINKSET["$ex"]+x}" ]; then
    r="$(readlink -f -- "$ex" 2>/dev/null || true)"
    if [ -z "$r" ] || ! in_old "$r"; then
      if ! in_old "$ex"; then return 1; fi
    fi
  fi
  if [ ! -f "$ex" ]; then
    GIT_DROPPED+=("core.excludesfile: dropped, $ex is missing in the old setup")
  elif [ -e "$HOME/.config/git/ignore" ]; then
    GIT_DROPPED+=("core.excludesfile: dropped; ~/.config/git/ignore exists and is kept, merge $ex by hand (a copy is in the backup)")
    GIT_WARN+=("core.excludesfile pointed into the old dotfiles but ~/.config/git/ignore already exists: its content was not touched")
  else
    EXC_SRC="$ex"
    GIT_DROPPED+=("core.excludesfile: dropped, the content of $ex becomes ~/.config/git/ignore (git reads it by default)")
  fi
  GIT_UNSET+=(core.excludesfile)
  return 0
}

# plan_includes <values> <dir of the config file>: include.path entries that
# point at an empty or missing file are dropped, the others stay.
plan_includes() {
  local -a vals
  local v p d seen
  split_vals "$1" vals
  for v in "${vals[@]}"; do
    [ -n "$v" ] || continue
    p="$(tilde "$v")"
    case "$p" in /*) ;; *) p="$2/$p" ;; esac
    if [ -s "$p" ]; then
      case "$v" in /* | "$TILDE"/*) ;; *) GIT_WARN+=("include.path = $v is relative and may not resolve from ~/.gitconfig.local") ;; esac
      check_old_ref include.path "$v"
    else
      seen=0
      for d in ${GIT_INC_DROP[@]+"${GIT_INC_DROP[@]}"}; do
        if [ "$d" = "$v" ]; then seen=1; fi
      done
      # One unset removes every copy of a repeated value.
      if [ "$seen" = 0 ]; then GIT_INC_DROP+=("$v"); fi
      GIT_DROPPED+=("include.path = $v: dropped, the file is empty or missing")
    fi
  done
}

plan_git() {
  local key vals base
  [ -f "$HOME/.gitconfig" ] || return 0
  GIT_SRC="$HOME/.gitconfig"
  if [ -L "$GIT_SRC" ]; then GIT_KIND="link"; else GIT_KIND="file"; fi
  command -v git >/dev/null 2>&1 || die "git is required to split ~/.gitconfig"
  git config --file "$GIT_SRC" --list -z >/dev/null 2>&1 || die "git cannot read $GIT_SRC: fix it first"
  read_cfg "$GIT_SRC" G G_ORDER
  read_cfg "$self_root/config/git/config" R R_ORDER
  base="$(dirname "$(readlink -f "$GIT_SRC")")"

  for key in "${G_ORDER[@]}"; do
    vals="${G["$key"]}"
    case "$key" in
      core.editor)
        GIT_UNSET+=("$key")
        GIT_DROPPED+=("core.editor: dropped on purpose, git then uses \$GIT_EDITOR, \$VISUAL or \$EDITOR")
        continue
        ;;
      core.excludesfile)
        if plan_excludes "$vals"; then continue; fi
        ;;
      include.path)
        plan_includes "$vals" "$base"
        continue
        ;;
    esac
    if [ -n "${R["$key"]+x}" ] && [ "${R["$key"]}" = "$vals" ]; then
      GIT_UNSET+=("$key")
      GIT_SKIPPED+=("$key")
      continue
    fi
    GIT_KEPT+=("$key")
    check_old_ref "$key" "$vals"
  done
}

# build_gitlocal <out>: the old file with the dropped keys removed by git itself.
build_gitlocal() {
  local dest="$1" key v
  cp -L -- "$GIT_SRC" "$dest"
  chmod 600 "$dest"
  for key in ${GIT_UNSET[@]+"${GIT_UNSET[@]}"}; do
    git config --file "$dest" --unset-all "$key"
  done
  # Only the dropped include.path values are removed, in place: git applies an
  # include where it stands, so the kept ones must keep their order.
  for v in ${GIT_INC_DROP[@]+"${GIT_INC_DROP[@]}"}; do
    git config --file "$dest" --unset-all include.path "^$(_re_escape "$v")\$"
  done
}

# report_git: what the split does, and the keys the user may want in the repo.
report_git() {
  local key vals n identity=0
  local -a parts
  if [ -z "$GIT_SRC" ]; then
    log_info "git: no ~/.gitconfig, nothing to split"
    return 0
  fi
  log_info "git: ~/.gitconfig ($GIT_KIND) becomes ~/.gitconfig.local; ${#GIT_KEPT[@]} keys stay, ${#GIT_SKIPPED[@]} are skipped (config/git/config has them), ${#GIT_DROPPED[@]} are dropped"
  for key in ${GIT_DROPPED[@]+"${GIT_DROPPED[@]}"}; do
    mask_userinfo "$key"
    log_info "git: $MASKED"
  done
  for key in ${GIT_SKIPPED[@]+"${GIT_SKIPPED[@]}"}; do
    mask_userinfo "$key"
    log_info "git: $MASKED: skipped, config/git/config sets the same"
  done
  for key in ${GIT_WARN[@]+"${GIT_WARN[@]}"}; do
    mask_userinfo "$key"
    log_warn "git: $MASKED"
  done
  printf '\nKeys that stay only in ~/.gitconfig.local. Nothing was added to the repo;\ncopy what you want to share into config/git/config yourself:\n'
  for key in ${GIT_KEPT[@]+"${GIT_KEPT[@]}"}; do
    vals="${G["$key"]}"
    split_vals "$vals" parts
    n="${#parts[@]}"
    case "$key" in
      user.* | credential.*)
        identity=$((identity + 1))
        ;;
      *)
        mask_userinfo "$key"
        if [ "$n" -gt 1 ]; then
          printf '  %s (%d values)\n' "$MASKED" "$n"
        else
          printf '  %s\n' "$(masked_kv "$key" "${parts[0]}")"
        fi
        ;;
    esac
  done
  printf '  (+ %d identity keys, user.* and credential.*, not listed)\n\n' "$identity"
}

# --- mise ------------------------------------------------------------------------------------------
report_mise() {
  local old="$HOME/.config/mise/config.toml" new name
  case "$profile" in
    workstation) name=config.workstation.toml ;;
    server) name=config.toml ;;
    *)
      # minimal installs no tools: there is nothing to compare with.
      printf '\nmise: the minimal profile installs no tools; the old ~/.config/mise/config.toml is kept in the backup\n\n'
      return 0
      ;;
  esac
  new="$self_root/config/mise/$name"
  printf '\nmise: old config against config/mise/%s (informational):\n' "$name"
  if [ ! -f "$old" ]; then
    printf '  no ~/.config/mise/config.toml\n\n'
    return 0
  fi
  # Lines that look like a secret (an [env] token, a URL with a password) are
  # not shown; the file itself is in the backup.
  local line
  { diff -u --label "old ~/.config/mise/config.toml" --label "new $name" "$old" "$new" || true; } |
    while IFS= read -r line; do
      mask_userinfo "$line"
      line="$MASKED"
      case "$line" in
        '---'* | '+++'* | '@@'*) printf '%s\n' "$line" ;;
        *)
          if looks_secret "${line:1}"; then
            printf '%s<hidden: looks like a secret>\n' "${line:0:1}"
          else
            printf '%s\n' "$line"
          fi
          ;;
      esac
    done
  printf '\n'
}

# --- the local layer: ~/.localrc, GNUPGHOME, and what else the old shells read ----------------------
# The old setup sources ~/.localrc from login bash and interactive zsh and exports
# GNUPGHOME. Neither means anything to the new shells, so the migration carries
# both and tells the user about everything else that silently stops being read.
LOCAL_BEGIN_RC='# >>> migrated from nobitagamer/dotfiles: ~/.localrc >>>'
LOCAL_BEGIN_GPG='# >>> migrated from nobitagamer/dotfiles: GNUPGHOME >>>'
LOCAL_END='# <<< migrated from nobitagamer/dotfiles <<<'
LOCALRC_LINE='[ -r "$HOME/.localrc" ] && . "$HOME/.localrc"'

LOCALRC=0
# What gets written: one entry per block, relative to $HOME.
LOCAL_REL=()
LOCAL_BEGIN=()
LOCAL_BODY=()
LOCAL_WHAT=()
LOCAL_END_OF=() # the closing marker of each block
# new | append | present | joined. A block for a file that another block of this run creates or
# appends to is "joined" to it (LOCAL_JOIN holds the index): both are written, and undone, as one
# piece of text, so that env.local can get GNUPGHOME and linuxbrew in one run.
LOCAL_KIND=()
LOCAL_JOIN=()
# Linuxbrew (plan_linuxbrew): whether the old shells load it, its prefix, and whether install.sh
# runs without it on PATH.
BREW_USED=0
BREW_PREFIX=""
BREW_STRIP=0
# What the user is told about what the old shells read: "<thing>|<fate>".
LOCAL_NOTES=()
declare -A VAR_SEEN=() VAR_VAL=() READ_SEEN=()

# disp <absolute path>: the path as the user writes it, ~/… under $HOME.
disp() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# collect_old_reads: one grep over the old shell files (the old dotfiles tree only,
# never a walk of $HOME) for the variables that move state and for the files the
# shells source or test. Fills VAR_SEEN/VAR_VAL (variable to its last assignment,
# resolved or empty) and LOCAL_NOTES for the files that exist and are not links into
# the old dotfiles. Nothing is sourced or evaluated.
collect_old_reads() {
  local scan="$OLD/shells" text line var kind raw rest tok p r def
  local assign_re='^[[:space:]]*(export[[:space:]]+)?(GNUPGHOME|ZDOTDIR|HISTFILE|XDG_(CONFIG|DATA|CACHE|STATE)_HOME)='
  local ctx_re='(^|[;&|({[:space:]])(source|\.)[[:space:]]+[^[:space:]]|(^|[;&|({[:space:]])(\[\[?|test)[[:space:]]+(![[:space:]]+)?-[a-zA-Z][[:space:]]'
  local assign_bash="${assign_re}(.*)\$"
  local tok_re='(\$HOME|\$\{HOME\}|~|\$ZDOTDIR|\$\{ZDOTDIR\}|\$XDG_(CONFIG|DATA|CACHE|STATE)_HOME|\$\{XDG_(CONFIG|DATA|CACHE|STATE)_HOME(:-[^}]*)?\})(/[A-Za-z0-9._/@+-]+)'
  # A shell file that puts linuxbrew on PATH: `brew shellenv`, or a PATH assignment naming it.
  local brew_re='brew[[:space:]]+shellenv|(^|[;&|({[:space:]])(export[[:space:]]+)?PATH=[^#]*linuxbrew'
  [ -d "$scan" ] || scan="$OLD"
  text="$(find "$scan" -name .git -prune -o -type f -size -512k -print0 2>/dev/null |
    LC_ALL=C sort -z | xargs -0 -r grep -IhE -e "$assign_re" -e "$ctx_re" -e "$brew_re" 2>/dev/null || true)"
  [ -n "$text" ] || return 0

  # Pass 1: the variables ($ZDOTDIR is needed to resolve the paths of pass 2).
  while IFS= read -r line; do
    if [[ $line =~ $assign_bash ]]; then
      var="${BASH_REMATCH[2]}"
      raw="${BASH_REMATCH[4]}"
      resolve_value "$raw"
      VAR_SEEN["$var"]=1
      VAR_VAL["$var"]="$RESOLVED"
    fi
  done <<<"$text"

  # Pass 2: the files.
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*# ]] && continue # a commented-out line reads nothing
    if [[ $line =~ $brew_re ]]; then BREW_USED=1; fi
    [[ $line =~ $ctx_re ]] || continue
    rest="$line"
    while [[ $rest =~ $tok_re ]]; do
      tok="${BASH_REMATCH[0]}"
      rest="${rest#*"$tok"}"
      resolve_value "$tok" "${VAR_VAL[ZDOTDIR]:-}"
      p="$RESOLVED"
      [ -n "$p" ] || continue
      norm_path "$p"
      p="$NORM"
      # Once per file, however it is spelled (~/.profile and $HOME/.profile are one file).
      [ -z "${READ_SEEN["$p"]+x}" ] || continue
      READ_SEEN["$p"]=1
      [ -f "$p" ] || continue # a file that exists (a directory or a glob is not one)
      in_old "$p" && continue
      [ -z "${LINKSET["$p"]+x}" ] || continue
      if [ -L "$p" ]; then
        r="$(readlink -f -- "$p" 2>/dev/null || true)"
        if [ -n "$r" ] && in_old "$r"; then continue; fi
      fi
      case "$p" in
        "$HOME/.localrc") continue ;; # reported by plan_localrc
        "$HOME/.zshrc.local" | "$HOME/.bashrc.local" | "$HOME/.config/dotfiles/env.local")
          LOCAL_NOTES+=("$(disp "$p")|kept (the new dotfiles read it too)")
          ;;
        "$HOME/.profile")
          # install.sh links its own ~/.profile, after saving this one in the backup.
          LOCAL_NOTES+=("$(disp "$p")|replaced (backup kept)")
          ;;
        *) LOCAL_NOTES+=("$(disp "$p")|no longer read") ;;
      esac
    done
  done <<<"$text"
  # A variable that is set to the default the new shells use anyway is not news.
  for kind in CONFIG DATA CACHE STATE; do
    var="XDG_${kind}_HOME"
    [ -n "${VAR_SEEN["$var"]+x}" ] || continue
    case "$kind" in
      CONFIG) def="$HOME/.config" ;;
      DATA) def="$HOME/.local/share" ;;
      CACHE) def="$HOME/.cache" ;;
      STATE) def="$HOME/.local/state" ;;
    esac
    if [ "${VAR_VAL["$var"]}" = "$def" ]; then unset "VAR_SEEN[$var]"; fi
  done
}

# add_local_target <relative path> <begin marker> <body> <what> [end marker]: plan one marked block.
# A block for a file that an earlier block of this run creates or appends to is joined to it.
add_local_target() {
  local rel="$1" f="$HOME/$1" kind join="" j
  if [ -e "$f" ] || [ -L "$f" ]; then
    # Like ~/.gitconfig.local and ~/.zsh_history in preflight: a link could lead outside $HOME or
    # into the old dotfiles (removed before the block is written), so a real file is required.
    [ ! -L "$f" ] || die "$(disp "$f") is a symlink: move it away first, the migration appends to a real file there"
    [ ! -d "$f" ] || die "$f is a directory: the migration appends a block to it"
    [ -w "$f" ] || die "$f is not writable: the migration appends a block to it"
    if grep -qxF -- "$2" "$f"; then kind=present; else kind=append; fi
  else
    kind=new
  fi
  if [ "$kind" != present ]; then
    for j in "${!LOCAL_REL[@]}"; do
      if [ "${LOCAL_REL[$j]}" = "$rel" ] && { [ "${LOCAL_KIND[$j]}" = new ] || [ "${LOCAL_KIND[$j]}" = append ]; }; then
        kind=joined
        join="$j"
        break
      fi
    done
  fi
  LOCAL_REL+=("$rel")
  LOCAL_BEGIN+=("$2")
  LOCAL_BODY+=("$3")
  LOCAL_WHAT+=("$4")
  LOCAL_END_OF+=("${5:-$LOCAL_END}")
  LOCAL_KIND+=("$kind")
  LOCAL_JOIN+=("$join")
}

plan_localrc() {
  if [ -f "$HOME/.localrc" ] && [ -z "${LINKSET["$HOME/.localrc"]+x}" ]; then
    LOCALRC=1
    LOCAL_NOTES=("~/.localrc|kept (shim in ~/.zshrc.local, ~/.bashrc.local)" ${LOCAL_NOTES[@]+"${LOCAL_NOTES[@]}"})
    add_local_target .zshrc.local "$LOCAL_BEGIN_RC" "$LOCALRC_LINE" "the ~/.localrc shim"
    add_local_target .bashrc.local "$LOCAL_BEGIN_RC" "$LOCALRC_LINE" "the ~/.localrc shim"
  fi
}

# plan_gnupg: GNUPGHOME is carried only when it can be resolved without running code
# and its directory holds keys; the new shells would otherwise look in ~/.gnupg and
# find none.
plan_gnupg() {
  local d why=""
  [ -n "${VAR_SEEN[GNUPGHOME]+x}" ] || return 0
  d="${VAR_VAL[GNUPGHOME]}"
  if [ -z "$d" ]; then
    why="its value needs a shell to evaluate; set it in ~/.config/dotfiles/env.local"
  else
    norm_path "$d"
    d="$NORM"
    if [ ! -d "$d" ]; then
      why="$(disp "$d") does not exist"
    elif in_old "$d" || in_old "$(readlink -f -- "$d" 2>/dev/null || printf '%s' "$d")"; then
      why="$(disp "$d") is inside the old dotfiles, which are moved away"
    elif [ "${d#"$HOME"/}" = "$d" ]; then
      why="$d is outside your home"
    elif [ ! -e "$d/pubring.kbx" ] && [ -z "$(ls -A "$d/private-keys-v1.d" 2>/dev/null)" ]; then
      why="$(disp "$d") holds no keys"
    fi
  fi
  if [ -n "$why" ]; then
    LOCAL_NOTES+=("GNUPGHOME|no longer read ($why)")
    return 0
  fi
  # An env.local that sets GNUPGHOME already wins: a second assignment would silently replace it.
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?GNUPGHOME=' "$HOME/.config/dotfiles/env.local" 2>/dev/null; then
    LOCAL_NOTES+=("GNUPGHOME|already set in env.local")
    return 0
  fi
  LOCAL_NOTES+=("GNUPGHOME|carried to env.local")
  add_local_target .config/dotfiles/env.local "$LOCAL_BEGIN_GPG" "export GNUPGHOME=\"\$HOME/${d#"$HOME"/}\"" "GNUPGHOME=\"\$HOME/${d#"$HOME"/}\""
}

# join_commas <items...>: "a, b, c".
join_commas() {
  local out="" x
  for x in "$@"; do out+="${out:+, }$x"; done
  printf '%s' "$out"
}

# linuxbrew_body <prefix>: the text between the markers: brew's directories appended to PATH, once,
# and only while the directory exists. With the default prefix it is the block that was verified on
# a real host (the test compares it byte for byte); a test prefix only changes the path.
linuxbrew_body() {
  local p="$1"
  printf '%s\n' \
    '# The login shell and tools such as screen live only in linuxbrew on this host.' \
    '# Appended last, so system tools win; remove this block once brew is gone.' \
    'case ":$PATH:" in' \
    "  *:$p/bin:*) ;;" \
    "  *) [ -d $p/bin ] && PATH=\"\$PATH:$p/bin:$p/sbin\" ;;" \
    'esac'
}

# path_without <prefix>: $PATH without the entries inside <prefix>.
path_without() {
  local out="" part
  local -a parts=()
  IFS=: read -ra parts <<<"$PATH"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      "$1" | "$1"/*) continue ;;
    esac
    out+="${out:+:}$part"
  done
  printf '%s' "$out"
}

# plan_linuxbrew: the old shells load linuxbrew (brew shellenv, or a PATH assignment naming it) and
# its bin exists. What would vanish without it: commands in brew's bin that are not on a clean system
# PATH (the one a fresh ssh or cron session starts with) and that the profile does not provide: the
# login shell when it lives under the prefix, the doctor's packages, zsh, micro and nano. The profile
# provides the commands of its mise tools (config/mise/commands.*) and, for server and workstation,
# zsh through zsh-bin. install.sh only installs zsh-bin when it finds no zsh, so it runs without
# brew on its PATH whenever nothing keeps brew (BREW_STRIP); when brew is kept, zsh stays brew's and
# is listed.
# Default: add the marked block to env.local (same rules as the GNUPGHOME block). --drop-linuxbrew: no
# block, the report names what disappears.
plan_linuxbrew() {
  local prefix login base="" cmd label d p found note where
  local -a cand=() provided=() full=() rest=()
  local -A seen=()
  [ "$BREW_USED" = 1 ] || return 0
  prefix="$(df_linuxbrew_prefix)"
  [ -d "$prefix/bin" ] || return 0
  BREW_PREFIX="$prefix"
  login="$(df_login_shell)"
  case "$login" in
    "$prefix"/*) base="${login##*/}" ;;
  esac
  cand=(${base:+"$base"} "${DF_DOCTOR_PACKAGES[@]}" zsh micro nano)
  mapfile -t provided < <(_df_doctor_tools "$profile" || true)
  for cmd in "${cand[@]}"; do
    [ -z "${seen["$cmd"]+x}" ] || continue
    seen["$cmd"]=1
    [ -x "$prefix/bin/$cmd" ] || [ -x "$prefix/sbin/$cmd" ] || continue
    found=0
    for d in /usr/local/bin /usr/bin /bin; do
      if [ -x "$d/$cmd" ]; then found=1; fi
    done
    for p in ${provided[@]+"${provided[@]}"}; do
      if [ "$p" = "$cmd" ]; then found=1; fi
    done
    [ "$found" = 0 ] || continue
    label="$cmd"
    if [ "$cmd" = "$base" ]; then label="$cmd (login shell)"; fi
    full+=("$label")
    if [ "$cmd" = zsh ] && [ "$profile" != minimal ]; then continue; fi
    rest+=("$label")
  done

  if [ "$drop_brew" = 1 ]; then
    BREW_STRIP=1
    if [ "${#rest[@]}" = 0 ]; then
      note="dropped (--drop-linuxbrew) — nothing depends on it"
    else
      note="dropped (--drop-linuxbrew) — these commands will disappear: $(join_commas "${rest[@]}"); install them with the system package manager, or run again without --drop-linuxbrew"
    fi
    if grep -qxF -- "$DF_LINUXBREW_BEGIN" "$HOME/.config/dotfiles/env.local" 2>/dev/null; then
      note+="; the block already in ~/.config/dotfiles/env.local is left as it is"
    fi
  elif [ "${#rest[@]}" = 0 ]; then
    BREW_STRIP=1
    note="nothing depends on it (what it has is on the system or comes with the profile), so it is not kept on PATH"
  else
    add_local_target .config/dotfiles/env.local "$DF_LINUXBREW_BEGIN" "$(linuxbrew_body "$prefix")" "linuxbrew on PATH" "$DF_LINUXBREW_END"
    where="appended last"
    if [ "${LOCAL_KIND[$((${#LOCAL_KIND[@]} - 1))]}" = present ]; then where="the block is already in env.local"; fi
    note="kept on PATH ($where) — only there: $(join_commas "${full[@]}")"
  fi
  LOCAL_NOTES+=("linuxbrew|$note")
}

plan_local() {
  collect_old_reads
  plan_localrc
  plan_gnupg
  plan_linuxbrew
  if [ -n "${VAR_SEEN[ZDOTDIR]+x}" ]; then
    if [ -n "$HIST_SRC" ]; then
      LOCAL_NOTES+=("ZDOTDIR|history migrated to ~/.zsh_history")
    else
      LOCAL_NOTES+=("ZDOTDIR|no longer read (there is no history to migrate)")
    fi
  fi
  local var
  for var in HISTFILE XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME; do
    [ -n "${VAR_SEEN["$var"]+x}" ] || continue
    if [ "$var" = HISTFILE ] && [ -n "$HIST_SRC" ] && [ "${VAR_VAL[HISTFILE]}" = "$HIST_SRC" ]; then
      LOCAL_NOTES+=("HISTFILE|history migrated to ~/.zsh_history")
    else
      LOCAL_NOTES+=("$var|no longer read")
    fi
  done
}

# report_local: informational, never a reason to refuse.
report_local() {
  local n
  if [ "${#LOCAL_NOTES[@]}" = 0 ]; then
    log_info "local layer: the old shells read nothing from your home that the new ones do not"
    return 0
  fi
  log_info "local layer: what the old shells read outside the old dotfiles, and what happens to it:"
  for n in "${LOCAL_NOTES[@]}"; do
    log_info "  ${n%%|*}: ${n#*|}"
  done
}

# local_block <index>: the exact text appended to target <index>: the marked block (and the
# blocks joined to it, in order), with a newline in front when the file exists and does not
# end in one, so that removing the text gives the original bytes back.
local_block() {
  local i="$1" f="$HOME/${LOCAL_REL[$1]}" k
  if [ "${LOCAL_KIND[$i]}" = append ] && [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\n'; fi
  for k in "${!LOCAL_REL[@]}"; do
    if [ "$k" = "$i" ] || [ "${LOCAL_JOIN[$k]}" = "$i" ]; then
      printf '%s\n%s\n%s\n' "${LOCAL_BEGIN[$k]}" "${LOCAL_BODY[$k]}" "${LOCAL_END_OF[$k]}"
    fi
  done
}

# --- the plan, shared by --dry-run and the real run ----------------------------------------------
BK_ITEMS=(.zshenv .bashrc .profile .bash_profile .config/mise/config.toml .config/zsh)

report_plan() {
  local i verb="would" item kind strip_note
  [ "$dry_run" = 1 ] || verb="will"
  log_info "old setup: $OLD (git origin or .dots matches)"
  if [ "$dry_run" = 1 ]; then
    log_info "backup: $verb be created in $HOME/.dotfiles-backup/<timestamp>/ with restore.sh and links.tsv"
  else
    log_info "backup: $BK"
  fi
  for item in "${BK_ITEMS[@]}" .gitconfig; do
    if [ -e "$HOME/$item" ] || [ -L "$HOME/$item" ]; then log_info "backup: $verb save ~/$item"; fi
  done
  log_info "move: $verb move $OLD to <backup>/old-dotfiles"
  log_info "links: found ${#LINK_PATHS[@]} symlinks that point into the old dotfiles (walk of $HOME: ${LINK_SCAN_SECS}s); $verb remove them all"
  for i in "${!LINK_PATHS[@]}"; do
    log_info "  unlink ${LINK_PATHS[$i]} -> ${LINK_TARGETS[$i]}"
  done
  if [ -n "$HIST_SRC" ]; then
    log_info "history: $verb write ~/.zsh_history from $HIST_SRC"
  else
    log_info "history: no .zsh_history found, nothing to copy"
  fi
  if [ "$GIT_KIND" != none ]; then
    log_info "git: $verb write ~/.gitconfig.local and remove ~/.gitconfig"
    if [ -n "$EXC_SRC" ]; then log_info "git: $verb write ~/.config/git/ignore from $EXC_SRC"; fi
  fi
  for i in "${!LOCAL_REL[@]}"; do
    kind="${LOCAL_KIND[$i]}"
    if [ "$kind" = joined ]; then kind="${LOCAL_KIND[${LOCAL_JOIN[$i]}]}"; fi
    case "$kind" in
      new) log_info "local: $verb add ${LOCAL_WHAT[$i]} to $(disp "$HOME/${LOCAL_REL[$i]}") (new file)" ;;
      append) log_info "local: $verb add ${LOCAL_WHAT[$i]} to $(disp "$HOME/${LOCAL_REL[$i]}") (existing file, backed up)" ;;
      present) log_info "local: $(disp "$HOME/${LOCAL_REL[$i]}") already has ${LOCAL_WHAT[$i]}, left as it is" ;;
    esac
  done
  strip_note=""
  if [ "$BREW_STRIP" = 1 ]; then strip_note=" (linuxbrew taken off its PATH: nothing keeps it)"; fi
  if [ -n "${DOTFILES_REPO:-}" ]; then
    log_info "install: $verb run: DOTFILES_REPO=$DOTFILES_REPO bash $self_root/install.sh --profile $profile$strip_note"
  else
    log_info "install: $verb run: DOTFILES_SRC=$self_root bash $self_root/install.sh --profile $profile$strip_note"
  fi
}

# --- the real run ------------------------------------------------------------------------------------
# backup_copies: copies of what the install may replace; nothing is removed yet.
backup_copies() {
  local item src dst
  for item in "${BK_ITEMS[@]}" .gitconfig .gitconfig.local .zsh_history .zshrc.local .bashrc.local .config/dotfiles/env.local; do
    src="$HOME/$item"
    [ -e "$src" ] || [ -L "$src" ] || continue
    # A real ~/.gitconfig is moved later by df_backup_file.
    if [ "$item" = .gitconfig ] && [ ! -L "$src" ]; then continue; fi
    dst="$BK/$item"
    mkdir -p "$(dirname "$dst")"
    if [ -L "$src" ] && [ -f "$src" ]; then
      cp -aL -- "$src" "$dst" # the content, not a link that dangles once the clone moves
    else
      cp -a -- "$src" "$dst"
    fi
  done
  # The history itself, wherever it lives (ZDOTDIR) and even when it is reached through a
  # link into the old clone.
  if [ -n "$HIST_SRC" ]; then cp -L -- "$HIST_SRC" "$BK/zsh_history.orig"; fi
}

_sha() { sha256sum <"$1" | cut -d' ' -f1; }

# write_restore: restore.sh, written before the first destructive step. Every
# step in it checks the current state, so it works after a failed run, can be
# repeated, and never overwrites what exists.
write_restore() {
  local f="$BK/restore.sh" i sha_hist="" sha_local="" sha_ignore=""
  local -a sha_block=()
  # Hashed first, outside the printf arguments below: set -e does not see a
  # failing command substitution inside printf's arguments.
  if [ -f "$BK/staged/zsh_history" ]; then sha_hist="$(_sha "$BK/staged/zsh_history")"; fi
  if [ -f "$BK/staged/gitconfig.local" ]; then sha_local="$(_sha "$BK/staged/gitconfig.local")"; fi
  if [ -f "$BK/staged/git-ignore" ]; then sha_ignore="$(_sha "$BK/staged/git-ignore")"; fi
  if [ -f "$BK/staged/zsh_history" ] && [ -z "$sha_hist" ]; then die "could not hash the staged history for restore.sh"; fi
  if [ -f "$BK/staged/gitconfig.local" ] && [ -z "$sha_local" ]; then die "could not hash the staged gitconfig.local for restore.sh"; fi
  if [ -f "$BK/staged/git-ignore" ] && [ -z "$sha_ignore" ]; then die "could not hash the staged ignore file for restore.sh"; fi
  for i in "${!LOCAL_REL[@]}"; do
    [ "${LOCAL_KIND[$i]}" = new ] || continue
    sha_block[i]="$(_sha "$BK/staged/local-$i.block")"
    [ -n "${sha_block[i]}" ] || die "could not hash a staged local file for restore.sh"
  done
  {
    cat <<'EOF'
#!/usr/bin/env bash
# Rollback for the migration done by tools/migrate-from-nobitagamer.sh.
# Generated; safe to read. It prints every step and can be run again.
#
# Run it after `dotfiles uninstall` (or ~/.dotfiles/uninstall.sh): it
#   1. refuses while the new dotfiles are still installed or ~/.dotfiles is
#      occupied by anything but the copy the installer made (that one is moved
#      into this backup directory as new-dotfiles)
#   2. moves old-dotfiles back to ~/.dotfiles
#   3. recreates every removed symlink (listed below and in links.tsv), never
#      over something that exists
#   4. puts ~/.gitconfig back, and removes ~/.gitconfig.local, ~/.zsh_history
#      and ~/.config/git/ignore only when the migration created them and they
#      are unchanged
#   5. takes ~/.zshrc.local, ~/.bashrc.local and ~/.config/dotfiles/env.local
#      back: a file the migration created is removed while it is unchanged, the
#      marked block it appended to an existing one is cut out (that file is then
#      byte for byte what it was; an edited block is left alone with a warning)
#   6. removes the migration marker
set -euo pipefail

EOF
    printf 'BK=%q\nHOME_AT_MIGRATION=%q\n' "$BK" "$HOME"
    cat <<'EOF'
MARKER="$HOME/.config/dotfiles/migrated-from-nobitagamer"

say() { printf '[restore] %s\n' "$*"; }
warn() { printf '[restore] warning: %s\n' "$*" >&2; }
die() {
  printf '[restore] error: %s\n' "$*" >&2
  exit 1
}
sha() { sha256sum <"$1" | cut -d' ' -f1; }

# restore_link <path> <target>: recreate a removed symlink.
restore_link() {
  local path="$1" target="$2"
  if [ -L "$path" ]; then
    [ "$(readlink "$path")" = "$target" ] || warn "$path is a different symlink now, leaving it"
    return 0
  fi
  if [ -e "$path" ]; then
    warn "$path exists, not recreating the link to $target"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  ln -s -- "$target" "$path"
  say "linked $path -> $target"
}

# undo_created <path> <sha> [backup copy]: remove a file the migration wrote,
# only while it is unchanged; put the backup copy back when there was one.
undo_created() {
  local path="$1" want="$2" keep="${3:-}"
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  if [ "$(sha "$path")" = "$want" ]; then
    rm -f -- "$path"
    say "removed $path"
    if [ -n "$keep" ] && [ -e "$keep" ]; then
      cp -a -- "$keep" "$path"
      say "restored $path from the backup"
    fi
  else
    warn "$path changed since the migration, leaving it"
  fi
}

# undo_block <path> <block file>: cut the exact block the migration appended out of an
# existing file (the block file has the text, a leading newline included when the
# file lacked a final one). A block that was edited is left alone. It never aborts
# the rollback: whatever is wrong is a warning and the rest of restore.sh runs.
undo_block() {
  local path="$1" blockfile="$2" begin="" cur blk pre post
  [ -f "$path" ] || return 0
  if [ -L "$path" ]; then
    warn "$path is a symlink now, leaving it"
    return 0
  fi
  if [ -f "$blockfile" ]; then
    begin="$(grep -m 1 '^# >>> ' "$blockfile" || true)"
  fi
  if [ -z "$begin" ]; then
    warn "$path: the staged copy of the migration block ($blockfile) is gone, remove the marked lines by hand"
    return 0
  fi
  if ! grep -qxF -- "$begin" "$path"; then
    say "$path has no migration block any more"
    return 0
  fi
  cur="$(cat -- "$path"; printf x)" || { warn "cannot read $path, leaving it"; return 0; }
  cur="${cur%x}"
  blk="$(cat -- "$blockfile"; printf x)" || { warn "cannot read $blockfile, leaving $path"; return 0; }
  blk="${blk%x}"
  case "$cur" in
    *"$blk"*)
      pre="${cur%%"$blk"*}"
      post="${cur#*"$blk"}"
      # The block starts with a newline when the file lacked a final one. If the user added
      # lines after the block, that newline now separates their last old line from them:
      # keep it, or the two lines would be joined.
      if [ "${blk:0:1}" = $'\n' ] && [ -n "$post" ]; then
        pre="$pre"$'\n'
      fi
      if printf '%s%s' "$pre" "$post" >"$path"; then
        say "removed the migration block from $path"
      else
        warn "could not write $path, leaving it as it is"
      fi
      ;;
    *) warn "$path: the migration block was edited, leaving it as it is (remove the marked lines by hand)" ;;
  esac
}

[ "${HOME:-}" = "$HOME_AT_MIGRATION" ] || die "made for HOME=$HOME_AT_MIGRATION, not $HOME"
[ -d "$BK" ] || die "backup directory $BK is gone"

if [ -f "$HOME/.config/dotfiles/links" ]; then
  die "the new dotfiles are still installed: run 'dotfiles uninstall' (or ~/.dotfiles/uninstall.sh) first"
fi

if [ -d "$BK/old-dotfiles" ]; then
  if [ -e "$HOME/.dotfiles" ] || [ -L "$HOME/.dotfiles" ]; then
    if [ -f "$HOME/.dotfiles/.dotfiles-managed" ] && [ ! -L "$HOME/.dotfiles" ]; then
      [ ! -e "$BK/new-dotfiles" ] || die "$BK/new-dotfiles already exists"
      say "moving the new copy $HOME/.dotfiles to $BK/new-dotfiles"
      mv -- "$HOME/.dotfiles" "$BK/new-dotfiles"
    else
      die "$HOME/.dotfiles is occupied by something the migration did not create: move it away and run this again"
    fi
  fi
  say "moving $BK/old-dotfiles back to $HOME/.dotfiles"
  mv -- "$BK/old-dotfiles" "$HOME/.dotfiles"
else
  say "old-dotfiles is already back (or was never moved)"
fi

EOF
    for i in "${!LINK_PATHS[@]}"; do
      printf 'restore_link %q %q\n' "${LINK_PATHS[$i]}" "${LINK_TARGETS[$i]}"
    done
    printf '\n'
    if [ "$GIT_KIND" = file ]; then
      cat <<'EOF'
if [ -f "$BK/.gitconfig" ] && [ ! -e "$HOME/.gitconfig" ] && [ ! -L "$HOME/.gitconfig" ]; then
  cp -a -- "$BK/.gitconfig" "$HOME/.gitconfig"
  say "restored $HOME/.gitconfig"
fi
EOF
    fi
    # The $HOME and $BK below are written into restore.sh to be expanded when it runs.
    # shellcheck disable=SC2016
    if [ -f "$BK/staged/zsh_history" ]; then
      printf 'undo_created "$HOME/.zsh_history" %s' "$sha_hist"
      if [ "$HIST_PREEXISTED" = 1 ]; then printf ' "$BK/.zsh_history"'; fi
      printf '\n'
    fi
    # shellcheck disable=SC2016
    if [ -f "$BK/staged/gitconfig.local" ]; then
      printf 'undo_created "$HOME/.gitconfig.local" %s' "$sha_local"
      if [ "$GITLOCAL_PREEXISTED" = 1 ]; then printf ' "$BK/.gitconfig.local"'; fi
      printf '\n'
    fi
    # shellcheck disable=SC2016
    if [ -f "$BK/staged/git-ignore" ]; then
      printf 'undo_created "$HOME/.config/git/ignore" %s\n' "$sha_ignore"
    fi
    # shellcheck disable=SC2016
    for i in "${!LOCAL_REL[@]}"; do
      case "${LOCAL_KIND[$i]}" in
        new) printf 'undo_created "$HOME/%s" %s\n' "${LOCAL_REL[$i]}" "${sha_block[$i]}" ;;
        append) printf 'undo_block "$HOME/%s" "$BK/staged/local-%d.block"\n' "${LOCAL_REL[$i]}" "$i" ;;
      esac
    done
    cat <<'EOF'

rm -f -- "$MARKER"
rmdir "$HOME/.config/git" 2>/dev/null || true
rmdir "$HOME/.config/dotfiles" 2>/dev/null || true
say "done: the old dotfiles are back. Open a new terminal."
EOF
  } >"$f"
  chmod 755 "$f"
}

HIST_PREEXISTED=0
GITLOCAL_PREEXISTED=0

# stage: everything that can be prepared without touching the old setup.
stage() {
  local i
  df_backup_init
  # df_backup_init marks the first backup directory as "original", which is
  # what `dotfiles uninstall` restores from. This one holds the old clone and
  # must not be restored file by file into $HOME: leave the marker to install.sh.
  if [ "$(readlink "$HOME/.dotfiles-backup/original" 2>/dev/null || true)" = "$DF_BACKUP_DIR" ]; then
    rm -f -- "$HOME/.dotfiles-backup/original"
    log_info "(that marker was removed again: this backup is restored with restore.sh, not by dotfiles uninstall)"
  fi
  BK="$DF_BACKUP_DIR"
  STAGE=staged
  log_info "backup directory: $BK"

  [ -e "$HOME/.zsh_history" ] && HIST_PREEXISTED=1
  [ -e "$HOME/.gitconfig.local" ] && GITLOCAL_PREEXISTED=1
  mkdir -p "$BK/staged"
  backup_copies

  if [ -n "$HIST_SRC" ]; then
    filter_history "$HIST_SRC" "$BK/staged/zsh_history"
    chmod 600 "$BK/staged/zsh_history"
    log_info "history: kept $HIST_KEPT of $HIST_TOTAL entries"
  fi
  if [ "$GIT_KIND" != none ]; then
    build_gitlocal "$BK/staged/gitconfig.local"
  fi
  if [ -n "$EXC_SRC" ]; then
    cp -L -- "$EXC_SRC" "$BK/staged/git-ignore"
  fi
  for i in "${!LOCAL_REL[@]}"; do
    [ "${LOCAL_KIND[$i]}" != present ] || continue
    [ "${LOCAL_KIND[$i]}" != joined ] || continue # written with the block it is joined to
    local_block "$i" >"$BK/staged/local-$i.block"
  done

  for i in "${!LINK_PATHS[@]}"; do
    printf '%s\t%s\n' "${LINK_PATHS[$i]}" "${LINK_TARGETS[$i]}"
  done >"$BK/links.tsv"
  write_restore
  STAGE=ready
  log_info "rollback script written: $BK/restore.sh"
}

# apply: the destructive part. restore.sh already exists and copes with any
# state this leaves behind.
apply() {
  local l i f git_before="" git_after=""
  mkdir -p "$(dirname "$MARKER")"
  printf 'backup=%s\nrestore=%s\n' "$BK" "$BK/restore.sh" >"$MARKER"

  if [ -n "$GIT_SRC" ]; then git_before="$(git config --file "$GIT_SRC" --get user.email 2>/dev/null || true)"; fi

  mv -- "$OLD" "$BK/old-dotfiles"
  log_info "moved $OLD to $BK/old-dotfiles"
  for l in ${LINK_PATHS[@]+"${LINK_PATHS[@]}"}; do
    if [ -L "$l" ]; then rm -f -- "$l"; fi
  done
  log_info "removed ${#LINK_PATHS[@]} symlinks"
  if [ "$GIT_KIND" = file ]; then df_backup_file "$HOME/.gitconfig"; fi

  if [ -f "$BK/staged/zsh_history" ]; then
    cp -- "$BK/staged/zsh_history" "$HOME/.zsh_history"
    chmod 600 "$HOME/.zsh_history"
    log_info "wrote ~/.zsh_history"
  fi
  if [ -f "$BK/staged/gitconfig.local" ]; then
    cp -- "$BK/staged/gitconfig.local" "$HOME/.gitconfig.local"
    chmod 600 "$HOME/.gitconfig.local"
    log_info "wrote ~/.gitconfig.local"
  fi
  if [ -f "$BK/staged/git-ignore" ]; then
    mkdir -p "$HOME/.config/git"
    cp -- "$BK/staged/git-ignore" "$HOME/.config/git/ignore"
    log_info "wrote ~/.config/git/ignore"
  fi
  # The marked blocks of the local layer. A new file is created world-readable like
  # the user's other rc files; an existing one only gets the block appended.
  for i in "${!LOCAL_REL[@]}"; do
    f="$HOME/${LOCAL_REL[$i]}"
    case "${LOCAL_KIND[$i]}" in
      new)
        mkdir -p "$(dirname "$f")"
        cat -- "$BK/staged/local-$i.block" >"$f"
        chmod 644 "$f"
        log_info "wrote $(disp "$f")"
        ;;
      append)
        cat -- "$BK/staged/local-$i.block" >>"$f"
        log_info "added the block to $(disp "$f")"
        ;;
    esac
  done

  if [ -n "${DOTFILES_REPO:-}" ]; then
    unset DOTFILES_SRC
  else
    export DOTFILES_SRC="$self_root"
  fi
  # Nothing keeps linuxbrew: install.sh must see the host as a new terminal will (zsh-bin is
  # installed only when it finds no zsh). $BASH is absolute, so env needs no PATH to find it.
  if [ "$BREW_STRIP" = 1 ]; then
    env "PATH=$(path_without "$BREW_PREFIX")" "$BASH" "$self_root/install.sh" --profile "$profile" || die "install.sh failed"
  else
    bash "$self_root/install.sh" --profile "$profile" || die "install.sh failed"
  fi

  if [ -n "$git_before" ]; then
    git_after="$(cd "$HOME" && git config --get user.email 2>/dev/null || true)"
    [ "$git_after" = "$git_before" ] || log_warn "git config user.email is '$git_after' after the migration, it was '$git_before'"
  fi
}

# --- main -------------------------------------------------------------------------------------------------
if [ "$dry_run" = 1 ]; then log_info "dry run: nothing will be written"; fi
preflight
collect_links
locate_history
plan_git
plan_local

if [ -n "$HIST_SRC" ]; then
  # In a dry run the filter writes to /dev/null: same pass, same counts.
  if [ "$dry_run" = 1 ]; then
    filter_history "$HIST_SRC" /dev/null
    log_info "history: $HIST_SRC has $HIST_TOTAL entries, $HIST_KEPT would be kept, $((HIST_TOTAL - HIST_KEPT)) dropped"
  fi
fi

if [ "$dry_run" = 1 ]; then
  report_plan
  report_git
  report_local
  report_mise
  log_info "dry run done: nothing was written"
  exit 0
fi

stage
report_plan
report_git
report_local
report_mise
apply

log_info "migrated. Open a new terminal to check the shell."
log_info "backup: $BK"
log_info "roll back: dotfiles uninstall && bash $BK/restore.sh"
if [ "$LOCALRC" = 1 ]; then
  log_info "~/.localrc is kept through a shim in ~/.zshrc.local and ~/.bashrc.local; move its entries into ~/.config/dotfiles/env.local (every shell) or ~/.zshrc.local (interactive) when you like, see the README section 'Local layer'"
fi
if [ -z "${DOTFILES_REPO:-}" ]; then
  log_info "\`dotfiles update\` has no source yet (this install was copied from $self_root): run install.sh once with DOTFILES_REPO=<repo url>, or run this migration again with it set"
fi
