# Markdown Preview — agent guide

A macOS app for reading and editing Markdown files. AppKit, sandboxed, ships with a Quick Look extension. Updates via Sparkle, distributed via Amore.

## Project facts

| Thing | Value |
|---|---|
| Bundle id | `doc.md-preview` |
| Product name | `Markdown Preview` |
| Scheme | `md-preview` |
| Quick Look target | `quick-look` (embedded extension) |
| Min macOS | 15.0 |
| Sandboxed | yes — uses Sparkle XPC services for updates |
| Editing | Inline source editor (NSTextView) with syntax highlighting; autosaves via NSDocument |
| Auto-updater | Sparkle 2.x (Swift package) |
| Distribution | Amore (managed) with custom domain `storage.md-preview.app` |

Version is managed centrally in `Version.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). Both the app and the quick-look extension inherit from it.

## Release pipeline

One command:

```bash
./scripts/release.sh                     # release current Version.xcconfig
./scripts/release.sh --version 0.0.2     # bump marketing version (auto-bumps build)
./scripts/release.sh --version 0.0.2 --build 7
./scripts/release.sh --beta              # amore --beta + GH prerelease
./scripts/release.sh --draft             # amore --draft, no GH release
./scripts/release.sh --skip-github       # local amore release only
```

Before running, **add a `CHANGELOG.md` entry** for the version being shipped:

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

## Known issues

- **Autosave vs. FileWatcher**. The inline editor autosaves via `NSDocument` (`autosavesInPlace`), but `FileWatcher` still watches the on-disk file. A self-triggered write can surface the external-change alert or reload the preview before autosave settles — a known edge case when editing with the source pane open.
- **`SUFeedURL` mismatch**. Info.plist points to `https://storage.md-preview.app/appcast.xml` but Amore actually publishes to `https://storage.md-preview.app/v1/apps/doc.md-preview/appcast.xml`. Fix Info.plist before any non-test release ships to real users — already-installed copies will check the wrong URL forever. Either change `SUFeedURL` to the `/v1/apps/...` path, or configure a CDN rewrite at `storage.md-preview.app` to map `/appcast.xml` → the real path.
- **No git remote yet**. `git remote -v` is empty. Run `gh repo create` before relying on the GitHub release portion of `scripts/release.sh` (it auto-skips when no remote exists).

## Common Xcode tasks

```bash
xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build
xcodebuild -resolvePackageDependencies -project md-preview.xcodeproj
```

Sparkle helper tools (sign_update / generate_keys / generate_appcast) live at:
`~/Library/Developer/Xcode/DerivedData/md-preview-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`
