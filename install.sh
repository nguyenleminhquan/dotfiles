#!/usr/bin/env bash
# Dotfiles installer (user scope, no sudo).
#
#   install.sh [--profile minimal|server|workstation] [--dry-run] [--no-tools] [--update]
#
# Where the code comes from (first match wins):
#   1. DOTFILES_SRC: mirror of a local checkout (works offline); when it is
#      $DOTFILES_DIR itself nothing is copied
#   2. this script already lives in $DOTFILES_DIR (and DOTFILES_SRC is unset):
#      nothing to fetch
#   3. DOTFILES_REPO + git: clone, or bring an existing clone to the ref
#   4. DOTFILES_REPO + curl/tar: GitHub tarball, mirrored
# An existing $DOTFILES_DIR that this installer did not create is refused.
# DOTFILES_REF picks the branch or tag (default main); DOTFILES_DIR is the
# install location (default: the one an earlier install recorded, else
# ~/.dotfiles). Piped from curl, DOTFILES_REPO defaults to DOTFILES_DEFAULT_REPO.
#
# --update is what `dotfiles update` runs: fetch the newest code even though
# this script lives in $DOTFILES_DIR (from DOTFILES_REPO, else the repo and ref
# recorded in ~/.config/dotfiles/repo, else the clone's own origin and branch),
# then run the new install.sh from there. This is the one implementation of the
# git and tarball fetch.
#
# The profile defaults to the one saved in ~/.config/dotfiles/profile, then to
# "workstation" under WSL; on any other host --profile is mandatory.
#
# server and workstation also install zsh-bin (only when the host has no zsh 5.8+),
# mise and its tools, and generate zsh completions: that needs the network.
# minimal never downloads anything; it removes what a higher profile installed
# earlier, also with --no-tools. --no-tools (or DOTFILES_NO_TOOLS=1) links the
# files and skips the downloads.
#
# The last step is `dotfiles doctor`; when it reports a FAIL the installer exits
# non-zero (after everything else is done). A dry run skips it.
set -euo pipefail

# The repository a piped install (curl ... | bash) fetches when DOTFILES_REPO is
# not set.
DOTFILES_DEFAULT_REPO="https://github.com/nguyenleminhquan/dotfiles"

# Minimal logging for the fetch phase, before lib/log.sh exists (it may not
# have been downloaded yet). Same format; lib/log.sh replaces these once sourced.
log_info() { printf '[info] %s\n' "$*" >&2; }
log_warn() { printf '[warn] %s\n' "$*" >&2; }
log_error() { printf '[error] %s\n' "$*" >&2; }
die() {
  log_error "$@"
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: install.sh [--profile minimal|server|workstation] [--dry-run] [--no-tools] [--update]

  --update   fetch the newest code first (what `dotfiles update` runs)

environment:
  DOTFILES_SRC   local checkout to copy from (no network)
  DOTFILES_REPO  GitHub repo URL to clone or download
  DOTFILES_REF   branch or tag (default: main)
  DOTFILES_DIR   install location (default: the recorded one, else ~/.dotfiles)
  DOTFILES_NO_TOOLS=1  same as --no-tools
EOF
}

profile=""
dry_run=0
no_tools=0
update=0
# The arguments again for the re-exec of an update, minus --update.
reexec_args=()
[ -z "${DOTFILES_NO_TOOLS:-}" ] || no_tools=1
while [ $# -gt 0 ]; do
  [ "$1" = --update ] || reexec_args+=("$1")
  case "$1" in
    --profile)
      [ $# -ge 2 ] || die "--profile needs a value"
      profile="$2"
      reexec_args+=("$2")
      shift 2
      ;;
    --profile=*)
      profile="${1#--profile=}"
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --no-tools)
      no_tools=1
      shift
      ;;
    --update)
      update=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

# Directory this script lives in; empty when it is piped into bash.
self_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fi

# The install location: DOTFILES_DIR, then the one recorded by an earlier
# install, then ~/.dotfiles (lib/dir.sh, shared with uninstall.sh and
# bin/dotfiles). Piped from curl there is no lib yet: the same steps inline.
if [ -n "$self_dir" ] && [ -f "$self_dir/lib/dir.sh" ]; then
  # shellcheck source=lib/dir.sh
  . "$self_dir/lib/dir.sh"
  df_resolve_dir
