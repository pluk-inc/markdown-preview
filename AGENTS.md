# Markdown Preview — agent guide

A macOS app for previewing Markdown files. AppKit, sandboxed, ships with a Quick Look extension. Updates via Sparkle, distributed via Amore.

## Project facts

| Thing             | Value                                                       |
| ----------------- | ----------------------------------------------------------- |
| Bundle id         | `doc.md-preview`                                            |
| Product name      | `Markdown Preview`                                          |
| Scheme            | `md-preview`                                                |
| Quick Look target | `quick-look` (embedded extension)                           |
| Min macOS         | 15.0                                                        |
| Sandboxed         | yes — uses Sparkle XPC services for updates                 |
| Auto-updater      | Sparkle 2.x (Swift package)                                 |
| Distribution      | Amore (managed) with custom domain `storage.md-preview.app` |

Version is managed centrally in `Version.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). Both the app and the quick-look extension inherit from it.

## Releasing

See the `release-process` skill for branch/PR naming, exactly what `scripts/release.sh` and `scripts/rollback-release.sh` do, and the Amore config already wired for this project.

## Known issues
- **`SUFeedURL` mismatch**. Info.plist points to `https://storage.md-preview.app/appcast.xml` but Amore actually publishes to `https://storage.md-preview.app/v1/apps/doc.md-preview/appcast.xml`. This matters for **any release run that isn't `--draft`** — the default run, `--beta`, and `--skip-github` all publish to Amore's live appcast, which — due to the mismatch above — is not yet the URL already-installed copies poll; `--draft` is the only mode that doesn't publish. Fix Info.plist before any of those ship to real users — already-installed copies will check the wrong URL forever. Either change `SUFeedURL` to the `/v1/apps/...` path, or configure a CDN rewrite at `storage.md-preview.app` to map `/appcast.xml` → the real path.
- **No git remote yet**. `git remote -v` is empty. Run `gh repo create` before relying on the GitHub release portion of `scripts/release.sh` (it auto-skips when no remote exists).

## Common Xcode tasks
```bash
xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build
xcodebuild -resolvePackageDependencies -project md-preview.xcodeproj
```
Sparkle helper tools (sign_update / generate_keys / generate_appcast) live at:
`~/Library/Developer/Xcode/DerivedData/md-preview-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`
