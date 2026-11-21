# Leak guard: the scanner's built-in patterns and the pre-commit hook, which
# also refuses a commit identity that matches a leak pattern. Everything runs
# against a throwaway HOME and repository; corp.example stands in for a
# company domain.
# SC2030/SC2031: HOME is changed in subshells on purpose.
# shellcheck disable=SC2030,SC2031

fx="$(mktemp -d)"
mkdir -p "$fx/home/.config/dotfiles"
guard() { (cd "$fx" && HOME="$fx/home" /src/scripts/check-leaks.sh "$@"); }

# --- scanner: built-in patterns, built at run time so this file holds no token ------
pat="github_pat_$(printf 'A%.0s' $(seq 1 30))"
printf 'token=%s\n' "$pat" >"$fx/pat.txt"
printf 'ghp_%s\n' "$(printf 'b%.0s' $(seq 1 36))" >"$fx/ghp.txt"
printf 'host 192.168.%s.%s\n' 1 5 >"$fx/ip.txt"
printf 'nothing to see here, github_pat_ is only a prefix\n' >"$fx/clean.txt"
assert_fail "a github_pat_ token is flagged" -- guard pat.txt
assert_eq "$(guard pat.txt 2>&1 || true)" "pat.txt:1: GitHub fine-grained token" "the report names file, line and label only"
assert_fail "a ghp_ token is flagged" -- guard ghp.txt
assert_fail "a private IP is flagged" -- guard ip.txt
assert_ok "text without a token passes" -- guard clean.txt
# a custom pattern comes from the patterns file, not from the repo
printf '# company\ncorp\\.example\n' >"$fx/home/.config/dotfiles/leak-patterns"
printf 'mail me at x@corp.example\n' >"$fx/corp.txt"
assert_fail "a custom pattern is applied" -- guard corp.txt
assert_ok "and does not flag clean text" -- guard clean.txt

# --- hook: needs git (the u24-nogit row has none) ----------------------------------
command -v git >/dev/null 2>&1 || { rm -rf "$fx"; return 0; }

repo="$fx/repo"
mkdir -p "$repo/scripts" "$repo/.githooks"
cp /src/scripts/check-leaks.sh "$repo/scripts/"
cp /src/.githooks/pre-commit "$repo/.githooks/"
git -C "$repo" init -q
git -C "$repo" config core.hooksPath .githooks
git -C "$repo" config commit.gpgsign false
# commit <author email> <committer email>: stage a clean file and commit it;
# the output of git (hook messages included) lands in $fx/out.
n=0
commit() {
  n=$((n + 1))
  printf 'line %s\n' "$n" >"$repo/f$n.txt"
  git -C "$repo" add .
  HOME="$fx/home" GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL="$1" GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL="$2" \
    git -C "$repo" commit -q -m "feat: change $n" >"$fx/out" 2>&1
}

assert_ok "a public identity commits" -- commit dev@users.example.com dev@users.example.com
assert_fail "an author matching a pattern is refused" -- commit dev@corp.example dev@users.example.com
assert_ok "the refusal names the author" -- grep -q 'GIT_AUTHOR_IDENT:1: custom pattern #1' "$fx/out"
assert_ok "and says how to fix it" -- grep -q 'identity matches a leak pattern' "$fx/out"
assert_fail "the identity is not echoed" -- grep -q 'dev@corp.example' "$fx/out"
assert_fail "a committer matching a pattern is refused" -- commit dev@users.example.com dev@corp.example
assert_ok "the refusal names the committer" -- grep -q 'GIT_COMMITTER_IDENT:1: custom pattern #1' "$fx/out"
assert_eq "$(git -C "$repo" rev-list --count HEAD)" 1 "refused commits left no commit behind"
assert_ok "the staged content still goes through the content check" -- bash -c '
  printf "mail x@corp.example\n" >"$1/leak.txt"; git -C "$1" add .
  ! HOME="$2" GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@users.example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@users.example.com \
    git -C "$1" commit -q -m "feat: leak" 2>/dev/null' _ "$repo" "$fx/home"
git -C "$repo" reset -q
rm -f "$repo/leak.txt"

# the warning: absent patterns file, every commit, never a failure
assert_fail "with the patterns file there is no warning" -- grep -q 'WARNING' "$fx/out"
rm -f "$fx/home/.config/dotfiles/leak-patterns"
assert_ok "without the patterns file a corp.example identity commits" -- commit dev@corp.example dev@corp.example
assert_ok "and the warning is loud" -- grep -q 'WARNING.*leak-patterns does not exist' "$fx/out"
assert_ok "the warning repeats on the next commit" -- commit dev@users.example.com dev@users.example.com
assert_ok "second warning" -- grep -q 'WARNING.*leak-patterns does not exist' "$fx/out"
rm -rf "$fx"
