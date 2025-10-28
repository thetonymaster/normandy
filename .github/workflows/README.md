# GitHub Actions CI Workflows

This directory contains GitHub Actions workflows for continuous integration and testing.

## Main CI Workflow (`ci.yml`)

The main CI workflow runs on every push and pull request to `main` and `develop` branches.

### Jobs

#### 1. **Test** (Matrix Build)
Runs unit tests across multiple Elixir and OTP versions to ensure compatibility:
- **Elixir versions**: 1.15, 1.16, 1.17
- **OTP versions**: 26, 27
- **Excludes**: Invalid combinations (e.g., Elixir 1.15 with OTP 27)

**Steps**:
- Checkout code
- Set up Elixir/OTP
- Cache dependencies and build artifacts
- Install and compile dependencies
- Check code formatting (on latest version only)
- Compile with warnings as errors
- Run unit tests (excludes `integration` and `normandy_integration` tags)
- Generate coverage report (on latest version only)

#### 2. **Integration Tests**
Runs integration tests that require API access:
- Only runs if unit tests pass
- **Requires**: `ANTHROPIC_API_KEY` repository secret
- Gracefully skips if API key is not configured

**Steps**:
- Runs all tests tagged with `integration` or `normandy_integration`
- Uses the `API_KEY` environment variable from secrets

#### 3. **Dialyzer** (Type Checking)
Performs static type analysis:
- Caches PLT (Persistent Lookup Table) for faster runs
- Reports type errors and inconsistencies
- Uses GitHub-friendly output format

#### 4. **Dependency Audit**
Checks dependency health:
- Verifies no unused dependencies
- Lists outdated dependencies (informational)

#### 5. **All Checks Complete**
Final validation job that:
- Waits for all other jobs
- Fails if any required check failed
- Allows integration tests to be skipped
- Provides clear pass/fail status

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
mix test --exclude integration --exclude normandy_integration
```

### Integration Tests Only
```bash
export API_KEY="your-api-key-here"
mix test --only integration --only normandy_integration
```

### All Tests
```bash
export API_KEY="your-api-key-here"
mix test
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
mix test --exclude integration --exclude normandy_integration

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
  run: mix test --exclude integration --exclude normandy_integration --trace
```

### Adding Code Coverage Upload
Integrate with services like Codecov:
```yaml
- name: Upload coverage to Codecov
  uses: codecov/codecov-action@v3
  with:
    files: ./cover/excoveralls.json
```
