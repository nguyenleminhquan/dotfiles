# Tools of the server and workstation profiles: zsh-bin (only when the host has
# no usable zsh), mise, the tools mise installs, and zsh completions. Meant to
# be sourced; defines functions only. Needs lib/log.sh. DF_DRY_RUN=1 only logs.
#
# Everything lands under $HOME (never sudo) and everything the installer puts
# there is recorded in ~/.config/dotfiles/, so that downgrading to minimal and
# `uninstall.sh --purge` remove exactly that and nothing the user had before:
#   tools            one word per line: mise-bin (we installed ~/.local/bin/mise),
#                    mise-data (~/.local/share/mise did not exist before us),
#                    zsh-bin (we installed zsh-bin)
#   mise-installs    "<tool dir>/<version>" under ~/.local/share/mise/installs
#   zsh-bin-files    every path the zsh-bin installer created, relative to $HOME
# What mise installs for the user afterwards (`mise use -g`, `mise install`) is
# never recorded: only the installs of our own isolated run are.

# Pins. Bump deliberately: the checksums below are checked against the release.
MISE_VERSION=2026.11.12
# zsh-bin: the installer script is pinned by tag and checksum; the script in
# turn verifies the sha256 of the archive it downloads.
ZSH_BIN_TAG=v6.1.1
ZSH_BIN_INSTALL_SHA256=fc052f5637a95887a4b58cc2bf8eb336a4e90e35e65256abec48ebd02b25e2a2
# Oldest zsh the shell setup is written for; older ones get zsh-bin.
DF_MIN_ZSH=5.8
# Tools whose zsh completion is generated at install time: ours (mise) and the
# host's own (docker, crictl, podman, gh), whichever of them are installed.
DF_COMPLETION_TOOLS=(kubectl helm k9s argocd talosctl task mise docker crictl podman gh)

_df_tools_dir() { printf '%s/.config/dotfiles' "$HOME"; }

_df_tools_mark() {
  local file
  file="$(_df_tools_dir)/tools"
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ] && grep -qxF -- "$1" "$file"; then return 0; fi
  printf '%s\n' "$1" >>"$file"
}

_df_tools_marked() { grep -qxF -- "$1" "$(_df_tools_dir)/tools" 2>/dev/null; }

# _df_tools_unmark <item>: forget one entry; the file goes when it is empty.
_df_tools_unmark() {
  local file tmp
  file="$(_df_tools_dir)/tools"
  [ -f "$file" ] || return 0
  tmp="$file.tmp.$$"
  grep -vxF -- "$1" "$file" >"$tmp" || true
  if [ -s "$tmp" ]; then mv -- "$tmp" "$file"; else rm -f -- "$tmp" "$file"; fi
}

# _df_mktemp_dir: a fresh private directory under the user's cache (nothing is
# written outside $HOME, and a host may have a full or read-only /tmp); prints
# its path, fails when there is none.
_df_mktemp_dir() {
  local base="${XDG_CACHE_HOME:-$HOME/.cache}" d
  mkdir -p "$base" || return 1
  d="$(mktemp -d "$base/dotfiles.XXXXXX")" || return 1
  [ -d "$d" ] || return 1
  printf '%s\n' "$d"
}

# _df_download <url> <dest>
_df_download() {
  command -v curl >/dev/null 2>&1 || {
    log_error "curl is required to download the tools"
    return 1
  }
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" -- "$1" || {
    log_error "download failed: $1"
    return 1
  }
}

