# Phase 4-B: CI/CD and Release Pipeline Review

**Branch:** `feat/add-editing-support`  
**Diff base:** `7fc5aa2` (Release 0.0.28 — viewer-only)  
**Files reviewed:** `.github/workflows/swift-tests.yml`, `scripts/release.sh`, `scripts/rollback-release.sh`, `CLAUDE.md` (release pipeline section), `AGENTS.md` (known issues + release guide), `md-preview.entitlements`, `Info.plist`  
**Prior phase critical findings cross-referenced:** C-1 (autosave race), C-2 (per-keystroke regex compile), Phase 1b C1 (data loss on editor toggle), Phase 1b H1 (dual source of truth)

---

## Executive Summary

The editing feature is not gated by any automated test or build check in CI. The GitHub Actions workflow compiles and tests only a small SPM helper package; none of the 482 new lines of AppKit editing code is compiled or exercised in CI. Three prior-phase critical defects (data loss, autosave/FileWatcher race, false external-change alert) will ship if this branch is released today — nothing in the pipeline prevents it. The entitlement escalation (read-only → read-write) is legitimate for a Developer ID app but must be documented in the release checklist to avoid notarization surprises. A pre-existing `SUFeedURL` mismatch in AGENTS.md's Known Issues blocks Sparkle auto-update, which also breaks the primary rollback path for already-installed users. Together these represent a high deployment risk for the first editor release.

---

## Finding 1 — No build or test coverage for 482 lines of new editing code

**Severity:** Critical  
**Operational Risk:** A Swift compilation error in any of the five changed/new files (`EditorViewController.swift`, `MarkdownSyntaxHighlighter.swift`, `DocumentWindowController.swift`, `MainSplitViewController.swift`, `MarkdownDocument.swift`) would not be caught in CI. A runtime regression in the editing feature — data loss, crash, wrong document state — would reach users with no automated backstop.

**Detail:**  
The CI workflow (`swift-tests.yml`) runs exactly one step:

```yaml
- name: Run tests
  run: swift test --package-path tests/swift-tests
```

The SPM package at `tests/swift-tests` contains three symlinked source files:

```
Sources/MarkdownHelpers/CodeFenceInfo.swift        → md-preview/CodeFenceInfo.swift
Sources/MarkdownHelpers/EscapingHTMLFormatter.swift → md-preview/EscapingHTMLFormatter.swift
Sources/MarkdownHelpers/MarkdownFrontmatter.swift   → md-preview/MarkdownFrontmatter.swift
```

None of `EditorViewController.swift`, `MarkdownSyntaxHighlighter.swift`, the 98-line addition to `DocumentWindowController.swift`, the 55-line addition to `MainSplitViewController.swift`, or the 27-line edit to `MarkdownDocument.swift` appear in the test package. The Xcode project is never built by CI — there is no `xcodebuild build` or `xcodebuild test` step. If the Xcode project fails to compile, the CI run still passes (green) because the SPM package compiles independently.

**Specific Improvement:**

1. Add a build-only step before the test step to compile the Xcode scheme and catch Swift errors in the full app target:

```yaml
- name: Build Xcode project
  run: |
    xcodebuild build \
      -project md-preview.xcodeproj \
      -scheme md-preview \
      -configuration Debug \
      -destination 'platform=macOS' \
      | xcpretty --simple || true
```

2. Add a symlink for `MarkdownSyntaxHighlighter.swift` into `tests/swift-tests/Sources/MarkdownHelpers/` — the highlighting engine contains pure string/range logic that has no AppKit dependencies (the `fenceOpenRegex`, `intersectsProtected`, `applyPattern`, and fence scanning methods all operate on `NSString`/`NSRange`). These can be unit-tested immediately via SPM without mocking any UI layer:

```bash
ln -s ../../../../md-preview/MarkdownSyntaxHighlighter.swift \
      tests/swift-tests/Sources/MarkdownHelpers/MarkdownSyntaxHighlighter.swift
```

