# Harness self-test: the container runs as an unprivileged user without sudo.
assert_eq "$(id -un)" "tester" "runs as tester"
assert_eq "$(command -v sudo || true)" "" "no sudo available"
assert_ok "DF_ROW is set" -- test -n "${DF_ROW:-}"
assert_ok "DF_PROFILE is set" -- test -n "${DF_PROFILE:-}"

# assert_fail must not accept a command that does not exist (typo protection).
assert_fail "assert_fail rejects a nonexistent command" -- \
  bash -c '. "$DOTFILES_SRC/test/lib/assert.sh"; assert_fail typo -- no-such-command-xyz'

# home_hash ignores zsh completion dumps but notices real changes.
before="$(home_hash)"
echo dump >"$HOME/.zcompdump"
echo dump >"$HOME/.zcompdump-host-5.9"
assert_eq "$(home_hash)" "$before" "home_hash ignores zcompdump files"
echo content >"$HOME/.harness-probe"
assert_fail "home_hash notices new files" -- test "$(home_hash)" = "$before"
rm -f "$HOME/.zcompdump" "$HOME/.zcompdump-host-5.9" "$HOME/.harness-probe"
