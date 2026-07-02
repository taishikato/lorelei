# Phase 1: Merge PR #1, Rename to Lorelei, Cleanup - Implementation Plan

> **For agentic workers:** This plan is executed by Codex (gpt-5.5) task-by-task, reviewed by the planner between tasks. Steps use checkbox (`- [ ]`) syntax for tracking. Work on a branch created from `main` after Task 1.

**Goal:** Land PR #1, then rename every trace of `leanring-buddy` to `Lorelei`, delete clicky-era analytics and the OpenAI cloud STT provider, and raise the deployment target to macOS 26.

**Architecture:** No behavior changes in this phase. It is mechanical renaming and deletion, verified by the existing test suite plus zero-match greps. This phase locks in the project identity before new subsystems are added.

**Tech Stack:** Xcode 26, Swift/SwiftUI, XCTest, `xcodebuild`, `git`, `gh`.

## Global Constraints

- Bundle ID stays exactly `dev.taishi.lorelei` (already correct; changing it would reset TCC permissions).
- `PRODUCT_NAME` stays exactly `Lorelei`.
- `MACOSX_DEPLOYMENT_TARGET` becomes exactly `26.0` (Task 5).
- `THIRD_PARTY_NOTICES.md` is NOT edited: it is the license attribution for the original clicky code.
- Commit messages in English.
- Every task ends with a successful build and test run before its commit.
- Build command (used throughout):
  `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' build`
- Test command (used throughout):
  `xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -skip-testing:LoreleiUITests`
  (UI tests are launch smoke tests; run them once in Task 6.)

---

### Task 1: Merge PR #1 into main

**Files:** none (git operation only).

**Interfaces:**
- Consumes: PR #1 (`codex/computer-use-lorelei`), verified MERGEABLE/CLEAN; `main` is an ancestor of the branch.
- Produces: `main` containing the App Server integration that later phases build on.

**GATE: get explicit user confirmation before merging - this is an irreversible remote action.**

- [ ] **Step 1: Confirm state and merge**

```bash
gh pr view 1 --json mergeable,mergeStateStatus
gh pr merge 1 --merge --subject "Merge PR #1: Codex App Server computer use integration"
```

Expected: merge succeeds (branch is CLEAN and up to date with main).

- [ ] **Step 2: Update local main and create the phase branch**

```bash
git checkout main && git pull
git checkout -b phase-1-rename-cleanup
```

- [ ] **Step 3: Baseline build and test on the merged tree**

```bash
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS' build
xcodebuild test -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS' -skip-testing:leanring-buddyUITests
```

Expected: BUILD SUCCEEDED and TEST SUCCEEDED.
If the baseline fails, STOP and report - do not start renaming on a broken tree.

---

### Task 2: Rename project scaffolding to Lorelei

**Files:**
- Rename: `leanring-buddy/` → `Lorelei/`, `leanring-buddyTests/` → `LoreleiTests/`, `leanring-buddyUITests/` → `LoreleiUITests/`, `leanring-buddy.xcodeproj/` → `Lorelei.xcodeproj/`
- Rename: `Lorelei/leanring_buddyApp.swift` → `Lorelei/LoreleiApp.swift`, `Lorelei/leanring-buddy.entitlements` → `Lorelei/Lorelei.entitlements`
- Rename: scheme `leanring-buddy.xcscheme` → `Lorelei.xcscheme`, test files `leanring_buddyTests.swift` → `LoreleiTests.swift`, `leanring_buddyUITests.swift` → `LoreleiUITests.swift`, `leanring_buddyUITestsLaunchTests.swift` → `LoreleiUITestsLaunchTests.swift`
- Modify: every file containing the strings `leanring-buddy`, `leanring_buddy`, or `leanring_buddyApp` (pbxproj, xcscheme, Swift sources)

**Interfaces:**
- Consumes: merged tree from Task 1.
- Produces: targets/scheme named `Lorelei`, `LoreleiTests`, `LoreleiUITests`; `@main struct LoreleiApp`; module name stays `Lorelei` (already is - `@testable import Lorelei` must keep compiling).

- [ ] **Step 1: git mv directories and files**