3. Add a new `MarkdownSyntaxHighlighterTests.swift` covering:
   - Heading, bold, italic, link, and inline-code pattern detection
   - Code fence open/close matching
   - `intersectsProtected` boundary cases (range at start of fence, range spanning fence boundary, empty protected list)
   - Fence allocation count for documents with many fences (regression guard for the allocation storm)

---

## Finding 2 — Critical bugs from prior phases are unblocked for release

**Severity:** Critical  
**Operational Risk:** Three confirmed data-loss or UX-breaking defects identified in Phases 1-A and 1-B will ship if the branch is released as-is. The release pipeline has no mechanism to block a release with open critical findings.

**Detail:**  
The following findings from the prior review phases are unresolved and untested:

| Finding | Description | Consequence if shipped |
|---|---|---|
| Phase 1-A C-1 / Phase 1-B M3 | Autosave triggers `FileWatcher` → false "File Modified Externally" alert | User sees a false modal on their own save; alarm fatigue; user may click "Reload from Disk" and lose their unsaved edits |
| Phase 1-B C1 | `toggleEditorAction` overwrites editor text with `currentMarkdown` on every panel open, within the 200 ms debounce window | Silent data loss of in-progress keystrokes when the user closes and re-opens the editor panel |
| Phase 1-A C-2 / Phase 1-B H3 | 8 `NSRegularExpression` patterns compiled from constant literals on every keystroke | 1.2–3.6 ms of unnecessary main-thread work per keystroke; scales with document size |

The `release.sh` preflight only checks:

1. Working tree is clean  
2. `CHANGELOG.md` entry exists for the version  
3. `amore` is logged in  
4. `gh` CLI is authenticated  

There is no known-issue check, no test gate, and no human sign-off step in the script itself (CLAUDE.md documents a "release branch + PR" pattern, but that is a social convention, not an enforced gate).

**Specific Improvement:**

Add an explicit release blocklist check to `release.sh`. Before the `amore release` call, add:

```bash
# ── Check for open critical issues ────────────────────────────────────────
BLOCKLIST="$PROJECT_ROOT/.release-blocklist"
if [[ -f "$BLOCKLIST" ]]; then
    echo "  ✗ open release blockers found in .release-blocklist:"
    cat "$BLOCKLIST"
    echo "    Resolve or use --force to override"
    exit 1
fi
```

Create `.release-blocklist` on this branch with the current open criticals. The file is deleted (or items removed) only when the defect is fixed and verified. This makes the pipeline state machine explicit: a critical finding is a tangible artifact that must be removed before the release command succeeds.

As a parallel action, the three critical findings above must be fixed before this branch merges. The data-loss defect (C1 / `toggleEditorAction` overwrite) is the highest-priority ship blocker.

---

## Finding 3 — Entitlement escalation requires explicit release checklist entry and may surprise notarization

**Severity:** High  
**Operational Risk:** The change from `com.apple.security.files.user-selected.read-only` to `com.apple.security.files.user-selected.read-write` is a sandbox permission escalation. While `amore release` handles notarization automatically, an entitlement mismatch between the `.entitlements` file and the codesigning configuration causes a hard notarization failure. No step in the pipeline validates entitlement consistency before invoking `amore`.

**Detail:**  
The diff:

```diff
- <key>com.apple.security.files.user-selected.read-only</key>
+ <key>com.apple.security.files.user-selected.read-write</key>
```

For a Developer ID app (not App Store), `user-selected.read-write` is a standard entitlement and Apple's notarization scanner will accept it without additional provisioning. However:

1. **Notarization failure risk:** If `amore config` has cached the old codesigning configuration and the entitlement list in the Amore-managed provisioning profile is stale or mismatched, notarization will fail mid-pipeline (after archiving, after signing, during submission). The `amore release` command will exit with an error, but at this point the build is already archived and the release script will leave a partial state (no GitHub release, no appcast update). The release must then be re-run from scratch.

