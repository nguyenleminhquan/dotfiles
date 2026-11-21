#!/usr/bin/env bash
# Runs one test case inside the container: run-case.sh <case> <profile> [row]
set -euo pipefail

case_name="${1:?usage: run-case.sh <case> <profile>}"
profile="${2:?usage: run-case.sh <case> <profile>}"

export DOTFILES_SRC=/src
export DF_PROFILE="$profile"
# Matrix row name (e.g. u24-nogit) so cases can branch on the environment.
export DF_ROW="${3:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
. "$here/lib/assert.sh"

case_file="$here/cases/$case_name.sh"
[ -f "$case_file" ] || { printf 'FAIL: no such case: %s\n' "$case_name" >&2; exit 1; }

# shellcheck source=/dev/null
. "$case_file"
