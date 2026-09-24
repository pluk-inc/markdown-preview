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
| Distribution      | Amore (managed); appcast at `release.md-preview.app` |

Version is managed centrally in `Version.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). Both the app and the quick-look extension inherit from it.

## Codex development workflow

- `.codex/config.toml` pins `gpt-6-astra` with `medium` reasoning for trusted project sessions. Explicit session overrides can take precedence. This config controls the coding agent; the app's Open in LLM action delegates to external apps.
- Open PRs ready for review, never as drafts. Never use a `codex/` branch prefix.
- The maintainer uses Nushell and has `gh` authentication available. Match shell syntax to the actual execution shell.
- Complete work authorized by the user's request, making reasonable routine implementation choices. A request for a plan authorizes planning only.
- Apply skills within their stated scope. If an instruction blocks authorized work, identify the exact file and instruction rather than inferring an extra approval requirement.
- Keep verification proportional: config and documentation changes need validation and diff review; Swift changes need relevant tests and an app build; visible behavior changes need runtime verification.

## Documentation that describes behaviour is part of the behaviour

**If a change makes a documented claim false, updating that claim is part of the
change — same commit, not a follow-up.** This applies to `README.md`, sample and
fixture files, and any comment that tells a reader what to expect on screen.

The reason is not tidiness. A stale claim asserts the *opposite* of what the
code does, and people trust it, so it is worse than saying nothing at all. It
produces two specific failures:

- A correct result gets reported as a bug, because the documentation says
  something else should happen.
- A real regression gets waved through as a known limitation, because the
  documentation says it never worked.

The second one is not hypothetical here. `README.md` said Mermaid diagrams
render in both the app and Quick Look previews. They had stopped rendering in
Quick Look, and the mismatch was read as documentation drift rather than as the
bug it was — which is part of why it survived several releases before anyone
chased it (#338, fixed in #343).

So when you change what the reader sees, grep for what says otherwise:

```bash
grep -rn "<the behaviour you changed>" README.md samples/ tests/fixtures/ docs/
```

## Signing & secrets — do not touch without asking

- `DEVELOPMENT_TEAM = 5P3TSMNV42` (`project.pbxproj`, both targets) is the
  maintainer's Apple Developer Team ID, hardcoded in the shared Xcode project.
  Never change it, regenerate signing, or let Xcode "fix" it automatically —
  building locally without the team's certificates can make Xcode silently
  rewrite `DEVELOPMENT_TEAM` to your own personal team on save. Check
  `git diff` on `project.pbxproj` before committing anything and revert that
  hunk if it shows up.
- `CODE_SIGN_IDENTITY` / `CODE_SIGN_STYLE = Automatic` — same story, leave as-is.
- Secrets (currently `POSTHOG_PROJECT_TOKEN`) live in `Secrets.xcconfig`,
  gitignored — copy `Secrets.xcconfig.example` to `Secrets.xcconfig` locally.
  Never hardcode a real token into a tracked file, Info.plist, or a commit.
- The Sparkle/Amore signing material (EdDSA key, notary keychain profile) is
  documented in the `release-process` skill. Don't touch `SUPublicEDKey` in
  `Info.plist` or the entitlements' `mach-lookup` names without reading that
  skill first — they're paired with private material outside the repo (login
  Keychain / Amore), so an unmatched change breaks Sparkle updates silently.
- `md-preview.entitlements` / `quick-look.entitlements` — the sandbox
  `temporary-exception` entries (Sparkle XPC mach-lookup names, the read-only
  filesystem exception) are narrowly scoped, notarization-review-sensitive
  capabilities. Don't broaden or "clean up" them without understanding why
  they're there (see the inline comments in each file).
- A release PR must update **both** `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in `Version.xcconfig`, together with the matching
  `CHANGELOG.md` entry. Edit the version file directly during PR preparation.
  `scripts/release.sh` builds and publishes; run it only when release execution
  is requested, not merely to create the PR.

## Releasing

Every release PR must have the `release` GitHub label. Apply it when creating
the PR (`gh pr create --label release`), or add it to an existing release PR
with `gh pr edit <PR> --add-label release`. If the label does not exist in the
repository, create it first. Verify the label is present before handing off
the release PR.

See the `release-process` skill for branch/PR naming, exactly what `scripts/release.sh` and `scripts/rollback-release.sh` do, and the Amore config already wired for this project.

## Release references

- `Info.plist` currently sets `SUFeedURL` to `https://release.md-preview.app/v1/apps/doc.md-preview/appcast.xml`. Check the current plist and Amore configuration before releasing; do not assume an old hostname or mismatch still applies.
- The canonical GitHub repository is `pluk-inc/markdown-preview`. Older remotes may redirect from `pluk-inc/md-preview.app`; check `git remote -v` and `gh repo view` before publishing.

## Common Xcode tasks
```bash
xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build
xcodebuild -resolvePackageDependencies -project md-preview.xcodeproj
```
Sparkle helper tools (sign_update / generate_keys / generate_appcast) live at:
`~/Library/Developer/Xcode/DerivedData/md-preview-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`
