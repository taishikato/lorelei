# Plan 005: Track the codex app-server schema snapshot in git

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 120103a..HEAD -- .gitignore scripts/update-appserver-schema.sh`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live files before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dependencies
- **Planned at**: commit `120103a`, 2026-07-06

## Why this matters

`Lorelei/CodexAppServerProtocol.swift` (772 lines) hand-tracks the JSON-RPC
schema of the installed codex CLI. The repo has a script whose documented
purpose is "re-run after every codex upgrade and review the diff against the
Swift protocol layer" - but the snapshot it writes lives under `docs/`, which
is blanket-ignored, so there is no committed baseline to diff against and
public contributors cannot see what CLI version the protocol layer is pinned
to. Tracking just the schema directory (while keeping the rest of `docs/`
local-only, which is a deliberate owner decision) restores the script's
purpose and gives protocol changes reviewable diffs.

## Current state

- `.gitignore` (entire file, 6 lines):

```
.worktrees/
.DS_Store
xcuserdata/
DerivedData/
dist/
docs/
```

- `scripts/update-appserver-schema.sh` (entire file):

```bash
#!/usr/bin/env bash
# Snapshot the app-server protocol schema for the installed codex CLI.
# Re-run after every codex upgrade and review the diff against the Swift
# protocol layer (CodexAppServerProtocol.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/appserver-schema
codex app-server generate-json-schema --out docs/appserver-schema
codex --version > docs/appserver-schema/CODEX_VERSION
```

- `docs/appserver-schema/` exists locally with ~40 JSON schema files plus
  `CODEX_VERSION` (contents: `codex-cli 0.142.4`). All currently untracked.
- Git ignore semantics that matter here: a pattern that ignores a DIRECTORY
  (`docs/`) cannot have children re-included with `!` - git never descends
  into an ignored directory. The fix is to ignore the directory's CHILDREN
  (`docs/*`) and then negate the one child to keep (`!docs/appserver-schema/`).
- The rest of `docs/` (superpowers/, battle-test-log.md, release.md, memos)
  must STAY untracked - that is a recorded owner decision.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Ignore check (kept local) | `git check-ignore -v docs/battle-test-log.md` | prints a match (still ignored) |
| Ignore check (now tracked) | `git check-ignore docs/appserver-schema/CODEX_VERSION` | exit 1, no output (NOT ignored) |
| Status | `git status --short docs/` | only `docs/appserver-schema/` entries appear |

## Scope

**In scope**:
- `.gitignore` (edit)
- `docs/appserver-schema/**` (add to git as-is - do NOT regenerate; the
  committed baseline must match what `CodexAppServerProtocol.swift` was
  written against, i.e. the current local snapshot at codex-cli 0.142.4)

**Out of scope** (do NOT touch):
- Everything else under `docs/` - must remain untracked.
- `scripts/update-appserver-schema.sh` - already writes to the right place.
- `README.md` (plan 002 optionally links the schema dir; not this plan).

## Git workflow

- Branch: `track-appserver-schema`
- Commit style: `chore: track the codex app-server schema snapshot`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Rewrite the docs ignore rule

In `.gitignore`, replace the line `docs/` with:

```
docs/*
!docs/appserver-schema/
```

(Keep the other five lines untouched. Order matters: the negation must come
after `docs/*`.)

**Verify**:
- `git check-ignore docs/appserver-schema/CODEX_VERSION` → exit 1 (not ignored)
- `git check-ignore -v docs/battle-test-log.md` → prints the `docs/*` rule
- `git check-ignore -v docs/superpowers/specs/2026-07-02-lorelei-buddy-redesign.md` → prints the `docs/*` rule

### Step 2: Stage and commit the snapshot

`git add .gitignore docs/appserver-schema` then check what is staged BEFORE
committing:

**Verify**: `git diff --cached --stat` lists ONLY `.gitignore` and files under
`docs/appserver-schema/` (expect ~40 JSON files + `CODEX_VERSION`; if anything
else from `docs/` appears, STOP). Then commit.

### Step 3: Confirm the worktree is clean of surprises

**Verify**: `git status --short` → no unexpected `docs/` entries beyond
(nothing - everything else stays untracked and now silent under `docs/*`).
`cat docs/appserver-schema/CODEX_VERSION` → `codex-cli 0.142.4` (the version
the protocol layer currently tracks).

## Test plan

No Swift changes - the git checks above are the tests. If plan 001's CI is
merged, the PR must still be green (no code touched).

## Done criteria

- [ ] `git check-ignore docs/appserver-schema/CODEX_VERSION` exits 1
- [ ] `git check-ignore docs/battle-test-log.md` exits 0 (still ignored)
- [ ] `git ls-files docs/ | grep -v '^docs/appserver-schema/'` → empty output
- [ ] Committed files: `.gitignore` + `docs/appserver-schema/**` only
- [ ] `plans/README.md` status row updated

## STOP conditions

- `docs/appserver-schema/` does not exist locally or `CODEX_VERSION` does not
  read `codex-cli 0.142.4` - the local snapshot may have been regenerated
  against a newer CLI than the Swift layer tracks. Report the version instead
  of committing a mismatched baseline.
- Staging pulls in any path under `docs/` outside `appserver-schema/`.

## Maintenance notes

- After every `codex` CLI upgrade: run `./scripts/update-appserver-schema.sh`,
  review `git diff docs/appserver-schema/` against
  `Lorelei/CodexAppServerProtocol.swift`, and commit the new snapshot together
  with any protocol-layer changes - that pairing is the whole point.
- Plan 002 (README refresh) may add a line pointing contributors at this
  directory once this plan is DONE.