else
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set to an existing directory"
  if [ -z "${DOTFILES_DIR:-}" ] && [ -r "$HOME/.config/dotfiles/dir" ]; then
    read -r DOTFILES_DIR <"$HOME/.config/dotfiles/dir" || :
  fi
  DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
  DOTFILES_DIR="${DOTFILES_DIR%/}"
  case "$DOTFILES_DIR" in
    /?*) ;;
    *) die "DOTFILES_DIR must be an absolute path other than /: '$DOTFILES_DIR'" ;;
  esac
  [ "$DOTFILES_DIR" != "$HOME" ] || die "DOTFILES_DIR must not be \$HOME itself"
  export DOTFILES_DIR
fi
DF_DRY_RUN="$dry_run"

# _same_dir <a> <b>: both exist and resolve to the same directory.
_same_dir() {
  [ -d "$1" ] && [ -d "$2" ] || return 1
  [ "$(cd "$1" && pwd -P)" = "$(cd "$2" && pwd -P)" ]
}

# Marker file proving that $DOTFILES_DIR was created by this installer. Every
# "is this ours?" decision (replace the directory, follow its symlinks, purge
# it) rests on it, never on the path alone, so a user's own ~/.dotfiles is
# never adopted, merged into or deleted.
DF_MARKER=.dotfiles-managed

_write_marker() {
  printf 'created by dotfiles install.sh; do not delete\n' >"$1/$DF_MARKER"
}

# _dir_unused: $DOTFILES_DIR does not exist or is an empty real directory.
_dir_unused() {
  [ ! -e "$DOTFILES_DIR" ] && [ ! -L "$DOTFILES_DIR" ] && return 0
  [ -d "$DOTFILES_DIR" ] && [ ! -L "$DOTFILES_DIR" ] && [ -z "$(ls -A "$DOTFILES_DIR")" ]
}
# check_dir_usable: refuse to touch a $DOTFILES_DIR we did not create.
check_dir_usable() {
  if _dir_unused; then return 0; fi
  if [ -f "$DOTFILES_DIR/$DF_MARKER" ] && [ ! -L "$DOTFILES_DIR" ]; then return 0; fi
  die "$DOTFILES_DIR already exists and was not created by this installer (it is a non-empty directory, a file or a symlink). Move it aside, for example: mv '$DOTFILES_DIR' '$DOTFILES_DIR.bak-$(date +%Y%m%d-%H%M%S)', or choose another place with DOTFILES_DIR=/some/path"
}

# Temporary directories next to $DOTFILES_DIR get names nobody else owns
# (pid + random, created atomically with mkdir), and only those are ever
# deleted. Names a user may pick, such as .old, .staging or .bak-*, are never
# touched.
STAGING=""
_cleanup_staging() {
  if [ -n "$STAGING" ]; then rm -rf -- "$STAGING"; fi
}

# _unique_sibling <tag>: a not yet existing path "$DOTFILES_DIR.<tag>.<pid>.<random>".
_unique_sibling() {
  local path
  while :; do
    path="$DOTFILES_DIR.$1.$$.$RANDOM"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
}

# _stage: create a fresh empty staging directory next to $DOTFILES_DIR (same
# filesystem, so the final swap is a rename) and set STAGING to its path. It
# is removed again on exit unless the swap succeeded.
_stage() {
  mkdir -p "$(dirname "$DOTFILES_DIR")"
  STAGING="$(_unique_sibling staging)"
  mkdir "$STAGING"
  trap _cleanup_staging EXIT
}

# _swap_in: replace $DOTFILES_DIR by the staged copy, so the result mirrors
# the source exactly and nothing deleted upstream lingers.
_swap_in() {
  local old
  old="$(_unique_sibling old)"
  _write_marker "$STAGING"
  if [ -e "$DOTFILES_DIR" ] && ! mv -- "$DOTFILES_DIR" "$old"; then
    # Nothing was moved yet, so there is nothing to roll back. On WSL1 (Windows
    # file semantics) a directory cannot be renamed while a process has a file
    # or its working directory inside it.
    die "could not move $DOTFILES_DIR aside to replace it. A process with a file or its working directory inside it usually causes this (on WSL1: a shell cd-ed there, an editor); close it and run the update again"
  fi
  if ! mv -- "$STAGING" "$DOTFILES_DIR"; then
    if [ -e "$old" ]; then mv -- "$old" "$DOTFILES_DIR"; fi
    die "could not move the new copy into $DOTFILES_DIR"
  fi
  STAGING=""
  # The old directory was ours (marker checked) or empty, and the name is unique.
  rm -rf -- "$old"
}