2. **Sparkle/auto-update behavior:** macOS presents a permission-upgrade prompt to users updating from the reader-only version to the editor version via Sparkle. This is a system UI event outside the app's control, but users who dismiss it may have a broken editor (the `NSOpenPanel` will succeed but `NSDocument` writes will fail with `NSCocoaErrorDomain 513` / `.fileWriteNoPermission`). This is not communicated anywhere in the current UI or release notes draft.

3. **No post-notarization entitlement verification step:** `release.sh` has no step that extracts the notarized `.app` from the DMG and verifies `codesign -d --entitlements - app` matches the expected values before uploading and publishing.

**Specific Improvement:**

1. Add a preflight entitlement check to `release.sh`:

```bash
echo "▸ Preflight: entitlement consistency"
ENTITLEMENTS_FILE="$PROJECT_ROOT/md-preview/md-preview.entitlements"
if ! plutil -lint "$ENTITLEMENTS_FILE" >/dev/null 2>&1; then
    echo "  ✗ $ENTITLEMENTS_FILE is not valid plist"
    exit 1
fi
echo "  ✓ entitlements plist is valid"
```

2. Add a post-DMG entitlement verify step after `curl -fsSL -o "$DMG_PATH"`:

```bash
echo "▸ Verifying entitlements in notarized DMG"
MOUNT_POINT="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_PATH"
APP_PATH="$(find "$MOUNT_POINT" -name "*.app" -maxdepth 2 | head -1)"
SIGNED_ENTS="$(codesign -d --entitlements - "$APP_PATH" 2>/dev/null)"
hdiutil detach -quiet "$MOUNT_POINT"
if ! echo "$SIGNED_ENTS" | grep -q "user-selected.read-write"; then
    echo "  ✗ notarized app does not have expected read-write entitlement"
    exit 1
fi
echo "  ✓ entitlement verified in notarized app"
```

3. The CHANGELOG entry for this release MUST mention the permission escalation so users understand why macOS shows a system prompt during update. Add a standard line to the release notes template:

```
- **Storage permission upgrade:** The app now requests write access to user-selected files to support saving edits. macOS will confirm this when you first open a file for editing.
```

---

## Finding 4 — Pre-existing SUFeedURL mismatch blocks Sparkle rollback for already-installed users

**Severity:** High  
**Operational Risk:** AGENTS.md records this as a Known Issue. If this release ships before it is fixed, users who auto-update will permanently configure their Sparkle updater to poll the wrong URL. Rolling back via `rollback-release.sh` (which unpublishes from the Amore appcast) will be invisible to them — their installed copy polls `https://storage.md-preview.app/appcast.xml`, which does not exist. They cannot receive any future update or rollback automatically.

**Detail:**  
From AGENTS.md Known Issues:

> **`SUFeedURL` mismatch.** Info.plist points to `https://storage.md-preview.app/appcast.xml` but Amore actually publishes to `https://storage.md-preview.app/v1/apps/doc.md-preview/appcast.xml`. Fix Info.plist before any non-test release ships to real users — already-installed copies will check the wrong URL forever.

The `rollback-release.sh` script works by:
1. Setting `published=false` on Amore (removes the entry from the real appcast)
2. Deleting the GitHub release and tag

This is effective only for users whose Sparkle is polling the correct appcast URL. Any user who installed from this release with the wrong `SUFeedURL` becomes stranded — rollback does not reach them. They remain on the broken editor version with no auto-recovery path.

This is a pre-existing bug but it is a release blocker for the first version that reaches real users, which this branch would be.

**Specific Improvement:**

Fix `Info.plist` `SUFeedURL` before releasing this branch. The correct value is:

```xml
<key>SUFeedURL</key>
<string>https://storage.md-preview.app/v1/apps/doc.md-preview/appcast.xml</string>
```

