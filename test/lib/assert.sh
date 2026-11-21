# Minimal assertion helpers for test cases. Meant to be sourced.
# Every failed assertion prints "FAIL: <msg>" and exits 1; passing ones are silent.

_fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# assert_eq <actual> <expected> <msg>
assert_eq() {
  [ "$#" -eq 3 ] || _fail "assert_eq: expected 3 arguments, got $#"
  if [ "$1" != "$2" ]; then
    printf '  expected: %s\n  actual:   %s\n' "$2" "$1" >&2
    _fail "$3"
  fi
}

# assert_ok <msg> -- <cmd...>
assert_ok() {
  local msg="$1"
  shift
  [ "${1:-}" = "--" ] || _fail "assert_ok: missing '--' separator ($msg)"
  shift
  "$@" >/dev/null 2>&1 || _fail "$msg"
}

# assert_fail <msg> -- <cmd...>
assert_fail() {
  local msg="$1"
  shift
  [ "${1:-}" = "--" ] || _fail "assert_fail: missing '--' separator ($msg)"
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  # 126/127 mean the command could not run at all (typo, missing tool), which
  # must not be mistaken for the expected failure.
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    _fail "$msg (command not found or not executable: $1)"
  fi
  if [ "$rc" -eq 0 ]; then
    _fail "$msg"
  fi
}

# assert_file_absent <path>
assert_file_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    _fail "expected absent: $1"
  fi
}

# assert_symlink <dest> <src>: <dest> must be a symlink whose target is <src>
assert_symlink() {
  [ -L "$1" ] || _fail "not a symlink: $1"
  assert_eq "$(readlink "$1")" "$2" "symlink target of $1"
}

# home_hash: sha256 over every file and symlink under $HOME, skipping caches,
# the mise data dir, shell/editor history files and zsh completion dumps.
# Used to prove idempotence and "no writes" guarantees.
home_hash() {
  (
    cd "$HOME" || exit 1
    find . \
      \( -path ./.cache -o -path ./.local/share/mise \) -prune -o \
      \( -type f -o -type l \) \
      ! -name '*_history' ! -name '.lesshst' ! -name '.viminfo' \
      ! -name '.zcompdump*' \
      -print0 |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' path; do
        if [ -L "$path" ]; then
          printf 'L %s -> %s\n' "$path" "$(readlink "$path")"
        else
          printf 'F %s %s\n' "$path" "$(sha256sum <"$path" | cut -d' ' -f1)"
        fi
      done |
      sha256sum | cut -d' ' -f1
  )
}