# fetch_local: mirror $DOTFILES_SRC into $DOTFILES_DIR, leaving .git behind.
fetch_local() {
  local src="${DOTFILES_SRC%/}" entry name
  [ -f "$src/install.sh" ] && [ -f "$src/lib/log.sh" ] || die "DOTFILES_SRC is not a dotfiles checkout: $src"
  if [ "$dry_run" = 1 ]; then
    log_info "would copy $src to $DOTFILES_DIR"
    return 0
  fi
  _stage
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    [ "$name" != .git ] || continue
    [ "$name" != "$DF_MARKER" ] || continue
    cp -a -- "$entry" "$STAGING/"
  done
  _swap_in
  log_info "copied $src to $DOTFILES_DIR"
}

# Set when the code came from $DOTFILES_REPO; `dotfiles update` needs the repo later.
fetched_repo=0

# fetch_tarball: download the GitHub tarball for $DOTFILES_REF and mirror it.
fetch_tarball() {
  local repo="${DOTFILES_REPO%.git}" ref="${DOTFILES_REF:-main}"
  command -v curl >/dev/null 2>&1 || die "neither git nor curl is available; install one or set DOTFILES_SRC"
  command -v tar >/dev/null 2>&1 || die "tar is required to unpack the tarball"
  if [ "$dry_run" = 1 ]; then
    log_info "would download $repo/archive/$ref.tar.gz into $DOTFILES_DIR"
    return 0
  fi
  _stage
  curl -fsSL "$repo/archive/$ref.tar.gz" | tar -xz --strip-components=1 -C "$STAGING" ||
    die "could not download $repo ($ref)"
  [ -f "$STAGING/install.sh" ] || die "the download from $repo does not look like dotfiles"
  _swap_in
  log_info "downloaded $repo ($ref) to $DOTFILES_DIR"
  fetched_repo=1
}

# update_clone <ref>: bring an existing clone to <ref> (a branch or a tag). A
# clone on a branch fast-forwards, never merges or rewrites; a detached one (a
# tag-pinned install) moves to what the ref points at now.
update_clone() {
  local ref="$1"
  git -C "$DOTFILES_DIR" fetch --quiet --force origin "$ref" || die "could not fetch $ref from origin in $DOTFILES_DIR"
  if git -C "$DOTFILES_DIR" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    git -C "$DOTFILES_DIR" merge --ff-only --quiet FETCH_HEAD ||
      die "$ref cannot be fast-forwarded in $DOTFILES_DIR; resolve it there and run update again"
  else
    git -C "$DOTFILES_DIR" checkout --quiet --detach FETCH_HEAD ||
      die "could not check out $ref in $DOTFILES_DIR; resolve it there and run update again"
  fi
}

# fetch_git: clone into an unused directory, or bring our own clone up to date.
fetch_git() {
  local ref="${DOTFILES_REF:-}"
  if [ -z "$ref" ] && [ -d "$DOTFILES_DIR/.git" ]; then
    # Nothing says which ref: stay on the branch the clone is on.
    ref="$(git -C "$DOTFILES_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [ -n "$ref" ] || die "$DOTFILES_DIR is on a detached HEAD and no ref is recorded: set DOTFILES_REF to a branch or tag"
  fi
  ref="${ref:-main}"
  if [ "$dry_run" = 1 ]; then
    log_info "would clone or update ${DOTFILES_REPO} ($ref) in $DOTFILES_DIR"
    return 0
  fi
  if [ -d "$DOTFILES_DIR/.git" ]; then
    update_clone "$ref"
    log_info "updated $DOTFILES_DIR ($ref)"
    fetched_repo=1
  else
    git clone --quiet --depth 1 --branch "$ref" "$DOTFILES_REPO" "$DOTFILES_DIR"
    _write_marker "$DOTFILES_DIR"
    log_info "cloned ${DOTFILES_REPO} ($ref) to $DOTFILES_DIR"
    fetched_repo=1
  fi
}

