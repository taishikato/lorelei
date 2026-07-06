# Plan 002: Bring README.md in line with the shipped v1.0 reality

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 120103a..HEAD -- README.md Lorelei/LoreleiAnalytics.swift Lorelei/LoreleiToolbarView.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (one optional line depends on plan 005 - see step 4)
- **Category**: docs
- **Planned at**: commit `120103a`, 2026-07-06

## Why this matters

The repo just went public with a v1.0 notarized DMG release, and the README is
wrong at exactly the four places a new visitor hits first: it says no packaged
release exists (one does), it tells users to find a menu bar icon that was
removed, its "Docs live in the repo" links 404 (the `docs/` tree is untracked),
and the Privacy section does not disclose the PostHog telemetry that Release
builds send. The last one is a trust liability for a product whose headline is
"audio never leaves your Mac".

## Current state

`README.md` (root; last touched in commit `120103a` "Update README.md"). The
four wrong claims, verbatim:

1. Line 32: `There is no packaged release yet; you build from source.`
   - Reality: https://github.com/taishikato/lorelei/releases/tag/v1.0 has
     `Lorelei-1.0.dmg` (signed, notarized, stapled; Gatekeeper-clean).
2. Line 51: `The setup panel (menu bar icon) shows a Grant button for each, ...`
   - Reality: there is NO menu bar icon. Settings open from a **gear button in
     the expanded floating toolbar** - `Lorelei/LoreleiToolbarView.swift:164-165`
     has the `gearshape` button labeled "Settings"; it opens a standard macOS
     window titled "Lorelei Settings" (`Lorelei/SettingsWindowController.swift`).
     The settings window also auto-opens on launch while permissions are
     missing (`Lorelei/LoreleiApp.swift:81-83`).
3. Lines 94-95: links to `docs/superpowers/specs/2026-07-02-lorelei-buddy-redesign.md`
   and `docs/superpowers/plans/` - `git ls-files docs/` is empty (`.gitignore`
   line 6 ignores `docs/`), so these are dead links for anyone on GitHub. The
   PRD link to issue #2 (line 96) works and stays.
4. Lines 118-121 (Privacy): mentions only on-device audio and the
   Codex/OpenAI data path. Reality: `Lorelei/LoreleiAnalytics.swift` sends
   product analytics to PostHog (`https://us.i.posthog.com`) in **Release
   builds only** (`isEnabled` is false in DEBUG and when the key is empty).
   What is sent (verified across every capture call site): event names
   (`app_launched`, `dictation_completed`, `turn_started`, `turn_completed`,
   `steer_sent`, `steer_failed`, `run_stopped`, `approval_requested`,
   `approval_resolved`, `settings_panel_opened`, `toolbar_expanded`,
   `new_chat_started`) with coarse metadata only - transcript character
   COUNTS, sandbox policy names, success booleans, durations. Never
   transcripts, conversation text, or file paths (that contract is stated at
   `LoreleiAnalytics.swift:6-11` and enforced by a unit test). There is no
   opt-out toggle (deliberate owner decision).

Style conventions for this repo's prose: plain dash `-` (never em dash),
sentence-per-line is NOT used in the existing README (keep its current
paragraph style), tone is direct and concrete.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Link check (manual) | `grep -n "docs/superpowers" README.md` | no matches after step 3 |
| Stale-claim check | `grep -n "menu bar icon\|no packaged release" README.md` | no matches after steps 1-2 |
| Disclosure check | `grep -n "PostHog" README.md` | at least one match after step 4 |

## Scope

**In scope**:
- `README.md`

**Out of scope** (do NOT touch):
- Any Swift file (two source comments still say "menu bar panel" -
  `Lorelei/CompanionDebugLog.swift:5`, `Lorelei/WorkspaceSettingsStore.swift:5` -
  leave them; code comments are not this plan).
- `.gitignore` / anything under `docs/` (plan 005 handles the schema snapshot).
- `LoreleiAnalytics.swift` (disclosure changes the README, not the code).

## Git workflow

- Branch: `readme-refresh`
- Commit style: `docs: bring README in line with the v1.0 release`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the "no packaged release" install section

In "## Install and run": lead with a **Download** subsection - link
`https://github.com/taishikato/lorelei/releases/latest`, state the DMG is
signed and notarized (no Gatekeeper warning), install = drag to Applications.
Keep the existing clone/Xcode instructions under a "Build from source"
subsection (content unchanged). Requirements table stays.

**Verify**: `grep -n "no packaged release" README.md` → no matches; `grep -n "releases/latest" README.md` → 1 match.

### Step 2: Fix the first-run setup description

Rewrite the sentence at line ~51: permissions are granted from the **settings
window**, which opens automatically on first launch while permissions are
missing, and any time via the **gear button in the expanded toolbar** (click
the floating face at the top of the screen to expand it). Keep the
four-permission list and the workspace-folder paragraph as they are.

**Verify**: `grep -n "menu bar icon" README.md` → no matches; `grep -in "gear" README.md` → at least 1 match.

### Step 3: Fix the Development doc links

Remove the two `docs/superpowers/...` bullet lines. Keep the PRD bullet
(issue #2). Add one line pointing contributors at `plans/` for current
improvement plans. Keep the test-command block, but add the timeout flags the
suite is actually run with so contributors reproduce CI:
`-test-timeouts-enabled YES -default-test-execution-time-allowance 60`.

**Verify**: `grep -n "docs/superpowers" README.md` → no matches.

### Step 4: Disclose analytics in Privacy

Add a third bullet to "## Privacy" (keep the existing two), factually scoped
to the "Current state" facts above: Release builds send anonymous usage
analytics to PostHog (US cloud); events carry coarse metadata only - counts,
durations, statuses - never transcripts, screen content, or file paths; DEBUG
builds send nothing. Do not overpromise (there is no opt-out - do not claim
one; it is acceptable to state "no opt-out UI yet").

Optional (only if plan 005 is already DONE in `plans/README.md`): in the
Development section, mention `docs/appserver-schema/` as the tracked protocol
snapshot regenerated by `./scripts/update-appserver-schema.sh`.

**Verify**: `grep -n "PostHog" README.md` → ≥1 match in the Privacy section.

### Step 5: Full read-through

Read the final README top to bottom once; confirm no other sentence
contradicts the app you can see in the code (screenshots/claims about UI
elements must match `LoreleiToolbarView.swift` / `SettingsWindowController.swift`).
No em dashes introduced.

**Verify**: `grep -n "—" README.md` → no NEW matches versus `git show 120103a:README.md | grep -c "—"` (count must not increase).

## Test plan

Docs-only; the greps in each step are the tests. If plan 001 is merged, CI
will still run on the PR - it must stay green (README changes cannot break it).

## Done criteria

- [ ] All five step verifications pass
- [ ] `git diff --stat` touches only `README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- README.md has been substantially rewritten since `120103a` (drift check) -
  re-audit which of the four claims still exist before editing; if none do,
  mark this plan DONE-by-drift in the index and stop.
- You cannot verify a factual claim you are about to write (e.g. the release
  URL 404s). Report instead of guessing.

## Maintenance notes

- The Privacy bullet must be updated if analytics events ever gain new
  properties - reviewers of future `LoreleiAnalytics` changes should check the
  README stays truthful (the unit test `dictationEventCarriesOnlyMetadataNeverContent`
  in `LoreleiTests/LoreleiAnalyticsTests.swift` guards the code side).
- If an update checker ships (plan 007), the Download section gains a "the app
  checks for updates" line.
