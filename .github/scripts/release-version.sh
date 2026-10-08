#!/usr/bin/env bash
# Decides whether the Release workflow publishes. Prints `release=true` and
# `version=<tag>` (or `release=false`) for $GITHUB_OUTPUT on stdout; the reason on stderr.
#
# cog 7 exits 0 with nothing to release and prints a sentence, not a version, so the exit
# status alone cannot decide: a release needs the dry run's last line to be a version.
# A non-zero exit is a cog failure (bad config, broken history) and fails the job.
set -euo pipefail

# cog's own diagnostics go to stderr, which the job log shows; stdout carries the result.
if ! out="$(cog bump --auto --dry-run)"; then
  echo "cog bump --auto --dry-run failed; see its output above." >&2
  exit 1
fi

last="$(printf '%s\n' "$out" | tail -n1)"

if [[ "$last" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "release=true"
  echo "version=${last}"
  echo "Releasable change detected: ${last}" >&2
else
  echo "release=false"
  echo "No releasable commits since the last tag (cog: ${last}); skipping release." >&2
fi
