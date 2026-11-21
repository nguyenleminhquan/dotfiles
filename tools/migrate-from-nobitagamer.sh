#!/usr/bin/env bash
# One-off migration from the old dotfiles (a clone of nobitagamer/dotfiles in
# ~/.dotfiles) to this repo. Spec section 6.8.
#
#   tools/migrate-from-nobitagamer.sh [--dry-run]
#
# What it does, in this order:
#   1. refuses unless ~/.dotfiles is the old setup (git origin nobitagamer/dotfiles
#      or a .dots file), is not migrated yet, and nothing it would write is in the way
#   2. backs everything up in ~/.dotfiles-backup/<timestamp>/ and writes
#      restore.sh and links.tsv there BEFORE changing anything
#   3. moves the old ~/.dotfiles into <backup>/old-dotfiles and removes every
#      symlink under ~, ~/.config and ~/.local/bin that points into it
#   4. filters ~/.config/zsh/.zsh_history (or $ZDOTDIR/.zsh_history) into
#      ~/.zsh_history: PEM blocks and everything df_history_is_secret flags are dropped
#   5. copies ~/.gitconfig to ~/.gitconfig.local (nothing private can reach the
#      public repo) without core.editor, without the include of an empty file and
#      without what config/git/config already sets, then removes ~/.gitconfig
#   6. prints the old mise config against config.workstation.toml (informational)
#   7. runs install.sh --profile workstation
#
# Linuxbrew, ~/.ssh and everything else outside that list are left alone, and
# links that point outside the old dotfiles are never touched. --dry-run prints
# every action and writes nothing at all.
#
# Roll back with `dotfiles uninstall` followed by <backup>/restore.sh.
#
# Environment: DOTFILES_REPO makes install.sh clone that repo; otherwise it
# installs from the checkout this script lives in.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: migrate-from-nobitagamer.sh [--dry-run]

  --dry-run   print what would happen and write nothing
EOF
}

dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=1
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

self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ ! -f "$self_root/lib/log.sh" ] || [ ! -f "$self_root/install.sh" ]; then
  printf '[error] %s is not a dotfiles checkout\n' "$self_root" >&2
  exit 1
fi
# shellcheck source=lib/log.sh
. "$self_root/lib/log.sh"
# shellcheck source=lib/detect.sh
. "$self_root/lib/detect.sh"
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
GIT_INC_REWRITE=0
GIT_INC_KEEP=()
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
# Only $HOME, ~/.config (6 levels) and ~/.local/bin (2 levels) are searched, and
# find neither follows symlinked directories nor crosses a mount point there.
collect_links() {
  local l t abs r
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
  done < <(
    {
      find "$HOME" -mindepth 1 -maxdepth 1 -type l -printf '%p\0%l\0'
      if [ -d "$HOME/.config" ] && [ ! -L "$HOME/.config" ]; then
        find "$HOME/.config" -xdev -mindepth 1 -maxdepth 6 -type l -printf '%p\0%l\0'
      fi
      if [ -d "$HOME/.local/bin" ] && [ ! -L "$HOME/.local" ] && [ ! -L "$HOME/.local/bin" ]; then
        find "$HOME/.local/bin" -xdev -mindepth 1 -maxdepth 2 -type l -printf '%p\0%l\0'
      fi
    } 2>/dev/null
  )
  # ~/.gitconfig is removed in every case, so a link that is not one of the old
  # ones is recorded too (restore.sh recreates it).
  if [ -L "$HOME/.gitconfig" ] && [ -z "${LINKSET["$HOME/.gitconfig"]+x}" ]; then
    LINK_PATHS+=("$HOME/.gitconfig")
    LINK_TARGETS+=("$(readlink "$HOME/.gitconfig")")
    LINKSET["$HOME/.gitconfig"]=1
  fi
}