```bash
git mv leanring-buddy Lorelei
git mv leanring-buddyTests LoreleiTests
git mv leanring-buddyUITests LoreleiUITests
git mv leanring-buddy.xcodeproj Lorelei.xcodeproj
git mv Lorelei.xcodeproj/xcshareddata/xcschemes/leanring-buddy.xcscheme Lorelei.xcodeproj/xcshareddata/xcschemes/Lorelei.xcscheme
git mv Lorelei/leanring_buddyApp.swift Lorelei/LoreleiApp.swift
git mv Lorelei/leanring-buddy.entitlements Lorelei/Lorelei.entitlements
git mv LoreleiTests/leanring_buddyTests.swift LoreleiTests/LoreleiTests.swift
git mv LoreleiUITests/leanring_buddyUITests.swift LoreleiUITests/LoreleiUITests.swift
git mv LoreleiUITests/leanring_buddyUITestsLaunchTests.swift LoreleiUITests/LoreleiUITestsLaunchTests.swift
```

- [ ] **Step 2: Rewrite name strings in file contents**

Order matters: the `leanring_buddyApp` replacement must run before the generic `leanring_buddy` one.

```bash
LC_ALL=C grep -rl 'leanring' Lorelei Lorelei.xcodeproj LoreleiTests LoreleiUITests \
  | xargs sed -i '' -e 's/leanring_buddyApp/LoreleiApp/g' -e 's/leanring-buddy/Lorelei/g' -e 's/leanring_buddy/Lorelei/g'
```

This renames, among others: the pbxproj target/product references (`leanring-buddyTests` → `LoreleiTests` via the prefix match), the scheme's BuildableName/BlueprintName, `struct leanring_buddyApp` → `struct LoreleiApp`, and the UI test classes `leanring_buddyUITests` → `LoreleiUITests`, `leanring_buddyUITestsLaunchTests` → `LoreleiUITestsLaunchTests`.

- [ ] **Step 3: Verify zero leftovers and unchanged identity**

```bash
grep -ri 'leanring' Lorelei Lorelei.xcodeproj LoreleiTests LoreleiUITests; echo "exit=$?"
grep -c 'PRODUCT_BUNDLE_IDENTIFIER = dev.taishi.lorelei;' Lorelei.xcodeproj/project.pbxproj
```

Expected: first grep prints nothing with `exit=1`; second prints `2` (Debug + Release of the app target).

- [ ] **Step 4: Build and test with the new names**

```bash
xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' build
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -skip-testing:LoreleiUITests
```

Expected: BUILD SUCCEEDED, TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename leanring-buddy project to Lorelei"
```

---

### Task 3: Delete ClickyAnalytics

**Files:**
- Delete: `Lorelei/ClickyAnalytics.swift`
- Modify: every remaining call site (post-merge, locate with the grep below; pre-merge these are `CompanionManager.swift`, `MenuBarPanelManager.swift`, `CompanionPanelView.swift`, `LoreleiApp.swift`, `BuddyTranscriptionProvider.swift`)

**Interfaces:**
- Consumes: renamed tree from Task 2.
- Produces: no analytics symbol anywhere; no replacement API (call sites are deleted, not stubbed).

- [ ] **Step 1: List call sites**

```bash
grep -rn 'ClickyAnalytics' Lorelei LoreleiTests LoreleiUITests
```

- [ ] **Step 2: Delete the file and every call site**

```bash
git rm Lorelei/ClickyAnalytics.swift
```

Then edit each file from Step 1: remove the whole statement that mentions `ClickyAnalytics` (these are fire-and-forget tracking calls; no return values are consumed).
If a removal leaves a now-empty helper function or an unused import, remove that too.

- [ ] **Step 3: Verify zero references, build, test**

```bash
grep -rn 'ClickyAnalytics' Lorelei LoreleiTests LoreleiUITests; echo "exit=$?"
xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' build
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -skip-testing:LoreleiUITests
```

Expected: `exit=1`, BUILD SUCCEEDED, TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove clicky-era analytics"
```

---

### Task 4: Delete the OpenAI cloud transcription provider

**Files:**
- Delete: `Lorelei/OpenAIAudioTranscriptionProvider.swift`
- Modify: `Lorelei/BuddyTranscriptionProvider.swift` (provider selection / API-key plumbing), plus any settings UI or store fields that exist only for the OpenAI key (locate with the grep below)

**Interfaces:**
- Consumes: tree from Task 3.
- Produces: `BuddyTranscriptionProvider` protocol unchanged as the STT seam; Apple provider becomes the only implementation (still the old SFSpeechRecognizer one - the DictationTranscriber migration is Phase 6, NOT this task).

