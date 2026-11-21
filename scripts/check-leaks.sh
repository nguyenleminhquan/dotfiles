#!/usr/bin/env bash
# Leak guard: fail when a file contains something that must not be public.
#
#   scripts/check-leaks.sh [files...]
#
# With no arguments it scans every tracked and untracked, non-ignored file.
# Built-in patterns cover private IPs and common credential formats. Extra
# patterns (company hostnames, domains, ...) are read from
# ~/.config/dotfiles/leak-patterns, one extended regex per line, so they never
# live in the repo. Matches are reported as file:line only, never the content.
set -euo pipefail

user_patterns="$HOME/.config/dotfiles/leak-patterns"

# label<TAB>regex
patterns=(
  "private IPv4 class A|(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)"
  "private IPv4 class B|(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)"
  "private IPv4 class C|(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)"
  "GitHub personal access token|ghp_[A-Za-z0-9]{36}"
  "GitLab personal access token|glpat-[A-Za-z0-9_-]{20}"
  "GitHub fine-grained token|github_pat_[A-Za-z0-9_]{22,}"
  "AWS access key id|AKIA[0-9A-Z]{16}"
  "private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)

if [ -f "$user_patterns" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in '' | '#'*) continue ;; esac
    n=$((n + 1))
    patterns+=("custom pattern #$n|$line")
  done <"$user_patterns"
fi

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files -co --exclude-standard)
fi

found=0
for file in "${files[@]}"; do
  [ -f "$file" ] || continue
  for entry in "${patterns[@]}"; do
    label="${entry%%|*}"
    regex="${entry#*|}"
    rc=0
    # -a scans binary and invalid-UTF-8 files too, and LC_ALL=C keeps bytes
    # opaque so a stray Latin-1 byte cannot hide a match. NULs are dropped
    # because bash cannot hold them in a variable.
    hits="$(LC_ALL=C grep -naE -e "$regex" -- "$file" | tr -d '\0'; exit "${PIPESTATUS[0]}")" || rc=$?
    if [ "$rc" -gt 1 ]; then
      printf 'check-leaks: invalid pattern (%s)\n' "$label" >&2
      exit 2
    fi
    [ "$rc" -eq 0 ] || continue
    while IFS= read -r hit; do
      printf '%s:%s: %s\n' "$file" "${hit%%:*}" "$label"
    done <<<"$hits"
    found=1
  done
done

exit "$found"
