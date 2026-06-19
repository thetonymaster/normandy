# Cocogitto Autopublish Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically publish the Normandy Elixir library to Hex.pm with a conventional-commit-derived version, whenever the CI workflow (including integration tests) succeeds on `main`.

**Architecture:** A pinned `cog` (cocogitto 7.0.0) binary computes the next semver from conventional commits, rewrites `mix.exs` + `CHANGELOG.md`, and tags. A standalone `release.yml` runs via `workflow_run` after CI concludes successfully on `main`; it publishes to Hex *before* pushing the tag so a failed publish never leaves a dangling tag. A separate `pr-title.yml` lints PR titles (the squash-merge commit subject) with `cog verify`.

**Tech Stack:** cocogitto 7.0.0 (`cog`), GitHub Actions (`workflow_run`, `erlef/setup-beam`), Elixir/Mix (`mix hex.publish`), bash.

## Global Constraints

- **cocogitto version is pinned to `7.0.0`** everywhere (install script `COG_VERSION` default). Copy verbatim.
- **Tag prefix is `v`** (`cog.toml` `tag_prefix = "v"`) — matches existing `v0.1.0`…`v1.0.0` tags.
- **Release job BEAM versions: Elixir `1.17` / OTP `27`** (the CI "primary" combo).
- **Publish-before-push ordering is mandatory:** `mix hex.publish` runs *before* `git push` of the bump commit/tag.
- **Do NOT set `MIX_ENV=test` in the release job** — `mix hex.publish` builds docs via `ex_doc` (`only: :dev`); it must run in the default (`dev`) env.
- **Never interpolate `${{ github.event.pull_request.title }}` directly into a `run:` script.** Pass it through an `env:` var and reference `"$PR_TITLE"` (shell-injection safety).
- **Use the default `GITHUB_TOKEN` for pushes** (no PAT). `main` is unprotected, and `GITHUB_TOKEN` pushes do not re-trigger `on: push` CI → no release loop.
- **Non-feat/fix conventional types do not bump** (`ci`, `build`, `chore`, `docs`, `test`, `refactor`, `style`). Use these for this plan's own setup commits so the pipeline doesn't attribute an unintended bump to its own scaffolding.

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `.github/scripts/install-cog.sh` | Create | OS/arch-aware download+install of pinned `cog` into a PATH dir. Reused by both workflows and runnable on the macOS dev machine. |
| `cog.toml` | Create | cocogitto config: tag prefix, merge-commit ignore, `mix.exs` version rewrite hook, GitHub changelog linking. |
| `CHANGELOG.md` | Modify | Insert the cocogitto `- - -` insertion anchor between the header and `## [1.0.0]`. Old hand-written entries stay below. |
| `.github/workflows/pr-title.yml` | Create | Lint PR titles as conventional commits via `cog verify`. |
| `.github/workflows/release.yml` | Create | The release pipeline: gate on CI success, compute bump, publish to Hex, push, GitHub Release. |

**Manual prerequisite (not a code change):** add a `HEX_API_KEY` Actions secret (Task 5).

---

### Task 1: Pinned `cog` install script

**Files:**
- Create: `.github/scripts/install-cog.sh`

**Interfaces:**
- Produces: an executable that installs `cog` `7.0.0` into `${1:-$HOME/.local/bin}/cog`. Honors `COG_VERSION` (default `7.0.0`) and a positional install-dir arg. Used by Task 2 (local verification) and Tasks 3–4 (CI).

- [ ] **Step 1: Write the install script**

Create `.github/scripts/install-cog.sh`:

```bash
#!/usr/bin/env bash
# Installs a pinned cocogitto (cog) binary for the current OS/arch.
# Usage: install-cog.sh [INSTALL_DIR]   (default: $HOME/.local/bin)
#        COG_VERSION=7.0.0 install-cog.sh
set -euo pipefail

COG_VERSION="${COG_VERSION:-7.0.0}"
INSTALL_DIR="${1:-$HOME/.local/bin}"

os="$(uname -s)"
arch="$(uname -m)"
case "${os}-${arch}" in
  Darwin-arm64)   asset="cocogitto-${COG_VERSION}-aarch64-apple-darwin.tar.gz" ;;
  Darwin-x86_64)  asset="cocogitto-${COG_VERSION}-x86_64-apple-darwin.tar.gz" ;;
  Linux-x86_64)   asset="cocogitto-${COG_VERSION}-x86_64-unknown-linux-musl.tar.gz" ;;
  Linux-aarch64)  asset="cocogitto-${COG_VERSION}-aarch64-unknown-linux-gnu.tar.gz" ;;
  *) echo "Unsupported platform: ${os}-${arch}" >&2; exit 1 ;;
esac

url="https://github.com/cocogitto/cocogitto/releases/download/${COG_VERSION}/${asset}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "Downloading ${url}"
curl -fsSL "${url}" -o "${tmp}/cog.tar.gz"
tar -xzf "${tmp}/cog.tar.gz" -C "${tmp}"

bin="$(find "${tmp}" -type f -name cog | head -n1)"
if [ -z "${bin}" ]; then
  echo "cog binary not found in archive" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
install "${bin}" "${INSTALL_DIR}/cog"
echo "Installed cog ${COG_VERSION} to ${INSTALL_DIR}/cog"
"${INSTALL_DIR}/cog" --version
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x .github/scripts/install-cog.sh`