# resolve_update_repo: for --update without DOTFILES_REPO, the repo (and ref) to
# fetch from: what the last fetching install recorded in ~/.config/dotfiles/repo
# (URL, then ref), or else the origin of the clone in $DOTFILES_DIR.
resolve_update_repo() {
  local url='' ref=''
  [ -z "${DOTFILES_REPO:-}" ] || return 0
  if [ -r "$state_dir/repo" ]; then
    { IFS= read -r url && IFS= read -r ref; } <"$state_dir/repo" || :
  fi
  if [ -z "$url" ] && [ -d "$DOTFILES_DIR/.git" ] && command -v git >/dev/null 2>&1; then
    url="$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null || true)"
  fi
  [ -n "$url" ] || die "nothing to update from: $DOTFILES_DIR is not a git clone and no repo was recorded; set DOTFILES_SRC to a local checkout, or DOTFILES_REPO to a repo URL"
  DOTFILES_REPO="$url"
  if [ -z "${DOTFILES_REF:-}" ] && [ -n "$ref" ]; then DOTFILES_REF="$ref"; fi
}

fetch_source() {
  # "In place": the code to install already is $DOTFILES_DIR, either named
  # explicitly as the source or because this script is running from it. That
  # is the one way an existing directory without marker is accepted. An update
  # fetches even then.
  local in_place=0
  if [ -n "${DOTFILES_SRC:-}" ]; then
    if _same_dir "$DOTFILES_SRC" "$DOTFILES_DIR"; then in_place=1; fi
  elif [ "$update" = 1 ]; then
    resolve_update_repo
  elif [ -n "$self_dir" ] && _same_dir "$self_dir" "$DOTFILES_DIR"; then
    in_place=1
  fi
  if [ "$in_place" = 1 ]; then
    [ -f "$DOTFILES_DIR/lib/link.sh" ] || die "$DOTFILES_DIR is not a dotfiles checkout"
    if [ "$dry_run" != 1 ] && [ ! -f "$DOTFILES_DIR/$DF_MARKER" ]; then
      _write_marker "$DOTFILES_DIR"
      log_info "using the checkout in $DOTFILES_DIR"
    fi
    return 0
  fi

  check_dir_usable
  if [ -n "${DOTFILES_SRC:-}" ]; then
    fetch_local
    return 0
  fi
  # Piped from curl there is no checkout to take the code from.
  if [ -z "${DOTFILES_REPO:-}" ] && [ -z "$self_dir" ]; then DOTFILES_REPO="$DOTFILES_DEFAULT_REPO"; fi
  [ -n "${DOTFILES_REPO:-}" ] || die "no code source: set DOTFILES_SRC (local checkout) or DOTFILES_REPO (GitHub URL)"
  if [ -d "$DOTFILES_DIR/.git" ]; then
    # A tarball would replace the clone (and its history): never without git.
    command -v git >/dev/null 2>&1 || die "$DOTFILES_DIR is a git clone but git is not installed"
    fetch_git
  elif command -v git >/dev/null 2>&1 && _dir_unused; then
    fetch_git
  else
    fetch_tarball
  fi
}

state_dir="$HOME/.config/dotfiles"

# load_libs <root>: source the libraries found under <root>/lib.
load_libs() {
  # Plain printf: log.sh below redefines die, so the linter sees the call as
  # coming before its definition.
  if [ ! -f "$1/lib/link.sh" ]; then
    printf '[error] libraries not found in %s/lib\n' "$1" >&2
    exit 1
  fi
  # shellcheck source=lib/log.sh
  . "$1/lib/log.sh"
  # shellcheck source=lib/detect.sh
  . "$1/lib/detect.sh"
  # shellcheck source=lib/backup.sh
  . "$1/lib/backup.sh"
  # shellcheck source=lib/link.sh
  . "$1/lib/link.sh"
  # shellcheck source=lib/tools.sh
  . "$1/lib/tools.sh"
}

# preflight: platform check and profile choice. Sets $profile. Runs with the
# code that is about to be installed: before anything is written when that code
# is a local checkout, after the download when it comes from a repo.
preflight() {
  df_detect
  df_platform_supported || exit 1
  if [ -z "$profile" ]; then
    if [ -r "$state_dir/profile" ]; then
      profile="$(head -n 1 "$state_dir/profile")"
    elif [ "${DF_WSL:-0}" != 0 ]; then
      profile=workstation
    else
      die "no saved profile and this is not WSL: pass --profile minimal|server|workstation"
    fi
  fi
  df_profile_valid "$profile" || die "unknown profile: '$profile' (minimal|server|workstation)"
}

