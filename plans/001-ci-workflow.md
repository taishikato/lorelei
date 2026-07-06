# Plan 001: Add a GitHub Actions CI workflow that builds and tests every PR

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 120103a..HEAD -- .github/ README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `120103a`, 2026-07-06

## Why this matters

The repo is public with a v1.0 binary release and a 157-test suite, but nothing
runs that suite automatically - the only gate is the owner remembering to run
it locally. External contributors (the repo just went public) can open PRs with
zero build/test signal. The verification command already exists and is
documented in the README; this plan only wires it into GitHub Actions. Every
other plan in this directory uses CI as its final verification gate, which is
why this one goes first.

## Current state

- No `.github/` directory exists at the repo root (`ls .github` fails).
- The project is a single Xcode project: `Lorelei.xcodeproj`, scheme `Lorelei`,
  **deployment target macOS 26.0**, built with **Xcode 26.x** (the pbxproj says
  `LastUpgradeCheck = 2620`, i.e. Xcode 26.2). Tests are Swift Testing
  (`@Test`) in the `LoreleiTests` target. The app target's Debug config signs
  with a personal development certificate that CI will NOT have - CI must
  disable code signing.
- One SPM dependency (posthog-ios) resolved in
  `Lorelei.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
  xcodebuild resolves it automatically (needs network).
- The suite's local invocation (from README.md:100-102 plus the timeout flags
  the owner always uses):

  ```
  xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei \
    -destination 'platform=macOS' \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 60
  ```

- Known suite characteristic: some tests use generous 1.5-2.0s timers by
  deliberate convention to survive parallel-suite load. On a slow CI runner a
  timing test may still occasionally flake; a retry step is acceptable, test
  edits are NOT (out of scope).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Validate YAML locally | `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` | exit 0, no output |
| Local test run (sanity, optional) | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath DerivedData test -test-timeouts-enabled YES -default-test-execution-time-allowance 60` | `** TEST SUCCEEDED **` |
| Trigger CI | push the branch, open a PR (see Git workflow) | workflow run appears |
| Watch CI | `gh run watch --exit-status` (or `gh pr checks`) | conclusion: success |

## Scope

**In scope** (the only files you should create/modify):
- `.github/workflows/ci.yml` (create)
- `README.md` - one line only: a CI status badge at the top (optional step 4)

**Out of scope** (do NOT touch):
- Any Swift source or test file. If CI reveals a flaky test, report it; do not
  edit tests.
- `scripts/release.sh` (release pipeline is manual and local by design - it
  needs the owner's signing identity and notary profile).
- Signing configuration in `Lorelei.xcodeproj/project.pbxproj`.

## Git workflow

- Branch: `ci-workflow` (repo convention: short kebab-case feature branches,
  e.g. `mic-input-select`, `settings-window`).
- Commit style: lowercase conventional prefix, e.g. `chore: add CI workflow
  building and testing every PR` (see `git log --oneline` for examples).
- Pushing the branch and opening a PR **is required** to verify this plan (CI
  only runs on GitHub). This is pre-authorized for this plan. Do NOT merge the
  PR; leave it for the owner.

## Steps

### Step 1: Create the workflow file

Create `.github/workflows/ci.yml` with exactly this shape (adjust only if a
STOP condition forces it):

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: macos-26
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode 26
        run: |
          ls /Applications | grep -i xcode || true
          sudo xcode-select -s "$(ls -d /Applications/Xcode_26*.app | sort -V | tail -1)/Contents/Developer"
          xcodebuild -version

      - name: Run tests
        run: |
          xcodebuild test \
            -project Lorelei.xcodeproj \
            -scheme Lorelei \
            -destination 'platform=macOS' \
            -derivedDataPath DerivedData \
            -test-timeouts-enabled YES \
            -default-test-execution-time-allowance 60 \
            CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO
```

Notes that are load-bearing:
- `CODE_SIGNING_ALLOWED=NO` etc. as **build settings** (positional, after the
  flags) - the runner has no signing certificate.
- `runs-on: macos-26` - the app's deployment target is macOS 26, so the runner
  OS must be macOS 26. If GitHub's runner label differs (e.g. only
  `macos-latest` maps to 26), adjust the label, but verify with step 3 that the
  selected image really runs macOS 26 (`sw_vers` in a debug step if needed).

**Verify**: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` → exit 0.

### Step 2: Commit, push, open a draft PR

`git add .github/workflows/ci.yml`, commit, push the `ci-workflow` branch, then
`gh pr create --draft --title "chore: CI workflow" --body "Adds build+test on PRs. Part of plans/001."`

**Verify**: `gh pr checks --watch` (or `gh run watch --exit-status`) → the
`test` job concludes **success** with `** TEST SUCCEEDED **` in its log
(`gh run view --log | grep "TEST SUCCEEDED"`).

### Step 3: Handle a first-run failure (one bounded retry)

If the job fails on **Xcode selection** (no `/Applications/Xcode_26*` on the
image) or on **runner label** (no `macos-26` runner), apply the matching fix
once: try runner label `macos-latest` and re-check `sw_vers` + available
Xcodes in the log. If the failure is instead a **test failure**, re-run the job
once (`gh run rerun <id>`); a second identical test failure is a STOP
condition (report the failing test name and log excerpt).

**Verify**: same as step 2 - green run.

### Step 4 (optional, do last): Add the badge

Add to the top of `README.md`, directly under the `# Lorelei` heading:

```markdown
![CI](https://github.com/taishikato/lorelei/actions/workflows/ci.yml/badge.svg)
```

**Verify**: `grep -n "workflows/ci.yml/badge.svg" README.md` → one match.

## Test plan

No new Swift tests - this plan's product IS the test runner. Verification is a
green workflow run on the PR (step 2/3).

## Done criteria

- [ ] `.github/workflows/ci.yml` exists and parses as YAML
- [ ] A PR run of the `test` job concluded success, log contains `** TEST SUCCEEDED **`
- [ ] No Swift source/test files modified (`git status` shows only the workflow file and optionally README.md)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- No hosted runner image provides macOS 26 with an Xcode 26.x install (check
  the job log's `ls /Applications`). Report the available images/Xcodes -
  the fallback decision (self-hosted runner vs building against a lower SDK)
  belongs to the owner.
- The same test fails twice in CI while passing locally - that's a real
  environment-sensitivity finding; name the test, don't patch it.
- Package resolution for posthog-ios fails in CI after one retry.

## Maintenance notes

- When the owner upgrades Xcode/macOS, the `Xcode_26*` glob and runner label
  need revisiting.
- Future plans (002-008) all use "CI green" as a done criterion once this
  lands.
- Deferred deliberately: lint job (no lint config exists yet - audit finding
  DX-03), release automation (manual by design), test-result artifacts.