- [ ] **Step 1: List all wiring**

```bash
grep -rni 'openai' Lorelei LoreleiTests | grep -vi 'codex'
```

(The `codex` exclusion keeps App Server code out of scope; only transcription wiring may be touched.)

- [ ] **Step 2: Delete provider and wiring**

```bash
git rm Lorelei/OpenAIAudioTranscriptionProvider.swift
```

Then remove from the files found in Step 1: the OpenAI branch of provider selection, API-key storage fields and any settings UI rows for it, and OpenAI-specific tests.
Do NOT remove the `BuddyTranscriptionProvider` protocol or the Apple provider.

- [ ] **Step 3: Verify, build, test**

```bash
grep -rni 'openai' Lorelei LoreleiTests | grep -vi 'codex'; echo "exit=$?"
xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' build
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -skip-testing:LoreleiUITests
```

Expected: `exit=1`, BUILD SUCCEEDED, TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove OpenAI cloud transcription provider"
```

---

### Task 5: Raise deployment target to macOS 26

**Files:**
- Modify: `Lorelei.xcodeproj/project.pbxproj` (all `MACOSX_DEPLOYMENT_TARGET` entries)

**Interfaces:**
- Consumes: tree from Task 4.
- Produces: `MACOSX_DEPLOYMENT_TARGET = 26.0` on every configuration, unlocking liquid glass and SpeechAnalyzer APIs for later phases.

- [ ] **Step 1: Rewrite the setting**

```bash
sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 14.2;/MACOSX_DEPLOYMENT_TARGET = 26.0;/g' Lorelei.xcodeproj/project.pbxproj
grep -c 'MACOSX_DEPLOYMENT_TARGET = 26.0;' Lorelei.xcodeproj/project.pbxproj
```

Expected: count equals the number previously on 14.2 (6 pre-merge; re-check post-merge) and `grep -c 'MACOSX_DEPLOYMENT_TARGET = 14.2;'` returns 0.

- [ ] **Step 2: Build and test**

```bash
xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' build
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -skip-testing:LoreleiUITests
```

Expected: BUILD SUCCEEDED, TEST SUCCEEDED.
Raising the floor cannot remove APIs; if new deprecation warnings appear, list them in the task report but do not fix them here.

- [ ] **Step 3: Commit**

```bash
git add Lorelei.xcodeproj/project.pbxproj
git commit -m "chore: raise deployment target to macOS 26"
```

---

### Task 6: Sweep leftover legacy naming and open the PR

**Files:**
- Modify: any Swift file whose comments or user-facing strings still say `clicky`, `makesomething`, or `learning buddy` (pre-merge known: `GlobalPushToTalkShortcutMonitor.swift`, `BuddyDictationManager.swift`; re-check post-merge)

**Interfaces:**
- Consumes: tree from Task 5.
- Produces: source tree whose only clicky mention is `THIRD_PARTY_NOTICES.md`; Phase 1 PR ready for review.

- [ ] **Step 1: Find and fix leftovers**

```bash
grep -rni 'clicky\|makesomething\|learning buddy' Lorelei LoreleiTests LoreleiUITests
```

Rewrite each hit to refer to Lorelei (comments) or delete the sentence if it described clicky-specific behavior that no longer exists.
`THIRD_PARTY_NOTICES.md` stays untouched.

- [ ] **Step 2: Full verification including UI tests**

```bash
grep -rni 'clicky\|makesomething\|learning buddy\|leanring' Lorelei LoreleiTests LoreleiUITests Lorelei.xcodeproj; echo "exit=$?"
xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' build
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS'
```

Expected: `exit=1`, BUILD SUCCEEDED, TEST SUCCEEDED (UI launch tests included this time).

- [ ] **Step 3: Commit and open the PR**

```bash
git add -A
git commit -m "chore: sweep remaining clicky-era naming"
git push -u origin phase-1-rename-cleanup
gh pr create --title "Phase 1: rename to Lorelei and remove legacy code" --body "Implements phase 1 of docs/superpowers/specs/2026-07-02-lorelei-buddy-redesign.md: merge follow-up rename, ClickyAnalytics removal, OpenAI STT removal, macOS 26 deployment target. No behavior changes."
```

Expected: PR URL printed. The planner reviews before merge.