- [ ] **Step 3: Lint the script**

Run: `shellcheck .github/scripts/install-cog.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Run it locally to verify install works on this machine**

Run: `./.github/scripts/install-cog.sh "$HOME/.local/bin" && "$HOME/.local/bin/cog" --version`
Expected: ends with a line like `cog 7.0.0` (the macOS arm64 binary downloads and runs).

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/install-cog.sh
git commit -m "ci: add pinned cocogitto install script"
```

---

### Task 2: `cog.toml` + CHANGELOG anchor (the version engine)

**Files:**
- Create: `cog.toml`
- Modify: `CHANGELOG.md` (insert `- - -` anchor after the header block, before `## [1.0.0] - 2026-06-17`)

**Interfaces:**
- Consumes: `cog` on PATH (Task 1), `mix.exs:4` line `@version "1.0.0"`.
- Produces: a config where `cog bump --auto` computes the next version, rewrites `mix.exs` `@version`, and prepends a linked changelog entry.

- [ ] **Step 1: Write `cog.toml`**

Create `cog.toml` in the repo root:

```toml
# Cocogitto configuration — drives automatic versioning, changelog, and release.
# Reference: https://docs.cocogitto.io/reference/config.html
tag_prefix = "v"
ignore_merge_commits = true

# Rewrite the Elixir package version into mix.exs before the version commit.
# Files modified by pre_bump_hooks are included in cocogitto's bump commit.
# {{version}} expands to the version being bumped to (e.g. "1.1.0").
# sed -i.bak is portable across GNU (CI) and BSD (macOS) sed.
pre_bump_hooks = [
  "sed -i.bak -E 's/@version \"[^\"]+\"/@version \"{{version}}\"/' mix.exs && rm -f mix.exs.bak",
]

[changelog]
path = "CHANGELOG.md"
template = "remote"
remote = "github.com"
owner = "thetonymaster"
repository = "normandy"
```

- [ ] **Step 2: Add the changelog insertion anchor**

