#!/usr/bin/env bash
# Usage: tools/api_diff/run.sh <base-ref>        e.g. tools/api_diff/run.sh main
#
# Builds <base-ref> from `git archive` (no worktree, nothing in the repository changes) and the
# working tree, dumps both public APIs and checks every removed or changed item against
# MIGRATING-2.0.md. Exit 0: every item is named there or in reviewed.txt; 1: some are not
# (listed under "## unmatched"); 2: a build failed. Scratch files stay in the printed directory.
set -euo pipefail

base_ref="${1:?usage: tools/api_diff/run.sh <base-ref>}"
root="$(git rev-parse --show-toplevel)"
here="$root/tools/api_diff"
work="$(mktemp -d "${TMPDIR:-/tmp}/normandy-api-diff.XXXXXX")"
mkdir "$work/base"
git -C "$root" archive "$base_ref" | tar -x -C "$work/base"

if ! (cd "$work/base" && MIX_ENV=dev mix deps.get && MIX_ENV=dev mix compile) >"$work/base-build.log" 2>&1; then
  echo "building $base_ref failed; see $work/base-build.log" >&2
  exit 2
fi

if ! (cd "$root" && MIX_ENV=dev mix compile) >"$work/head-build.log" 2>&1; then
  echo "building the working tree failed; see $work/head-build.log" >&2
  exit 2
fi

elixir "$here/cli.exs" dump "$work/base/_build/dev/lib/normandy/ebin" "$work/base.term" || exit 2
elixir "$here/cli.exs" dump "$root/_build/dev/lib/normandy/ebin" "$work/head.term" || exit 2

status=0
elixir "$here/cli.exs" compare "$work/base.term" "$work/head.term" \
  "$root/MIGRATING-2.0.md" "$here/reviewed.txt" | tee "$work/report.txt" || status=$?
echo "report: $work/report.txt"
exit "$status"
