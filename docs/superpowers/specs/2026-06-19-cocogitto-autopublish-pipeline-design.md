# Cocogitto Autopublish Pipeline — Design

**Date:** 2026-06-19
**Status:** Approved (design); pending implementation plan
**Scope:** Add a fully-automatic Hex.pm release pipeline driven by conventional commits, gated on the existing CI (including integration tests), using [cocogitto](https://docs.cocogitto.io/) (`cog`).

## Goal

When commits land on `main` and the **CI** workflow completes successfully (which includes the integration-test job), automatically:

1. Compute the next semantic version from conventional commits.
2. Update `mix.exs` `@version` and `CHANGELOG.md`.
3. Create a `vX.Y.Z` tag and bump commit.
4. Publish the package (and docs) to Hex.pm.
5. Push the tag/commit and create a GitHub Release.

No human in the loop for the publish itself ("fully automatic"). Releases only happen when there are releasable commits; otherwise the pipeline no-ops cleanly.

## Decisions (resolved during brainstorming)

- **Publish gating:** Fully automatic. Every push to `main` that passes CI/integration and contains releasable (`feat`/`fix`/breaking) commits publishes to Hex with no manual approval.
- **Convention enforcement:** Lint **PR titles** with a required CI check (`cog verify`). Squash-merge makes the PR title the release-driving commit subject, so linting the title guarantees every merge to `main` is releasable-or-intentionally-not.
- **Workflow placement:** Separate `release.yml` triggered by `workflow_run` of the **CI** workflow (Approach A), not a job appended to `ci.yml`.
- **Docs:** Publish package **and** HexDocs (default `mix hex.publish` behavior). Retained.

## Current-state facts (verified 2026-06-19)

- Version is hardcoded: `mix.exs:4` → `@version "1.0.0"`.
- Hex package already configured (`package/0`, `description/0` in `mix.exs`); source/homepage point to `github.com/thetonymaster/normandy`.
- CI (`.github/workflows/ci.yml`) jobs: `test` (Elixir/OTP matrix) → `integration-tests` (only on push to `main`, hits real Anthropic API, **skippable** when no API key) → `dependency-audit` → `all-checks-complete` (`if: always()` aggregator that tolerates a *skipped* integration job but fails on a *failed* one).
- Tags follow `vX.Y.Z` (latest `v1.0.0`), consistent with `@version`.
- `CHANGELOG.md` is hand-maintained, Keep-a-Changelog format.
- Commit/PR-title history is **mixed**: some conventional (`feat(tools):`, `fix(llm):`, `chore(release):`), some not (`Phase 7: …`, `Add Redis & Mnesia …`). Squash-merge → PR title becomes the commit subject (`… (#NN)`).
- `main` is **not** branch-protected → cog can push the bump commit + tag directly with `GITHUB_TOKEN`.
- Secrets: only `ANTHROPIC_API_KEY` exists. **No `HEX_API_KEY`.**
- Variables: `NORMANDY_TEST_MODEL = claude-haiku-4-5-20251001`.
- `cog` is not installed locally → must be installed in CI.

## Architecture

### 1. `cog.toml` (repo root)

- `tag_prefix = "v"` — match existing tags.
- `ignore_merge_commits = true`.
- `[changelog]` configured with `remote = "github.com"`, `owner = "thetonymaster"`, `repository = "normandy"` so changelog entries link to commits/PRs/authors.
- `pre_bump_hooks` that:
  1. Rewrite the version in `mix.exs`:
     `sed -i -E 's/@version "[^"]+"/@version "{{version}}"/' mix.exs`
  2. `git add mix.exs` (belt-and-suspenders so the change is staged into cog's bump commit).
- Bump rules (cog defaults): `fix:` → patch, `feat:` → minor, `feat!`/`fix!`/`BREAKING CHANGE` → major. Other types alone → no bump.

### 2. `pr-title` job in `ci.yml`

- Trigger: existing `on: pull_request`.
- Steps: install cog, then `cog verify "${{ github.event.pull_request.title }}"`.
- Effect: PR check fails if the title is not a valid conventional commit. Required for merge.

### 3. `release.yml`

```yaml
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
    branches: [main]
permissions:
  contents: write
concurrency:
  group: release
  cancel-in-progress: false
```

Job guard: `if: github.event.workflow_run.conclusion == 'success'`.

Steps (in order):

1. Checkout `main` with `fetch-depth: 0` (cog needs full history + tags).
2. `erlef/setup-beam` (Elixir 1.17 / OTP 27, matching the CI "primary" combo).
3. Install `cog` (via `cocogitto/cocogitto-action` or pinned release binary — chosen in plan).
4. Configure git identity (a CI bot identity for the bump commit).
5. **Dry-run:** `cog bump --auto --dry-run`. If it exits non-zero (nothing releasable), set an output `release=false` and **stop cleanly** (no failure). Else `release=true`, capture the computed version.
6. *(if release)* `cog bump --auto` — updates `mix.exs` + `CHANGELOG.md`, creates the bump commit and `vX.Y.Z` tag **locally**.
7. *(if release)* `mix deps.get && mix hex.publish --yes` with `env: HEX_API_KEY: ${{ secrets.HEX_API_KEY }}`. **Publish happens before the push.**
8. *(if release, only on publish success)* `git push --follow-tags origin main`.
9. *(if release)* `gh release create vX.Y.Z` with the changelog section as notes (`GITHUB_TOKEN`).

### Data flow

```
conventional commits on main
  → CI workflow success (incl. integration-tests)
  → workflow_run fires release.yml
  → cog computes bump (patch/minor/major)
  → mix.exs @version + CHANGELOG.md updated
  → vX.Y.Z tag + bump commit (local)
  → mix hex.publish (package + docs)        [irreversible step, done first]
  → git push --follow-tags                  [only after publish success]
  → GitHub Release
```

## Failure / edge handling

- **Nothing to release:** dry-run errors → job ends green, no tag, no publish.
- **Publish failure:** local-only bump is discarded with the runner; **no tag is pushed**, so state stays consistent. Re-run after fixing.
- **Publish succeeds but push fails:** Hex has the version but the tag/commit isn't on `main`. Recoverable by re-pushing the tag/commit manually; Hex (the irreversible side) is already correct.
- **Loop safety:** the bump commit is pushed with `GITHUB_TOKEN`, which by GitHub design does **not** trigger `on: push` workflows → no CI↔release loop. A hypothetical re-trigger would no-op anyway (no new releasable commits).
- **Skipped integration tests:** `all-checks-complete` already encodes the acceptable-skip vs. real-failure distinction; release keys off the overall CI `conclusion == success`, inheriting that logic. (In practice `ANTHROPIC_API_KEY` is set, so integration tests run.)

## Prerequisites (one-time, manual)

- Add a `HEX_API_KEY` Actions secret:
  `mix hex.user key generate --key-name normandy-ci --permission api:write`
  → store the printed key as the repo secret `HEX_API_KEY`.
- No branch-protection changes needed (`main` is unprotected).

## Open items to verify during planning (not assumptions)

1. **cog hook-file staging:** confirm cog includes hook-modified files (`mix.exs`) in the bump commit. The `git add mix.exs` in the hook is the safeguard; verify cog's commit semantics (path-scoped vs. index commit) so `mix.exs` reliably ships in the version commit. Fallback: amend in a `post_bump_hook`.
2. **CHANGELOG coexistence:** confirm how cog's first generated entry slots into the existing hand-written Keep-a-Changelog file. May need a one-time insertion-anchor alignment (e.g. an `unreleased` marker or matching the `## [x.y.z]` heading shape cog expects).
3. **cog install method in CI:** `cocogitto/cocogitto-action` vs. pinned binary download — pick and pin a version in the plan.

## Testing strategy

- `pr-title` job: validated by opening a test PR with a non-conventional title (must fail) and a conventional one (must pass).
- `release.yml`: dry-run path validated by a `main` push with only non-releasable commits (must no-op green). Full path validated end-to-end on the first real `feat`/`fix` merge after the secret is added — or rehearsed against a throwaway Hex package / `--dry-run` of `mix hex.build` before the live publish step is enabled.
- cog version computation validated locally with `cog bump --auto --dry-run` against current history before wiring CI.

## Out of scope

- Migrating existing non-conventional history (only future PR titles are enforced).
- Changing the existing CI matrix or integration-test gating.
- Manual/approval-gated release modes (explicitly rejected in favor of full automation).