In `CHANGELOG.md`, insert a `- - -` line (cocogitto's insertion marker) between the header and the first entry. The region currently reads:

```
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-17
```

Change it to:

```
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- - -

## [1.0.0] - 2026-06-17
```

- [ ] **Step 3: Verify the next version is computed correctly (the core "test")**

Run: `cog bump --auto --dry-run`
Expected: prints `1.1.0` (the only releasable commit since `v1.0.0` is `feat(tools): … (#40)` → MINOR). If it prints nothing/errors, STOP — the config or history range is wrong.

- [ ] **Step 4: Verify the `mix.exs` rewrite hook regex works (non-destructive test)**

Run:
```bash
cp mix.exs /tmp/mix.exs.test
sed -i.bak -E 's/@version "[^"]+"/@version "9.9.9"/' /tmp/mix.exs.test && rm -f /tmp/mix.exs.test.bak
grep '@version' /tmp/mix.exs.test
```
Expected: `  @version "9.9.9"`. (Confirms the `pre_bump_hooks` sed targets `mix.exs:4`.) Then `rm /tmp/mix.exs.test`.

- [ ] **Step 5: Confirm no working-tree side effects from the dry-run**

Run: `git status --short`
Expected: only `cog.toml` (untracked) and `CHANGELOG.md` (modified). `mix.exs` must be unchanged (dry-run does not bump).

- [ ] **Step 6: Commit**

```bash
git add cog.toml CHANGELOG.md
git commit -m "ci: configure cocogitto versioning and changelog anchor"
```

---

### Task 3: PR-title lint workflow

**Files:**
- Create: `.github/workflows/pr-title.yml`

**Interfaces:**
- Consumes: `.github/scripts/install-cog.sh` (Task 1), `github.event.pull_request.title`.
- Produces: a required PR check `Lint PR title (conventional commit)` that fails non-conventional titles.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/pr-title.yml`:

```yaml
name: PR Title

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

permissions:
  contents: read

jobs:
  lint-pr-title:
    name: Lint PR title (conventional commit)
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install cocogitto
        run: |
          .github/scripts/install-cog.sh "$HOME/.local/bin"
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"

      - name: Verify PR title is a conventional commit
        env:
          PR_TITLE: ${{ github.event.pull_request.title }}
        run: cog verify "$PR_TITLE"
```

- [ ] **Step 2: Lint the workflow (YAML + embedded shell)**

Run: `actionlint .github/workflows/pr-title.yml`
Expected: no output, exit code 0. (actionlint also runs shellcheck on the `run:` blocks.)

- [ ] **Step 3: Verify `cog verify` accepts a good title and rejects a bad one (local "test")**

Run:
```bash
cog verify "feat(tools): add a thing"; echo "good exit: $?"
cog verify "Add a thing without a type" || echo "bad exit: $?"
```
Expected: first prints commit details and `good exit: 0`; second prints an `Error: Missing commit type separator` and `bad exit: 1` (non-zero).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr-title.yml
git commit -m "ci: lint PR titles as conventional commits"
```

---

### Task 4: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `.github/scripts/install-cog.sh` (Task 1), `cog.toml` (Task 2), the CI workflow named `CI`, secrets `HEX_API_KEY` (Task 5) and `GITHUB_TOKEN`.
- Produces: on a successful CI run on `main` with releasable commits → a new `vX.Y.Z` tag, a Hex.pm release, a pushed bump commit, and a GitHub Release. No-ops cleanly otherwise.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

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

jobs:
  release:
    name: Release to Hex.pm
    runs-on: ubuntu-latest
    # Only when the whole CI workflow (incl. integration-tests via all-checks-complete) succeeded.
    if: github.event.workflow_run.conclusion == 'success'
    env:
      ELIXIR_VERSION: '1.17'
      OTP_VERSION: '27'
    steps:
      - name: Checkout main (full history + tags)
        uses: actions/checkout@v4
        with:
          ref: main
          fetch-depth: 0

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}

      - name: Install cocogitto
        run: |
          .github/scripts/install-cog.sh "$HOME/.local/bin"
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"

      - name: Configure git identity
        run: |
          git config user.name "normandy-release-bot"
          git config user.email "release-bot@users.noreply.github.com"

      - name: Determine next version
        id: bump_check
        run: |
          # No pipe in the `if` condition: the exit status must be cog's, not
          # tail's. Piping here would mask a non-zero cog exit unless pipefail
          # is set, breaking the clean no-op when nothing is releasable.
          if version="$(cog bump --auto --dry-run 2>/dev/null)"; then
            version="$(printf '%s\n' "$version" | tail -n1)"
            echo "release=true" >> "$GITHUB_OUTPUT"
            echo "version=${version}" >> "$GITHUB_OUTPUT"
            echo "Releasable change detected: ${version}"
          else
            echo "release=false" >> "$GITHUB_OUTPUT"
            echo "No releasable commits since last tag; skipping release."
          fi

      - name: Bump version, changelog, and tag
        if: steps.bump_check.outputs.release == 'true'
        run: cog bump --auto

      - name: Resolve created tag
        id: tag
        if: steps.bump_check.outputs.release == 'true'
        run: echo "tag=$(git describe --tags --abbrev=0)" >> "$GITHUB_OUTPUT"

      - name: Fetch dependencies
        if: steps.bump_check.outputs.release == 'true'
        run: mix deps.get

      - name: Publish to Hex.pm
        if: steps.bump_check.outputs.release == 'true'
        env:
          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}
        run: mix hex.publish --yes

      - name: Push bump commit and tag
        if: steps.bump_check.outputs.release == 'true'
        run: |
          git push origin main
          git push origin "${{ steps.tag.outputs.tag }}"

      - name: Create GitHub Release
        if: steps.bump_check.outputs.release == 'true'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh release create "${{ steps.tag.outputs.tag }}" --title "${{ steps.tag.outputs.tag }}" --generate-notes
```

- [ ] **Step 2: Lint the workflow (YAML + embedded shell)**

Run: `actionlint .github/workflows/release.yml`
Expected: no output, exit code 0. (Confirms the `run:` shell blocks pass shellcheck and `${{ }}` references resolve.)

- [ ] **Step 3: Verify both branches of the no-op guard logic (deterministic, no repo mutation)**

The guard must not depend on `pipefail`. Prove the real path and the no-op path:
```bash
# Real path: a releasable commit exists since v1.0.0 → prints a version.
cog bump --auto --dry-run
# No-op path: with no pipe in the condition, a failing command takes the else branch
# regardless of pipefail (run in a non-pipefail shell to prove robustness).
bash -c 'set +o pipefail; if v="$(false)"; then echo "release=true v=$v"; else echo "release=false (no-op path)"; fi'
```
Expected: first prints `1.1.0`; second prints `release=false (no-op path)`. If a pipe were left in the `if` condition, the second would wrongly print `release=true`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add cocogitto-driven Hex.pm autopublish workflow"
```

