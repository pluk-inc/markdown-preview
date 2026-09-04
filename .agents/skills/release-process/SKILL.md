---
name: release-process
description: Cut, tag, and roll back Markdown Preview releases — branch/PR naming, exactly what scripts/release.sh and scripts/rollback-release.sh do (including that release.sh publishes live before the PR exists), and the already-wired Amore distribution config (codesign identity, notary profile, EdDSA key). Use when the user asks to release, ship, cut a version, bump the version, tag a release, roll back or unpublish a release, or asks about this project's Amore-specific config (codesign identity, notary keychain profile, EdDSA key, custom domain).
---

## Release pipeline

### Branch and PR naming
Every release goes through a dedicated branch and PR — never push the version bump or changelog directly to `main`.
- **Branch name**: `release/X.Y.Z` — exactly the marketing version, no `v` prefix, no build number, no suffix. Examples: `release/0.0.10`, `release/1.2.0`. Beta cuts use `release/X.Y.Z-betaN` (e.g. `release/0.1.0-beta1`).
- **PR title**: `Release X.Y.Z (N)` where `N` is `CURRENT_PROJECT_VERSION`. Example: `Release 0.0.10 (14)`. This matches the commit message `scripts/release.sh` writes for the version-bump commit, so the PR, the bump commit, and the eventual git tag all line up. For betas: `Release X.Y.Z-betaN (build)`.
- **PR body**: short Summary (version bump + changelog added), a "What's in X.Y.Z" section that mirrors the changelog bullets, and a Test plan.
- **One PR per release**. The branch contains only the bump (`Version.xcconfig`, normally produced by `scripts/release.sh` itself — see below) and the new `CHANGELOG.md` entry — keep unrelated changes out so the release diff stays auditable.

### How `scripts/release.sh` actually works
Read this before running it — the script ships the update, it doesn't just prepare a PR.

**Preflight** (checked in this order, before anything is changed):
- the working tree must be **clean** — commit everything, including the `CHANGELOG.md` entry, before running the script;
- a `## [X.Y.Z]` entry must already exist in `CHANGELOG.md` for the version being released (the script only validates and extracts it — it never writes the entry itself; that's the `changelog-maintenance` skill's job, see below);
- `amore` must be logged in (`amore whoami`);
- unless `--skip-github` or `--draft`, the `gh` CLI must be installed and authenticated, and an `origin` remote must exist — if there's no `origin`, the script falls back to `--skip-github` on its own with a warning.

