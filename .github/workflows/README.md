# GitHub Actions CI Workflows

This directory contains GitHub Actions workflows for continuous integration and testing.

## Main CI Workflow (`ci.yml`)

The main CI workflow runs on every push and pull request to `main` and `develop` branches.

### Jobs

#### 1. **Test** (matrix)
Elixir/OTP 1.15/26, 1.16/26, 1.17/26, 1.17/27, 1.18/27 and 1.19/28 — the declared floor
(`elixir: "~> 1.15"`) through the newest. Each leg compiles with warnings as errors and runs
`mix test --warnings-as-errors`; the 1.17/27 leg also checks formatting and coverage (threshold in
`mix.exs`).

#### 2. **Integration Tests**
Pushes to `main` only, Elixir 1.15/OTP 26, after the test matrix passes:
`mix test --only integration --only normandy_integration` against the live API when the
`ANTHROPIC_API_KEY` secret is set (skipped otherwise).

#### 3. **Code Quality**
Elixir 1.19/OTP 28: unused-dependency check, `mix hex.audit`, `mix hex.outdated` (informational),
compile without optional dependencies, `mix credo --strict`, `mix dialyzer`, and
`MIX_ENV=dev mix docs --warnings-as-errors`.

#### 4. **Test with unlocked dependencies**
Elixir 1.19/OTP 28: `mix deps.unlock --all`, then compile and test against the newest versions
`mix.exs` allows.

#### 5. **Postgres, Redis and Distributed**
The test files `mix test` excludes, against service containers (Elixir 1.19/OTP 28):
- **Postgres**: `mix test.postgres`
- **Redis**: `mix test.redis`
- **Distributed**: starts `epmd`, then `NORMANDY_REDIS=true mix test.postgres --only distributed`
  with both services, for the multi-node (`:peer`) tests

#### 6. **All Checks Passed**
Fails unless every job above succeeded; Integration Tests may also be skipped.

## Release workflow (`release.yml`)

Runs after CI succeeds on a push to `main`. `.github/scripts/release-version.sh` asks
`cog bump --auto --dry-run` for the next version and releases only when cog names one: a merge with
only `docs:`, `ci:`, `chore:` or `test:` commits since the last tag publishes nothing. A release bumps
`@version`, writes the CHANGELOG section and tags (`cog bump --auto`), publishes to Hex, pushes the bump
commit and the tag, and creates the GitHub release. If `cog` itself fails, the job fails.

### Caching Strategy

The workflow uses GitHub Actions cache for:
1. **Dependencies** (`deps/` and `_build/`):
   - Key: OS + Elixir version + OTP version + mix.lock hash
   - Significantly speeds up subsequent runs

2. **Dialyzer PLT** (`priv/plts/`):
   - Key: OS + Elixir version + OTP version + mix.lock hash
   - Avoids rebuilding type information on every run

## Setting Up Integration Tests

To enable integration tests in CI:

1. Go to your repository settings on GitHub
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Name: `ANTHROPIC_API_KEY`
5. Value: Your Anthropic API key
6. Click **Add secret**

**Note**: Integration tests will be skipped gracefully if the secret is not configured. This allows contributors without API access to still run unit tests.

## Running Tests Locally

### Unit Tests Only
```bash
mix test
```

### Integration Tests Only
```bash
export API_KEY="your-api-key-here"
mix test --only integration --only normandy_integration
```

### All Tests
```bash
export API_KEY="your-api-key-here"
mix test --include integration --include normandy_integration
```

### With Coverage
```bash
mix test --cover
```

## Running Other CI Checks Locally

### Format Check
```bash
mix format --check-formatted
```

### Dialyzer
```bash
mix dialyzer
```

### Dependency Audit
```bash
mix deps.unlock --check-unused
mix hex.outdated
```

### Full CI Simulation
```bash
# Format
mix format --check-formatted

# Compile with warnings as errors
mix compile --warnings-as-errors

# Unit tests
mix test

# Dialyzer
mix dialyzer

# Dependency checks
mix deps.unlock --check-unused
```

## Workflow Triggers

The CI workflow runs on:
- **Push** to `main` or `develop` branches
- **Pull requests** targeting `main` or `develop` branches

## Status Badges

Add CI status badges to your README.md:

```markdown
![CI](https://github.com/thetonymaster/normandy/workflows/CI/badge.svg)
```

## Troubleshooting

### Tests failing only in CI
- Check Elixir/OTP version compatibility
- Ensure all dependencies are in `mix.lock`
- Verify test isolation (no shared state)

### Dialyzer taking too long
- PLT cache should speed up subsequent runs
- First run builds PLT from scratch (slower)

### Integration tests not running
- Verify `ANTHROPIC_API_KEY` secret is set
- Check secret name matches exactly
- Ensure tests are tagged with `integration` or `normandy_integration`

### Cache issues
- Manually clear cache from GitHub Actions tab
- Check cache key includes `mix.lock` hash
- Verify cache restore/save steps are working

## Customization

### Adding More Elixir Versions
Edit the matrix in `.github/workflows/ci.yml`:
```yaml
strategy:
  matrix:
    elixir: ['1.15', '1.16', '1.17', '1.18']  # Add versions here
    otp: ['26', '27']
```

### Changing Test Commands
Modify the test steps:
```yaml
- name: Run unit tests
  run: mix test --trace
```

### Adding Code Coverage Upload
Integrate with services like Codecov:
```yaml
- name: Upload coverage to Codecov
  uses: codecov/codecov-action@v3
  with:
    files: ./cover/excoveralls.json
```
