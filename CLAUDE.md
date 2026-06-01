# Markdown Preview — agent guide

A macOS app for previewing Markdown files. AppKit, sandboxed, ships with a Quick Look extension. Updates via Sparkle, distributed via Amore.

## Project facts

| Thing | Value |
|---|---|
| Bundle id | `doc.md-preview` |
| Product name | `Markdown Preview` |
| Scheme | `md-preview` |
| Quick Look target | `quick-look` (embedded extension) |
| Min macOS | 15.0 |
| Sandboxed | yes — uses Sparkle XPC services for updates |
| Auto-updater | Sparkle 2.x (Swift package) |

The app also declares `com.apple.security.files.user-selected.read-write` so **Export as PDF…** can write to a user-chosen path via `NSSavePanel` (Powerbox grants a write extension to the destination).
| Distribution | Amore (managed) with custom domain `storage.md-preview.app` |

Version is managed centrally in `Version.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). Both the app and the quick-look extension inherit from it.

## Release pipeline

### Branch and PR naming

Every release goes through a dedicated branch and PR — never push the version bump or changelog directly to `main`.

- **Branch name**: `release/X.Y.Z` — exactly the marketing version, no `v` prefix, no build number, no suffix. Examples: `release/0.0.10`, `release/1.2.0`. Beta cuts use `release/X.Y.Z-betaN` (e.g. `release/0.1.0-beta1`).
- **PR title**: `Release X.Y.Z (N)` where `N` is `CURRENT_PROJECT_VERSION`. Example: `Release 0.0.10 (14)`. This matches the commit message the release script writes, so the PR, the bump commit, and the eventual git tag all line up. For betas: `Release X.Y.Z-betaN (build)`.
- **PR body**: short Summary (version bump + changelog added), a "What's in X.Y.Z" section that mirrors the changelog bullets, and a Test plan.
- **One PR per release**. The branch contains only the bump (`Version.xcconfig`) and the new `CHANGELOG.md` entry — keep unrelated changes out so the release diff stays auditable.

### Commands

One command:

```bash
./scripts/release.sh                     # release current Version.xcconfig
./scripts/release.sh --version 0.0.2     # bump marketing version (auto-bumps build)
./scripts/release.sh --version 0.0.2 --build 7
./scripts/release.sh --beta              # amore --beta + GH prerelease
./scripts/release.sh --draft             # amore --draft, no GH release
./scripts/release.sh --skip-github       # local amore release only
```

Before running, **add a `CHANGELOG.md` entry** for the version being shipped. **Always invoke the `changelog-maintenance` skill** (`.claude/skills/changelog-maintenance`) via the Skill tool whenever the user asks you to write, generate, or update a changelog entry — do not draft freeform. The skill enforces the project's house format, the Keep-a-Changelog category split (Added / Changed / Fixed / Security), and contributor crediting (it always inspects `git log` and `gh pr list` for non-maintainer authors and adds a `### Contributors` block with `@username` GitHub tags when any are found).

Entry shape:

```md
## [0.0.2] – 2026-05-01

Short narrative summary.

- **Bullet for each change.**
- Bug fix bullet.
```

The script:
1. Validates the changelog entry exists for the resolved version
2. Updates `Version.xcconfig` and commits as `Release X.Y.Z (N)` if it changed
3. Runs `amore release --scheme md-preview --release-notes "$NOTES"` (full pipeline: archive → sign → DMG → notarize → EdDSA-sign → upload → publish appcast)
4. Tags `vX.Y.Z`, pushes, creates GitHub release with DMG asset

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

## Common Xcode tasks

```bash
xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build
xcodebuild -resolvePackageDependencies -project md-preview.xcodeproj
```

Sparkle helper tools (sign_update / generate_keys / generate_appcast) live at:
`~/Library/Developer/Xcode/DerivedData/md-preview-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`