Alternatively (and more robustly), configure a CDN redirect at `storage.md-preview.app` so that requests to `/appcast.xml` are permanently redirected (HTTP 301) to `/v1/apps/doc.md-preview/appcast.xml`. This allows already-installed copies with the wrong URL to eventually resolve correctly. Confirm with `amore config show --bundle-id doc.md-preview` that the actual published URL is the `/v1/apps/...` path.

Add this check to `release.sh` preflight:

```bash
FEED_URL="$(plutil -extract SUFeedURL raw "$PROJECT_ROOT/Info.plist")"
EXPECTED_FEED="https://storage.md-preview.app/v1/apps/doc.md-preview/appcast.xml"
if [[ "$FEED_URL" != "$EXPECTED_FEED" ]]; then
    echo "  ✗ SUFeedURL mismatch: $FEED_URL"
    echo "    Expected: $EXPECTED_FEED"
    echo "    Fix Info.plist before releasing to real users"
    exit 1
fi
echo "  ✓ SUFeedURL is correct"
```

---

## Finding 5 — Rollback is server-side only; entitlement downgrade is not reversible for the user

**Severity:** Medium  
**Operational Risk:** `rollback-release.sh` unpublishes the Amore release and deletes the GitHub release+tag. This prevents new users from downloading the bad version. However, users who have already auto-updated to the editor release retain the `read-write` entitlement. Rolling back to the old version reintroduces `read-only`, but the OS does not revoke security-scoped bookmarks the app may have already created with write access. Users who installed the editor version and then receive the rolled-back viewer version will find the app requests fewer permissions — a net improvement in security — but any security-scoped bookmarks stored in `UserDefaults` or the app container that granted write access will become stale and may cause confusing `NSCocoaErrorDomain 513` errors on first launch of the rolled-back version.

**Detail:**  
The rollback script has no awareness of entitlement state. Its operation is:

```bash
# Unpublish on Amore (non-destructive)
"$AMORE" releases update "$VERSION" -b "$BUNDLE_ID" --published false

# Delete GitHub release + tag
gh release delete "$TAG" --yes
git push origin --delete "$TAG"
```

This is correct for controlling distribution. The gap is user-side: Sparkle does not automatically downgrade; it only upgrades to the latest published version. A rolled-back appcast causes Sparkle to find no update available — it does not push users back to the old version. Users who received the bad build must manually reinstall the older DMG from the GitHub release (which has been deleted by rollback). There is no mechanism for forced downgrade in this pipeline.

**Specific Improvement:**

1. Document in AGENTS.md that rollback is distribution-side only and does not push users to an older version. Include the manual recovery path: keep older GitHub releases available (use `--keep-github` or re-tag) so a manual download URL exists. Update rollback guidance:

```bash
# Preferred rollback: unpublish only, keep GitHub release for manual download
./scripts/rollback-release.sh 0.0.N --keep-github

# Then post in release notes / notify users with the old DMG link
```

2. For the entitlement-downgrade edge case specifically: add a release note in the rollback communication that users should go to System Settings → Privacy & Security → Files and Folders → Markdown Preview and revoke write access if they want to restore the viewer-only security posture.

3. Improve the rollback script to optionally upload the previous release's DMG to the new GitHub release as a "rollback installer" asset, so there is always a publicly downloadable DMG even after unpublishing the Amore release.

---

## Finding 6 — CI workflow has no build verification step for the Xcode project

**Severity:** Medium  
**Operational Risk:** Syntax or semantic errors introduced in `DocumentWindowController.swift`, `EditorViewController.swift`, `MainSplitViewController.swift`, or `MarkdownDocument.swift` will not be caught until `amore release` invokes `xcodebuild archive`. At that point, a compiler failure aborts mid-pipeline after the developer has already committed, tagged, and run the release script. The failure is recoverable (no assets are published), but it wastes pipeline time and requires diagnosing a build error from the amore log output rather than from a CI artifact.