---

### Task 5: Go-live — secret, rehearsal, and activation runbook

**Files:** none (manual GitHub configuration + a rehearsal). This task is the controlled activation.

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: a live pipeline. **First activation will publish `1.1.0`** (the unreleased `feat(tools): … #40`).

- [ ] **Step 1: Generate a Hex CI key**

Run locally (authenticated `mix hex.user`):
```bash
mix hex.user key generate --key-name normandy-ci --permission api:write
```
Expected: prints a key string. Copy it.

- [ ] **Step 2: Add the `HEX_API_KEY` repo secret**

Run: `gh secret set HEX_API_KEY --repo thetonymaster/normandy`
Paste the key when prompted.
Verify: `gh secret list --repo thetonymaster/normandy` shows `HEX_API_KEY`.

- [ ] **Step 3: Rehearse the package build (no publish)**

Run: `mix hex.build`
Expected: builds `normandy-1.0.0.tar` (current version) with no errors and lists the `files` from `package/0`. Confirms the package is publishable before the live run. (Do NOT run `mix hex.publish` here.)

- [ ] **Step 4: Open the setup PR with a NON-bumping title**

Title the PR for Tasks 1–4 `ci: add cocogitto autopublish pipeline` (a `ci:` title does not itself cause a bump). Merge via **squash** once CI is green.

- [ ] **Step 5: Observe the first automatic release**

After merge to `main`, CI runs → on success `release.yml` triggers. Watch: `gh run watch` (or the Actions tab).
Expected sequence: `Determine next version` → `Releasable change detected: 1.1.0`; `Publish to Hex.pm` succeeds; tag `v1.1.0` pushed; GitHub Release `v1.1.0` created.
Verify: `mix hex.info normandy` shows `1.1.0`; `git tag --list | tail -1` shows `v1.1.0`; `mix.exs` `@version` on `main` is `1.1.0`.

- [ ] **Step 6: Confirm no release loop**

After the bump commit lands on `main` (pushed by `GITHUB_TOKEN`), confirm a *new* CI run was NOT triggered by it (`gh run list --branch main` — the bump commit has no associated CI run). Expected: no loop; the pipeline is idle until the next releasable merge.

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:
- Fully-automatic publish → Task 4 (`release.yml`, no approval gate).
- Conventional-commit enforcement / PR-title lint → Task 3.
- `workflow_run` placement (Approach A) → Task 4 trigger.
- Docs published with package → Task 4 `mix hex.publish` (no `package`-only flag; no `MIX_ENV=test`).
- `cog.toml` with tag prefix, merge ignore, `mix.exs` hook, GitHub changelog → Task 2.
- `pr-title` via `cog verify` → Task 3.
- Publish-before-push ordering → Task 4 step order.
- No-op on nothing-releasable → Task 4 `bump_check` guard.
- Loop safety (`GITHUB_TOKEN`) → Task 4 + Task 5 Step 6.
- `HEX_API_KEY` prerequisite → Task 5.
- Open item "cog hook-file staging" → resolved: docs confirm hook-modified files are committed in the bump commit (Task 2 relies on it; verified by Task 5 Step 5 `mix.exs == 1.1.0`).
- Open item "CHANGELOG coexistence" → resolved: `- - -` anchor (Task 2 Step 2).
- Open item "cog install method" → resolved: pinned binary script (Task 1).

**2. Placeholder scan** — no TBD/TODO/"handle errors"/"similar to". All file contents and commands are concrete with expected outputs.

**3. Type/name consistency** — `install-cog.sh` install dir contract (`$HOME/.local/bin` + `$GITHUB_PATH`) is identical in Tasks 3 and 4. `cog.toml` `owner/repository` (`thetonymaster`/`normandy`) match the git remote. `steps.bump_check.outputs.release`/`version` and `steps.tag.outputs.tag` are defined before use within Task 4. Workflow name `CI` in `release.yml` matches `ci.yml`'s `name: CI`.

**Refinements logged for handoff (faithful-but-better deviations from the design doc):**
1. PR-title lint is its **own** `pr-title.yml` (not a job inside `ci.yml`) so the `edited` trigger re-lints title changes without re-running the whole test matrix.
2. GitHub Release notes use `gh release create --generate-notes` (deterministic) rather than extracting the cocogitto changelog section; the in-repo `CHANGELOG.md` remains the canonical cocogitto-generated changelog.