# Libraries from any checkout we already have make it possible to run
# preflight before fetching anything. When piped from curl there is none yet,
# and preflight has to wait until the code has been downloaded.
boot_lib=""
for candidate in "$self_dir" "${DOTFILES_SRC:-}"; do
  if [ -n "$candidate" ] && [ -f "$candidate/lib/link.sh" ]; then
    boot_lib="$candidate"
    break
  fi
done
# An installed copy stands in only for a dry run (which downloads nothing), and
# only when this installer created it. A real run replaces that copy, and its
# checks can be older than the code being installed: a copy left by a rejected
# piped install would otherwise keep rejecting a platform the new code supports.
if [ -z "$boot_lib" ] && [ "$dry_run" = 1 ] && [ -f "$DOTFILES_DIR/$DF_MARKER" ] && [ -f "$DOTFILES_DIR/lib/link.sh" ]; then
  boot_lib="$DOTFILES_DIR"
fi
if [ -n "$boot_lib" ]; then
  load_libs "$boot_lib"
  preflight
elif [ "$dry_run" = 1 ]; then
  die "a dry run needs a local checkout: run it from a clone or set DOTFILES_SRC"
fi

fetch_source

if [ "$update" = 1 ] && [ "$dry_run" != 1 ] && [ -z "${DOTFILES_SRC:-}" ]; then
  # The code on disk is new now; this process still runs the old script.
  exec bash "$DOTFILES_DIR/install.sh" "${reexec_args[@]}"
fi

if [ "$dry_run" != 1 ]; then
  # Run from the installed copy, which is what the symlinks will point into.
  load_libs "$DOTFILES_DIR"
  [ -n "$boot_lib" ] || preflight
fi

if [ "$dry_run" = 1 ]; then
  # Nothing was copied, so existence checks look at the checkout we booted from.
  DF_REPO_ROOT="$boot_lib"
  log_info "dry run: nothing will be changed"
fi
log_info "profile: $profile"

df_link_profile "$profile"

if [ "$dry_run" = 1 ]; then
  log_info "would record profile in $state_dir/profile and location in $state_dir/dir"
else
  mkdir -p "$state_dir"
  if [ "$(cat "$state_dir/profile" 2>/dev/null || true)" != "$profile" ]; then
    printf '%s\n' "$profile" >"$state_dir/profile"
  fi
  # The shell startup files cannot find a non-default checkout on their own.
  if [ "$(cat "$state_dir/dir" 2>/dev/null || true)" != "$DOTFILES_DIR" ]; then
    printf '%s\n' "$DOTFILES_DIR" >"$state_dir/dir"
  fi
  # `dotfiles update` downloads from here when there is no clone to pull.
  if [ "$fetched_repo" = 1 ]; then
    repo_record="$(printf '%s\n%s' "$DOTFILES_REPO" "${DOTFILES_REF:-main}")"
    if [ "$(cat "$state_dir/repo" 2>/dev/null || true)" != "$repo_record" ]; then
      printf '%s\n' "$repo_record" >"$state_dir/repo"
    fi
  fi
fi

# Tools. server and workstation download them; minimal removes what a higher
# profile left behind and never touches the network. --no-tools only gates the
# downloads: a downgrade must not leave tools behind because of it.
if [ "$profile" = minimal ]; then
  df_tools_remove
elif [ "$no_tools" = 1 ]; then
  log_info "skipping tools (--no-tools)"
else
  df_tools_install "$profile" || die "tool installation failed; the files are linked, run install.sh again to retry"
fi

if [ "$dry_run" != 1 ]; then
  log_info "installed profile '$profile'"
  # The last step: the health check. A FAIL does not undo the install, it only
  # makes the exit status say so. --no-tools told it the tools are not expected.
  log_info "running dotfiles doctor"
  doctor_rc=0
  (
    # shellcheck source=lib/doctor.sh
    . "$DOTFILES_DIR/lib/doctor.sh"
    if [ "$no_tools" = 1 ]; then export DF_DOCTOR_SKIP_TOOLS=1; fi
    df_doctor
  ) || doctor_rc=$?
  [ "$doctor_rc" = 0 ] || die "installed profile '$profile', but dotfiles doctor reported FAIL (see above); fix it, then run: dotfiles doctor"
fi