**Detail:**  
The current CI pipeline:

```
pull_request / push to main
    └── swift test --package-path tests/swift-tests
        (compiles: CodeFenceInfo, EscapingHTMLFormatter, MarkdownFrontmatter, QuickLookHelpers)
        (does NOT compile: md-preview Xcode scheme)
```

The Xcode project is compiled for the first time during `amore release` → `xcodebuild archive`. Any Swift error in the new editor files surfaces only then.

**Specific Improvement:**

Add a `build` job to `swift-tests.yml` that runs before tests and compiles the full Xcode scheme. This validates that every changed Swift file compiles before a release attempt:

```yaml
jobs:
  build:
    name: xcodebuild
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode.app
      - name: Build app scheme
        run: |
          xcodebuild build \
            -project md-preview.xcodeproj \
            -scheme md-preview \
            -configuration Debug \
            -destination 'platform=macOS,arch=arm64' \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            | grep -E "error:|Build succeeded|Build FAILED"

  test:
    name: swift test
    needs: build
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode.app
      - name: Run tests
        run: swift test --package-path tests/swift-tests
```

The `CODE_SIGNING_REQUIRED=NO` flag avoids requiring a provisioning profile in the CI environment. The `needs: build` dependency ensures tests run only after the build succeeds, producing a fast-fail signal for compile errors before the slower SPM test run.

---

## Finding 7 — No integration or smoke test for the editing feature in CI

**Severity:** Medium  
**Operational Risk:** The editing feature's core behaviors — typing triggers a preview update, `Cmd+S` saves to disk, the external-change alert fires on external writes, the toolbar toggle correctly shows/hides the editor — have zero automated coverage. These can regress silently across any commit that touches `DocumentWindowController.swift` or `MainSplitViewController.swift`.

**Detail:**  
The `MarkdownSyntaxHighlighter` is the only new component with logic that could be unit-tested without mocking an NSDocument or NSWindow. All other editing behaviors are tightly coupled to AppKit's view hierarchy. The SPM package has no mechanism to import AppKit types or run a headless NSApplication, so XCTest UI testing (or `xcodebuild test` targeting an XCTest target) is required for integration coverage.

Currently, there is no XCTest target visible in the Xcode project structure (no `.xctest` bundle, no `XCTestCase` subclasses). UI tests would require:
- An `UITests` target using `XCUIApplication`
- The target added to the `md-preview` scheme's Test action
- A CI step: `xcodebuild test -scheme md-preview -destination 'platform=macOS'`

**Specific Improvement:**

In priority order:

1. **(Immediate, no AppKit dependency)** Add `MarkdownSyntaxHighlighter.swift` to the SPM test package via symlink and write unit tests for the pure-logic methods. This can be done in a single PR alongside this feature (see Finding 1, item 2 and 3).

2. **(Short-term)** Create an XCTest target `MarkdownDocumentTests` with tests for the `NSDocument` subclass that do not require a full app window:
   - `testWriteReturnsUTF8Data()` — calls `data(ofType:)` and checks the returned bytes
   - `testSetMarkdownUpdatesStorage()` — calls `setMarkdown("# Hello")` and verifies `markdownStorage` is updated
   - `testAutosavesInPlaceIsTrue()` — confirms the class-level override
   These can run with `xcodebuild test` in headless mode.

3. **(Medium-term)** Add `XCUIApplication` UI tests for the toolbar toggle and save flow. These require macOS simulator or real hardware and are slower, but they cover the end-to-end editing path.

---

## Finding 8 — Homebrew cask bump has no post-patch verification

**Severity:** Low  
**Operational Risk:** The sed substitution in `release.sh` that patches `pluk-inc/homebrew-tap` can silently produce a malformed cask file if the version or SHA format does not match the expected pattern. The script has a partial check (grep for the expected strings after patching), but the check is in a non-strict shell block — a `sed` failure is swallowed with an informational message rather than aborting the release.