`jq` (used to parse `amore`'s JSON output) is checked later, right before the `amore release` call — **after** `Version.xcconfig` may already have been bumped and committed. If `jq` is missing when a version bump was needed, you're left with a local "Release X.Y.Z (N)" commit and no actual release; re-running the script once `jq` is installed is safe, since `Version.xcconfig` already matches and the sync step becomes a no-op.

**What it does, once preflight passes:**
1. Resolves the version and build number (see the flag reference below).
2. If `Version.xcconfig` doesn't already match the resolved version/build, updates it and commits **directly on whatever branch is currently checked out**, as `Release X.Y.Z (N)`.
3. Extracts that version's release notes from `CHANGELOG.md`.
4. Runs `amore release` — archives, signs, builds the DMG, notarizes, uploads, and — unless `--draft` was passed — **publishes the update to Amore's live appcast** (see the `SUFeedURL` mismatch in AGENTS.md's Known Issues — that's not yet the appcast already-installed copies poll). This is the actual "ship it" step.
5. Unless `--skip-github` or `--draft`: downloads the DMG, creates and pushes the `vX.Y.Z` tag, and creates the GitHub release (or, if a release for that tag already exists, uploads the DMG to it as an asset).

**The script never pushes the branch itself and never opens or merges the PR.** That remains a separate, manual step.

This has a consequence worth being explicit about: **unless you pass `--draft`, the release is already built, notarized, published to the live appcast, tagged, and on GitHub by the time the PR exists.** The branch/PR is not a pre-publish review gate — it's how the version-bump and changelog commits land on `main`'s history afterward. If a release needs to be reviewed before anything ships, the PR (with just the changelog entry) has to be reviewed *before* running the script on that branch, not after.

**Practical sequence:**
1. `git checkout -b release/X.Y.Z`
2. Add the `CHANGELOG.md` entry via the `changelog-maintenance` skill and commit it.
3. Run `./scripts/release.sh --version X.Y.Z` (only add `--build N` if you need to force a specific build number). This is the step that ships the release.
4. Push the branch and open the PR titled `Release X.Y.Z (N)`.
5. Merge with a regular merge, **not squash** — squashing rewrites the commit the `vX.Y.Z` tag points to, leaving that tag orphaned from `main`'s history.

### Commands
```bash
./scripts/release.sh                            # release current Version.xcconfig
./scripts/release.sh --version 0.0.2            # bump marketing version (auto-bumps build)
./scripts/release.sh --version 0.0.2 --build 7  # bump marketing version, force build 7 instead of auto-bumping
./scripts/release.sh --build 7                  # keep current marketing version, force build 7
./scripts/release.sh --beta                     # amore --beta + GH prerelease (still publishes live)
./scripts/release.sh --draft                    # amore --draft, no GH release — the only mode that doesn't publish
./scripts/release.sh --skip-github              # local amore release only (still publishes live; skips tag + GH release)
```

Before running, **add a `CHANGELOG.md` entry** for the version being shipped **and commit it** — the script refuses to run on a dirty working tree. **Always invoke the `changelog-maintenance` skill** via the Skill tool whenever the user asks you to write, generate, or update a changelog entry — do not draft freeform. The skill enforces the project's house format, the Keep-a-Changelog category split (Added / Changed / Fixed / Security), and contributor crediting (it always inspects `git log` and `gh pr list` for non-maintainer authors and adds a `### Contributors` block with `@username` GitHub tags when any are found).

Entry shape:
```md
## [0.0.2] – 2026-05-01
Short narrative summary.
- **Bullet for each change.**
- Bug fix bullet.
```
The en dash (`–`) between the version and the date matches the project's house style (used in the script's own help text and error messages) — follow it for consistency. The script's parser only checks that the line starts with `## [X.Y.Z]`; the date and dash aren't validated, so this is a style convention, not something tooling enforces.

Source of truth: `Version.xcconfig` for the version numbers, `CHANGELOG.md` for the notes.

## Rolling back a release
```bash
./scripts/rollback-release.sh --latest             # unpublish latest, delete GH release+tag
./scripts/rollback-release.sh 0.0.2                # unpublish specific version
./scripts/rollback-release.sh 0.0.2 --delete       # permanently delete on Amore
./scripts/rollback-release.sh 0.0.2 --keep-github  # leave GitHub release in place
./scripts/rollback-release.sh --latest --yes       # skip the confirmation prompt
```
Default is **unpublish** (reversible — flips `published=false` on Amore so it disappears from the appcast). Use `--delete` only when you're sure; it permanently removes the release. To re-publish after a non-destructive rollback: `amore releases update <version> -b doc.md-preview --published true`.

## Amore configuration (already wired)
- **Hosting**: Amore-managed with custom domain `storage.md-preview.app`
- **Codesign identity**: `Developer ID Application: Mohamed Fauzaan (5P3TSMNV42)`
- **Notary keychain profile**: `md-preview-notary`
- **EdDSA public key** (in Info.plist `SUPublicEDKey`): `gIQjgqfjkIR+egQ4S1oBLxE/NCDxpXXGdZXSpn04VAY=` — private key in login Keychain

To inspect or change: `amore config show --bundle-id doc.md-preview` / `amore config set ...`. CLI lives at `/usr/local/bin/amore`.