# _df_sha256_check <file> <expected hex>: fails for a mismatch and for an
# expected value that is not a sha256 (a missing checksum is never a pass).
_df_sha256_check() {
  local actual
  [[ ${2:-} =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  actual="$(sha256sum <"$1" | cut -d' ' -f1)"
  [ "$actual" = "${2,,}" ]
}

# _df_shasums_lookup <SHASUMS file> <name>: print the checksum of exactly <name>
# ("<sha>  ./<name>" or "<sha> *<name>" lines); fail when it is not listed.
_df_shasums_lookup() {
  DF_LOOKUP_NAME="$2" awk '
    { f = $2; sub(/^\.\//, "", f); sub(/^\*/, "", f) }
    f == ENVIRON["DF_LOOKUP_NAME"] { print $1; found = 1; exit }
    END { exit !found }
  ' "$1"
}

# _df_zsh_version_ok <"zsh 5.8 (...)">: the version is at least $DF_MIN_ZSH.
_df_zsh_version_ok() {
  local v="${1#zsh }" major minor
  v="${v%% *}"
  [[ $v =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  [ "$major" -gt "${DF_MIN_ZSH%%.*}" ] || { [ "$major" -eq "${DF_MIN_ZSH%%.*}" ] && [ "$minor" -ge "${DF_MIN_ZSH#*.}" ]; }
}

# _df_zsh_ok: a zsh on PATH that is new enough.
_df_zsh_ok() {
  local out
  command -v zsh >/dev/null 2>&1 || return 1
  out="$(zsh --version 2>/dev/null)" || return 1
  _df_zsh_version_ok "$out"
}

# _df_zsh_bin_snapshot: sorted list of what zsh-bin can create, relative to $HOME.
_df_zsh_bin_snapshot() {
  (
    cd "$HOME" || exit 1
    for d in .local/bin .local/man .local/share/man .local/share/terminfo .local/share/zsh; do
      [ -e "$d" ] && find "$d" -print
    done | LC_ALL=C sort
  )
}

# df_install_zsh_bin: only when `zsh` is missing or older than $DF_MIN_ZSH.
# Runs the pinned romkatv/zsh-bin installer into ~/.local without touching
# /etc/shells or any rc file, and records what it created.
df_install_zsh_bin() {
  local tmp state rc=0 want_dir
  if _df_zsh_ok; then
    log_info "zsh is new enough, no zsh-bin needed"
    return 0
  fi
  if { [ -e "$HOME/.local/bin/zsh" ] || [ -L "$HOME/.local/bin/zsh" ]; } && ! _df_tools_marked zsh-bin; then
    log_warn "$HOME/.local/bin/zsh exists but is too old or broken, and it is not ours: leaving it"
    return 0
  fi
  want_dir="$HOME/.local"
  mkdir -p "$want_dir"
  # The upstream installer uses sudo for a directory it cannot write to.
  [ -w "$want_dir" ] || {
    log_error "$want_dir is not writable; refusing to let the zsh-bin installer use sudo"
    return 1
  }
  state="$(_df_tools_dir)"
  tmp="$(_df_mktemp_dir)" || {
    log_error "cannot create a temporary directory under ${XDG_CACHE_HOME:-$HOME/.cache}"
    return 1
  }
  _df_download "https://raw.githubusercontent.com/romkatv/zsh-bin/$ZSH_BIN_TAG/install" "$tmp/install" || {
    rm -rf "$tmp"
    return 1
  }
  _df_sha256_check "$tmp/install" "$ZSH_BIN_INSTALL_SHA256" || {
    log_error "zsh-bin installer does not match the pinned checksum"
    rm -rf "$tmp"
    return 1
  }
  _df_zsh_bin_snapshot >"$tmp/before"
  log_info "installing zsh-bin $ZSH_BIN_TAG into ~/.local"
  (cd "$HOME" && sh "$tmp/install" -q -d "$want_dir" -e no -a sha256) || rc=$?
  _df_zsh_bin_snapshot >"$tmp/after"
  # Recorded even after a failure, so that a half-finished install is cleaned up too.
  if [ -n "$(LC_ALL=C comm -13 "$tmp/before" "$tmp/after")" ]; then
    mkdir -p "$state"
    { [ ! -f "$state/zsh-bin-files" ] || cat "$state/zsh-bin-files"; LC_ALL=C comm -13 "$tmp/before" "$tmp/after"; } |
      LC_ALL=C sort -u >"$tmp/files"
    cp -- "$tmp/files" "$state/zsh-bin-files"
    _df_tools_mark zsh-bin
  fi
  rm -rf "$tmp"
  if [ "$rc" -ne 0 ]; then
    log_error "zsh-bin installer failed"
    return 1
  fi
  log_info "installed zsh-bin to ~/.local/bin/zsh"
}

# df_install_mise: mise ${MISE_VERSION} (static musl build, runs on glibc 2.31)
# to ~/.local/bin/mise. The archive is checked against the sha256 in the
# release's SHASUMS256.txt. A mise that is already there and is not ours is
# used as it is.
df_install_mise() {
  local bin="$HOME/.local/bin/mise" asset base cur
  asset="mise-v${MISE_VERSION}-linux-x64-musl.tar.gz"
  base="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}"
  if [ -e "$bin" ] || [ -L "$bin" ]; then
    if ! _df_tools_marked mise-bin; then
      log_info "using the mise that is already at $bin"
      return 0
    fi
    cur="$("$bin" --version 2>/dev/null | cut -d' ' -f1 || true)"
    if [ "$cur" = "$MISE_VERSION" ]; then return 0; fi
  fi
  log_info "installing mise $MISE_VERSION"
  # No `set -e` in here: the subshell runs under `||`, where it would be ignored.
  (
    tmp="$(_df_mktemp_dir)" || {
      log_error "cannot create a temporary directory under ${XDG_CACHE_HOME:-$HOME/.cache}"
      exit 1
    }
    trap 'rm -rf "$tmp"' EXIT
    _df_download "$base/SHASUMS256.txt" "$tmp/SHASUMS256.txt" || exit 1
    want="$(_df_shasums_lookup "$tmp/SHASUMS256.txt" "$asset")" || {
      log_error "no checksum for $asset in SHASUMS256.txt"
      exit 1
    }
    _df_download "$base/$asset" "$tmp/$asset" || exit 1
    _df_sha256_check "$tmp/$asset" "$want" || {
      log_error "checksum mismatch for $asset"
      exit 1
    }
    tar -xzf "$tmp/$asset" -C "$tmp" mise/bin/mise || exit 1
    mkdir -p "$HOME/.local/bin" || exit 1
    # Copy next to the target and rename, so a running mise is never overwritten in place.
    { cp -- "$tmp/mise/bin/mise" "$bin.new.$$" && chmod 0755 "$bin.new.$$" && mv -f -- "$bin.new.$$" "$bin"; } || exit 1
  ) || return 1
  _df_tools_mark mise-bin
}

# _df_mise_installs_snapshot: sorted "<tool dir>/<version>" of what mise has installed.
_df_mise_installs_snapshot() {
  (
    cd "$HOME/.local/share/mise/installs" 2>/dev/null || exit 0
    find . -mindepth 2 -maxdepth 2 -type d | sed 's|^\./||' | LC_ALL=C sort
  )
}

# df_mise_install [profile]: `mise install --yes` for the linked config, and
# for nothing else: whatever else mise would read (~/.tool-versions,
# ~/mise.toml, /etc/mise, the user's ~/.config/mise/config.toml and the other
# fragments in conf.d) is not ours to install, and the installs are recorded as
# ours. That is why mise runs from an empty directory, with a config directory
# that holds only symlinks to our files (conf.d/dotfiles.toml, plus
# config.workstation.toml on the workstation profile), no system config and no
# look-up above the temp dir.
# A GITHUB_TOKEN from the environment, or from ~/.config/dotfiles/env.local,
# reaches mise (it raises the GitHub API limit); it is never stored or printed.
df_mise_install() {
  local profile="${1:-server}" mise data="$HOME/.local/share/mise" tok="${GITHUB_TOKEN:-}" state tmp rc=0 f
  mise="$(command -v mise 2>/dev/null)" || {
    log_error "mise is not installed"
    return 1
  }
  [ -e "$HOME/.config/mise/conf.d/dotfiles.toml" ] || {
    log_error "$HOME/.config/mise/conf.d/dotfiles.toml is missing; link the profile first"
    return 1
  }
  if [ -z "$tok" ] && [ -r "$HOME/.config/dotfiles/env.local" ]; then
    # shellcheck source=/dev/null
    tok="$( . "$HOME/.config/dotfiles/env.local" >/dev/null 2>&1 || true; printf '%s' "${GITHUB_TOKEN:-}")"
  fi
  state="$(_df_tools_dir)"
  if [ ! -e "$data" ] && [ ! -L "$data" ]; then _df_tools_mark mise-data; fi
  tmp="$(_df_mktemp_dir)" || {
    log_error "cannot create a temporary directory under ${XDG_CACHE_HOME:-$HOME/.cache}"
    return 1
  }
  mkdir -p "$tmp/cwd" "$tmp/mise-config/conf.d" "$tmp/mise-system"
  ln -s "$HOME/.config/mise/conf.d/dotfiles.toml" "$tmp/mise-config/conf.d/dotfiles.toml"
  f="$HOME/.config/mise/config.workstation.toml"
  if [ "$profile" = workstation ] && [ -e "$f" ]; then ln -s "$f" "$tmp/mise-config/config.workstation.toml"; fi
  _df_mise_installs_snapshot >"$tmp/before"
  log_info "running mise install"
  (
    if [ -n "$tok" ]; then export GITHUB_TOKEN="$tok"; fi
    unset MISE_GLOBAL_CONFIG_FILE MISE_CONFIG_FILE MISE_ENV
    if [ "$profile" = workstation ]; then export MISE_ENV=workstation; fi
    export MISE_CONFIG_DIR="$tmp/mise-config" MISE_SYSTEM_CONFIG_DIR="$tmp/mise-system" MISE_CEILING_PATHS="$tmp"
    cd "$tmp/cwd" && "$mise" install --yes >&2
  ) || rc=$?
  _df_mise_installs_snapshot >"$tmp/after"
  if [ -n "$(LC_ALL=C comm -13 "$tmp/before" "$tmp/after")" ]; then
    mkdir -p "$state"
    { [ ! -f "$state/mise-installs" ] || cat "$state/mise-installs"; LC_ALL=C comm -13 "$tmp/before" "$tmp/after"; } |
      LC_ALL=C sort -u >"$tmp/list"
    cp -- "$tmp/list" "$state/mise-installs"
  fi
  rm -rf "$tmp"
  if [ "$rc" -ne 0 ]; then
    log_error "mise install failed"
    return 1
  fi
}

# _df_tool_real <tool>: print the path of the real executable, never a mise
# shim (a shim starts mise, which would read its state from the wrong place
# when a tool runs with the XDG directories moved); fail when there is none.
_df_tool_real() {
  local p
  if command -v mise >/dev/null 2>&1 && p="$(cd / && mise which "$1" 2>/dev/null)" && [ -x "$p" ]; then
    printf '%s\n' "$p"
    return 0
  fi
  p="$(command -v "$1" 2>/dev/null)" || return 1
  case "$p" in */mise/shims/*) return 1 ;; esac
  printf '%s\n' "$p"
}

# df_gen_completions: write ~/.cache/zsh/completions/_<tool> for each tool in
# $DF_COMPLETION_TOOLS that is on PATH, and drop the file of one that is gone.
# `compinit -C` (see shell/zshrc) never refreshes its dump, so whenever the set
# of completions changes the dump is deleted and zsh rebuilds it once.
# The tools run with their XDG directories in a scratch directory: k9s, for one,
# creates ~/.local/state/k9s even for `completion`, and nothing but the
# completion file may be left behind by this step.
df_gen_completions() {
  local dir="$HOME/.cache/zsh/completions" tool real out cur changed=0 scratch
  local -a args
  mkdir -p "$dir"
  scratch="$(_df_mktemp_dir)" || {
    log_error "cannot create a temporary directory under ${XDG_CACHE_HOME:-$HOME/.cache}"
    return 1
  }
  for tool in "${DF_COMPLETION_TOOLS[@]}"; do
    if ! real="$(_df_tool_real "$tool")"; then
      if [ -e "$dir/_$tool" ]; then
        rm -f -- "$dir/_$tool"
        changed=1
      fi
      continue
    fi
    # go-task has a flag instead of a subcommand, gh wants the shell as `-s zsh`.
    case "$tool" in
      task) args=(--completion zsh) ;;
      gh) args=(completion -s zsh) ;;
      *) args=(completion zsh) ;;
    esac
    out="$(XDG_STATE_HOME="$scratch/state" XDG_DATA_HOME="$scratch/data" XDG_CONFIG_HOME="$scratch/config" XDG_CACHE_HOME="$scratch/cache" "$real" "${args[@]}" 2>/dev/null)" || out=''
    case "$out" in
      '#compdef'*) ;;
      *)
        log_warn "no zsh completion from $tool"
        continue
        ;;
    esac
    cur="$(cat "$dir/_$tool" 2>/dev/null || true)"
    if [ "$cur" != "$out" ]; then
      printf '%s\n' "$out" >"$dir/_$tool.tmp.$$"
      mv -f -- "$dir/_$tool.tmp.$$" "$dir/_$tool"
      changed=1
    fi
  done
  rm -rf "$scratch"
  if [ "$changed" = 1 ]; then
    rm -f -- "$HOME"/.cache/zsh/zcompdump*
    log_info "zsh completions updated"
  fi
}

# df_tools_install [profile]: everything above, in order. No sudo, no network
# unless something is actually missing.
df_tools_install() {
  local profile="${1:-server}"
  if [ "${DF_DRY_RUN:-0}" = 1 ]; then
    log_info "would install zsh-bin if zsh is older than $DF_MIN_ZSH or missing, mise $MISE_VERSION, the tools in config/mise/config.toml, and zsh completions"
    return 0
  fi
  PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  export PATH
  df_install_zsh_bin && df_install_mise && df_mise_install "$profile" && df_gen_completions
}

# _df_tools_remove_zsh_bin: delete the paths the zsh-bin installer created.
_df_tools_remove_zsh_bin() {
  local list p
  local -a files=() dirs=()
  list="$(_df_tools_dir)/zsh-bin-files"
  [ -f "$list" ] || return 0
  while IFS= read -r p; do
    # Only ever paths below ~/.local, whatever the file says.
    case "$p" in
      .local/*/../* | .local/../* | *'/..') continue ;;
      .local/*) ;;
      *) continue ;;
    esac
    if [ -d "$HOME/$p" ] && [ ! -L "$HOME/$p" ]; then dirs+=("$HOME/$p"); else files+=("$HOME/$p"); fi
  done < <(LC_ALL=C sort -r "$list")
  if [ "${#files[@]}" -gt 0 ]; then rm -f -- "${files[@]}"; fi
  # Longest paths first (sorted in reverse), so children go before parents; a
  # directory that is not empty any more is somebody else's and stays.
  if [ "${#dirs[@]}" -gt 0 ]; then rmdir -- "${dirs[@]}" 2>/dev/null || true; fi
  rm -f -- "$list"
  _df_tools_unmark zsh-bin
  log_info "removed zsh-bin"
}

# _df_tools_remove_mise: the tools mise installed for us, then mise itself.
# The versions we recorded always go. The data directory goes with them only
# when we created it AND nothing else is installed in it: whatever the user
# installed since (`mise use -g`, `mise install`) is theirs and stays.
_df_tools_remove_mise() {
  local list data="$HOME/.local/share/mise" p mise tool_dir own=0 removed=0
  list="$(_df_tools_dir)/mise-installs"
  if _df_tools_marked mise-data; then own=1; fi
  if [ -f "$list" ]; then
    removed=1
    while IFS= read -r p; do
      case "$p" in '' | /* | *..*) continue ;; esac
      rm -rf -- "${data:?}/installs/$p"
      # What mise keeps next to the versions (links such as latest and global,
      # .mise.backend.toml) goes with the last version; with another version
      # left (the user's) only the links that now dangle are dropped.
      tool_dir="$data/installs/${p%/*}"
      if [ -d "$tool_dir" ]; then
        if [ -z "$(find "$tool_dir" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)" ]; then
          rm -rf -- "$tool_dir"
        else
          find "$tool_dir" -mindepth 1 -maxdepth 1 -xtype l -delete 2>/dev/null || true
        fi
      fi
    done <"$list"
    rm -f -- "$list"
    log_info "removed the tools installed by mise"
  fi
  # sigstore-rust is the cache of the attestation check mise runs on downloads.
  if [ "$own" = 1 ]; then rm -rf -- "$HOME/.cache/mise" "$HOME/.cache/sigstore-rust"; fi
  if [ "$own" = 1 ] && [ -z "$(_df_mise_installs_snapshot)" ]; then
    rm -rf -- "$data" "$HOME/.local/state/mise"
  elif [ -d "$data" ] && { [ "$removed" = 1 ] || [ "$own" = 1 ]; }; then
    # Rebuild the shims of what is left, while mise itself is still there.
    mise="$HOME/.local/bin/mise"
    [ -x "$mise" ] || mise="$(command -v mise 2>/dev/null || true)"
    if [ -n "$mise" ]; then "$mise" reshim >/dev/null 2>&1 || true; fi
    if [ "$own" = 1 ]; then log_warn "kept the tools you installed with mise yourself in $data"; fi
  fi
  if [ "$own" = 1 ]; then _df_tools_unmark mise-data; fi
  if _df_tools_marked mise-bin; then
    rm -f -- "$HOME/.local/bin/mise"
    _df_tools_unmark mise-bin
    log_info "removed ~/.local/bin/mise"
  fi
}

# df_caches_remove: the caches our shell files and installer generate (zsh
# completions and dump, shell init scripts, the kube prompt cache). The one
# place that knows them: uninstall.sh and df_tools_remove both call it.
df_caches_remove() {
  rm -rf -- "$HOME/.cache/zsh/completions" "$HOME/.cache/dotfiles/init"
  rm -f -- "$HOME"/.cache/zsh/zcompdump* "$HOME"/.cache/dotfiles/kube-prompt*
}

# df_tools_remove: undo df_tools_install. Removes only what was recorded as
# ours, plus the generated caches. Offline and silent when there is nothing to
# do, so it is safe to call for every minimal install.
df_tools_remove() {
  local state
  state="$(_df_tools_dir)"
  if [ "${DF_DRY_RUN:-0}" = 1 ]; then
    if [ -f "$state/tools" ] || [ -f "$state/mise-installs" ] || [ -f "$state/zsh-bin-files" ]; then
      log_info "would remove the tools an earlier profile installed (mise, its tools, zsh-bin, completions)"
    fi
    return 0
  fi
  _df_tools_remove_mise
  _df_tools_remove_zsh_bin
  df_caches_remove
  # Only when empty: the shell may keep its own files in there.
  rmdir "$HOME/.cache/zsh" "$HOME/.cache/dotfiles" 2>/dev/null || true
  # Empty after the config links are gone; a directory with the user's files stays.
  rmdir "$HOME/.config/mise/conf.d" "$HOME/.config/mise" 2>/dev/null || true
}