**Detail:**

```bash
if ! grep -q "version \"$VERSION,$BUILD\"" "$CASK_FILE" || \
   ! grep -q "sha256 \"$DMG_SHA\""        "$CASK_FILE"; then
    echo "  ✗ cask sed didn't take — fix Casks/markdown-preview.rb manually"
    # ← no exit here; release continues
fi
```

A malformed cask means `brew upgrade --cask markdown-preview` silently installs the wrong version for Homebrew users, with no error until they try to run the app.

**Specific Improvement:**

Harden the cask verification block with an exit on failure:

```bash
if ! grep -q "version \"$VERSION,$BUILD\"" "$CASK_FILE" || \
   ! grep -q "sha256 \"$DMG_SHA\""        "$CASK_FILE"; then
    echo "  ✗ cask sed didn't take — fix Casks/markdown-preview.rb manually"
    echo "    Expected version \"$VERSION,$BUILD\" and sha256 \"$DMG_SHA\""
    exit 1
fi
```

Additionally, validate the cask syntax locally before pushing:

```bash
if command -v brew >/dev/null; then
    brew style --fix "$CASK_FILE" 2>/dev/null || true
    brew audit --cask "$CASK_FILE" 2>/dev/null && echo "  ✓ cask audit passed" || echo "  ⚠ cask audit warnings"
fi
```

---

## Release Blocklist Summary

Based on this review and prior phases, the following items must be resolved before this branch can be released to real users:

| # | Priority | Item | Blocking? |
|---|---|---|---|
| 1 | **Ship blocker** | Fix `SUFeedURL` mismatch (AGENTS.md Known Issue) — without this, Sparkle auto-update and rollback are broken for all installed users | Yes |
| 2 | **Ship blocker** | Fix data-loss defect: `toggleEditorAction` overwrites editor text within debounce window (Phase 1-B C1) | Yes |
| 3 | **Ship blocker** | Fix autosave/FileWatcher race that triggers false "File Modified Externally" alert (Phase 1-A C-1 / Phase 1-B M3) | Yes |
| 4 | **Ship blocker** | Add `xcodebuild build` step to CI so compiler errors in editing files are caught before `amore release` | Yes |
| 5 | **Pre-release** | Fix per-keystroke regex compilation (Phase 1-A C-2 / Phase 1-B H3) — functional but degrades UX on large files | No |
| 6 | **Pre-release** | Verify notarization with new `read-write` entitlement on a staging build (`release.sh --draft`) before the live release | No |
| 7 | **Pre-release** | Add `SUFeedURL` preflight check to `release.sh` | No |
| 8 | **Pre-release** | Document permission escalation in CHANGELOG entry | No |

---

## CI/CD Workflow: Current vs. Recommended

**Current:**
```
PR / push → [swift test --package-path tests/swift-tests]
                └── Tests: CodeFenceInfo, EscapingHTMLFormatter, MarkdownFrontmatter
                    (0 tests for editing feature)
```

**Recommended:**
```
PR / push → [xcodebuild build --scheme md-preview]   ← new: compile gate
               └── [swift test --package-path tests/swift-tests]
                       ├── Tests: CodeFenceInfo, EscapingHTMLFormatter, MarkdownFrontmatter
                       └── Tests: MarkdownSyntaxHighlighter (new)
```

**Release script preflight additions:**
```
release.sh preflight
    ├── ✓ working tree clean       (existing)
    ├── ✓ CHANGELOG entry exists   (existing)
    ├── ✓ amore logged in          (existing)
    ├── ✓ gh authenticated         (existing)
    ├── ✓ SUFeedURL correct        ← new
    ├── ✓ entitlements plist valid ← new
    └── ✓ no .release-blocklist    ← new
```