# --- history ------------------------------------------------------------------------------------
# locate_history: ZDOTDIR as the old ~/.zshenv sets it (parsed, never sourced),
# then ~/.config/zsh. Sets HIST_SRC to the first existing .zsh_history.
locate_history() {
  local line v="" xdg="${XDG_CONFIG_HOME:-$HOME/.config}" cand
  HIST_SRC=""
  if [ -f "$HOME/.zshenv" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?ZDOTDIR=(.*)$ ]]; then
        v="${BASH_REMATCH[2]}"
      fi
    done <"$HOME/.zshenv"
  fi
  if [ -n "$v" ]; then
    v="${v%%[[:space:]]\#*}"
    v="${v#\"}"
    v="${v%\"}"
    v="${v#\'}"
    v="${v%\'}"
    v="${v//\$\{HOME\}/"$HOME"}"
    v="${v//\$HOME/"$HOME"}"
    v="${v//\$\{XDG_CONFIG_HOME:-"$HOME"\/.config\}/"$xdg"}"
    v="${v//\$\{XDG_CONFIG_HOME\}/"$xdg"}"
    v="${v//\$XDG_CONFIG_HOME/"$xdg"}"
    v="$(tilde "$v")"
    case "$v" in
      *\$* | *\`* | "") v="" ;;
      /*) ;;
      *) v="" ;;
    esac
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
# lines (a line ending in an odd number of backslashes continues); plain lines
# of the older format are entries too. One pass, no fork per entry: the rules
# are df_history_is_secret itself, called as a function.
filter_history() {
  local in="$1" out="$2" line entry="" have=0 cont=0 t
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
    cont=0
    if [[ $line == *\\ ]]; then
      t="${line##*[!\\]}"
      if [ $((${#t} % 2)) = 1 ]; then cont=1; fi
    fi
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
  local v p
  split_vals "$1" vals
  for v in "${vals[@]}"; do
    [ -n "$v" ] || continue
    p="$(tilde "$v")"
    case "$p" in /*) ;; *) p="$2/$p" ;; esac
    if [ -s "$p" ]; then
      GIT_INC_KEEP+=("$v")
      case "$v" in /* | "$TILDE"/*) ;; *) GIT_WARN+=("include.path = $v is relative and may not resolve from ~/.gitconfig.local") ;; esac
      check_old_ref include.path "$v"
    else
      GIT_INC_REWRITE=1
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
  if [ "$GIT_INC_REWRITE" = 1 ]; then
    git config --file "$dest" --unset-all include.path
    for v in ${GIT_INC_KEEP[@]+"${GIT_INC_KEEP[@]}"}; do
      git config --file "$dest" --add include.path "$v"
    done
  fi
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
  for key in ${GIT_DROPPED[@]+"${GIT_DROPPED[@]}"}; do log_info "git: $key"; done
  for key in ${GIT_SKIPPED[@]+"${GIT_SKIPPED[@]}"}; do log_info "git: $key: skipped, config/git/config sets the same"; done
  for key in ${GIT_WARN[@]+"${GIT_WARN[@]}"}; do log_warn "git: $key"; done
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
        if [ "$n" -gt 1 ]; then
          printf '  %s (%d values)\n' "$key" "$n"
        else
          printf '  %s = %s\n' "$key" "${parts[0]}"
        fi
        ;;
    esac
  done
  printf '  (+ %d identity keys, user.* and credential.*, not listed)\n\n' "$identity"
}

# --- mise ------------------------------------------------------------------------------------------
report_mise() {
  local old="$HOME/.config/mise/config.toml" new="$self_root/config/mise/config.workstation.toml"
  printf '\nmise: old config against config/mise/config.workstation.toml (informational):\n'
  if [ ! -f "$old" ]; then
    printf '  no ~/.config/mise/config.toml\n\n'
    return 0
  fi
  diff -u --label "old ~/.config/mise/config.toml" --label "new config.workstation.toml" "$old" "$new" || true
  printf '\n'
}

# --- the plan, shared by --dry-run and the real run ----------------------------------------------
BK_ITEMS=(.zshenv .bashrc .profile .bash_profile .config/mise/config.toml .config/zsh)

report_plan() {
  local i verb="would" item
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
  log_info "links: $verb remove ${#LINK_PATHS[@]} symlinks that point into the old dotfiles"
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
  if [ -n "${DOTFILES_REPO:-}" ]; then
    log_info "install: $verb run: DOTFILES_REPO=$DOTFILES_REPO bash $self_root/install.sh --profile workstation"
  else
    log_info "install: $verb run: DOTFILES_SRC=$self_root bash $self_root/install.sh --profile workstation"
  fi
}

# --- the real run ------------------------------------------------------------------------------------
# backup_copies: copies of what the install may replace; nothing is removed yet.
backup_copies() {
  local item src dst
  for item in "${BK_ITEMS[@]}" .gitconfig .gitconfig.local .zsh_history; do
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
  local f="$BK/restore.sh" i
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
#   5. removes the migration marker
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
      printf 'undo_created "$HOME/.zsh_history" %s' "$(_sha "$BK/staged/zsh_history")"
      if [ "$HIST_PREEXISTED" = 1 ]; then printf ' "$BK/.zsh_history"'; fi
      printf '\n'
    fi
    # shellcheck disable=SC2016
    if [ -f "$BK/staged/gitconfig.local" ]; then
      printf 'undo_created "$HOME/.gitconfig.local" %s' "$(_sha "$BK/staged/gitconfig.local")"
      if [ "$GITLOCAL_PREEXISTED" = 1 ]; then printf ' "$BK/.gitconfig.local"'; fi
      printf '\n'
    fi
    # shellcheck disable=SC2016
    if [ -f "$BK/staged/git-ignore" ]; then
      printf 'undo_created "$HOME/.config/git/ignore" %s\n' "$(_sha "$BK/staged/git-ignore")"
    fi
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
  local l git_before="" git_after=""
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

  if [ -n "${DOTFILES_REPO:-}" ]; then
    unset DOTFILES_SRC
  else
    export DOTFILES_SRC="$self_root"
  fi
  bash "$self_root/install.sh" --profile workstation || die "install.sh failed"

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
  report_mise
  log_info "dry run done: nothing was written"
  exit 0
fi

stage
report_plan
report_git
report_mise
apply

log_info "migrated. Open a new terminal to check the shell."
log_info "backup: $BK"
log_info "roll back: dotfiles uninstall && bash $BK/restore.sh"
