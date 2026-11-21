# Harness self-test: the container runs as an unprivileged user without sudo.
assert_eq "$(id -un)" "tester" "runs as tester"
assert_fail "no sudo available" -- sudo -n true
