---
name: changelog-maintenance
description: Maintain a clear and informative changelog for software releases. Use when documenting version changes, tracking features, or communicating updates to users. Always identifies external contributors from git/GitHub and credits them with @username tags. Handles semantic versioning, changelog formats, and release notes.
metadata:
  tags: changelog, release-notes, versioning, semantic-versioning, documentation, contributors
  platforms: Claude, ChatGPT, Gemini
---

# Changelog Maintenance

## When to use this skill

- **Before release**: organize changes before shipping a version
- **Continuous**: update whenever significant changes occur
- **Migration guide**: document breaking changes

## Instructions

### Step 0: Identify contributors (REQUIRED — do this first)

**Always** check who contributed before drafting an entry. Skipping this step is a defect.

1. Determine the previous-release tag/commit. Either parse it from `CHANGELOG.md` (the heading just below the new version) or ask the user.
2. List commit authors and merged PR authors in the range:

   ```bash
   # Authors of all commits in the release range
   git log --format='%h %an <%ae> %s' <prev>..HEAD

   # Merged PRs in the range (if a GitHub remote is configured)
   gh pr list --state merged --limit 50 \
     --json number,title,author,mergedAt \
     --search "merged:>=<prev-merge-date>"
   ```

3. Identify the maintainer(s) — usually the current `git config user.email` / repo owner — and treat everyone else as an **external contributor** that MUST be credited by GitHub `@username`.
4. For PRs that close an issue authored by someone other than the PR author (e.g. `Closes #33`), inspect the issue with `gh issue view <n> --json author` and credit the **reporter** as well.
5. Resolve every contributor's GitHub `login` (the `@handle`). If a commit author's email doesn't map to a GitHub login, look up the merged PR via `gh pr list --search "<commit-sha>"` and use `author.login` from there. Never invent a handle.

If the result is "maintainer-only", omit the Contributors block. If there is at least one external contributor or external bug reporter, you MUST include the Contributors block from Step 1.

### Step 1: Keep a Changelog format

**This project:** each version heading also carries a short release title after the date — `## [0.0.71] – 2026-11-10 – Sharper tables, steadier search` — two to five words, sentence case, no period. It becomes the GitHub release name and the title in the app's release notes; see the `release-process` skill. Keep the bullet form `- **Title.** Text ([#123](…)).`: the app turns each bullet into an item with that title, that text, and those links.

**CHANGELOG.md**:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- New user profile customization options
- Dark mode support

### Changed

- Improved performance of search feature

### Fixed

- Bug in password reset email

## [1.2.0] - 2025-01-15

### Added

- Two-factor authentication (2FA)
- Export user data feature (GDPR compliance)
- API rate limiting
- Webhook support for order events

### Changed

- Updated UI design for dashboard
- Improved email templates
- Database query optimization (40% faster)

### Deprecated

- `GET /api/v1/users/list` (use `GET /api/v2/users` instead)

### Removed

- Legacy authentication method (Basic Auth)

### Fixed

- Memory leak in background job processor
- CORS issue with Safari browser
- Timezone bug in date picker

### Security

- Updated dependencies (fixes CVE-2024-12345)
- Implemented CSRF protection
- Added helmet.js security headers

### Contributors

Thanks to the external contributors who shipped in this release:

- [@octocat](https://github.com/octocat) — webhook support for order events ([#142](https://github.com/username/repo/pull/142))
- [@hubot](https://github.com/hubot) — reported the password-reset email bug ([#138](https://github.com/username/repo/issues/138))

## [1.1.2] - 2025-01-08

### Fixed

- Critical bug in payment processing
- Session timeout issue

## [1.1.0] - 2024-12-20

### Added

- User profile pictures
- Email notifications
- Search functionality

### Changed

- Redesigned login page
- Improved mobile responsiveness

## [1.0.0] - 2024-12-01

Initial release

### Added

- User registration and authentication
- Basic profile management
- Product catalog
- Shopping cart
- Order management

[Unreleased]: https://github.com/username/repo/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/username/repo/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/username/repo/compare/v1.1.0...v1.1.2
[1.1.0]: https://github.com/username/repo/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/username/repo/releases/tag/v1.0.0
```

### Step 1b: Voice and style (this project — REQUIRED)

Every entry must read as if one person wrote all of them. The app shows these entries as its release notes, item by item, so the wording is product copy, not a commit log. Write for someone who uses Markdown Preview every day: plain, warm, specific, and sure of itself.

**Release title** (in the heading, after the date)
- Two to five words, sentence case, no period. Usually two short parallel phrases joined by a comma, often comparatives: "Sharper tables, steadier search", "Publish to Web, redesigned Settings", "Faster opens, calmer toolbar", "More control, less clutter".
- Names the release's biggest changes in the order the items come. A single-theme release may use one phrase: "Edit math in place".

**Intro** (the paragraph before the first section)
- Exactly one sentence: `Markdown Preview X.Y.Z brings A, B, and C.` Two or three themes, lowercase unless a feature name, in the same order as the items, Oxford comma.
- For a single theme, `Markdown Preview X.Y.Z focuses on …`. For a fixes-only release, `Markdown Preview X.Y.Z brings fixes for …`.
- Never "This release adds", never a list of every item, never a second sentence.

**Item title** (the bold lead-in)
- Title Case: capitalize every word except a, an, the, and, but, or, for, nor, of, to, in, on, at, by, with, as — unless it is the first word. Two to seven words. Keep the trailing period inside the bold (`**Search Keeps Its Place.**`); the app strips it.
- Use one of four shapes:
  - A feature name: "Publish to Web", "Link Pills on Release Notes".
  - What the reader can do, starting with a verb: "Switch Tabs with ⌘1 to ⌘9", "Resize Table Columns", "Keep Your Place in Search".
  - A comparative: "Sharper Diagrams", "Faster Document Opening", "Calmer Toolbar in Full Screen".
  - A short statement of what now holds: "Search Keeps Its Place", "Checkboxes Work Again in Read Mode".
- A fix is titled by what now works, never by the bug: "Search Keeps Its Place", not "Fix Search Jumping".

**Description** (after the title)
- One sentence, about 12 to 30 words, present tense. The headline feature of a release may take a second short sentence; nothing else does.
- First what changed, then why it matters, joined by "so", "making", "to", or "without": "…, so the page never jumps while you read." / "…, making long tables easier to scan." / "…to cut a step out of sharing."
- Open with one of: the reader ("Drag the divider between two header cells to resize a column…"), the feature ("Settings now opens with toolbar tabs…"), the app ("Markdown Preview remembers…"), a verb with the app as the unstated subject ("Adds…", "Upgrades…", "Keeps…"), or a condition ("When a document changes on disk, …").
- Be concrete: shortcuts as glyphs (⌘⇧O), real numbers ("for 7 days", "up to 10 recent files"), and UI names as they appear on screen.
- Say where a feature lives in plain words: "from the File menu or the Share popover", "in Settings", "from the context menu", "right-click any tab". Give a full path only for something a reader would not find alone, such as a deep setting, in plain text with arrows and no italics: "Settings → Advanced → Command Line Tools".
- Fixes describe the behavior that now works: "Clicking in the document or the search field no longer moves the highlight to the next match." Never "Fixed a bug where…".
- A dependency or engine upgrade is one plain sentence, last in its section: "Upgrades the Mermaid renderer to Pele 1.12.0, with fewer crossing lines in subgraph flowcharts."

**Words and punctuation**
- "you" and "your" for the reader. No "we", except to retire a feature or say sorry. No "users", "the user", "now supports the ability to".
- American spelling (color, canceled). Curly quotes and apostrophes (’ “ ”). Oxford comma. The ellipsis character (…) when a menu item name has one.
- No hype or filler: no "amazing", "seamless", "powerful", "simply", "just". No exclamation marks, no emoji. A little color is fine when it is plain: "without losing your place", "at a glance".
- No internal names: no class, file, or function names, no "PR", no ticket numbers in the sentence. Links go only in the trailing group: ` ([#604](https://github.com/pluk-inc/markdown-preview/pull/604)).`

**Order and size**
- Three to eight items per release. Merge small related changes into one item instead of listing each.
- Headline feature first. Within each section, order by how much a reader will notice. Upgrades last.
- Keep `### Added`, `### Changed`, `### Fixed`, and `### Contributors` in the file; the app merges the first three into one list in this order, so the order across sections matters too.

**Before and after** (0.0.70)

Before:

```markdown
This release adds **Publish to Web**: an encrypted link to a document that anyone can read in a browser. Settings moves to toolbar tabs with a live Appearance pane, ⌘1 to ⌘9 switch between tabs, and code blocks and diagrams share one set of buttons.

- **Search keeps its place.** Clicking in the document or in the search field no longer moves the highlight to the next match ([#604](…)).
- **One sidebar button in Customize Toolbar.** The palette no longer offers two buttons that both show and hide the sidebar ([#605](…)).
```

After:

```markdown
## [0.0.70] – 2026-10-27 – Publish to Web, redesigned Settings

Markdown Preview 0.0.70 brings Publish to Web, a redesigned Settings window, and quicker ways to move between tabs.

- **Search Keeps Its Place.** Clicking in the document or the search field no longer moves the highlight, so you stay on the match you were reading ([#604](…)).
- **One Sidebar Button in Customize Toolbar.** The toolbar palette offers a single sidebar button instead of two that did the same thing ([#605](…)).
```

Before you finish an entry, read it top to bottom once as a reader would: every title should make sense alone, every description should be one breath, and no sentence should sound like a different person wrote it.

### Step 2: Semantic Versioning

**Version number**: `MAJOR.MINOR.PATCH`

```
Given a version number MAJOR.MINOR.PATCH, increment:

MAJOR (1.0.0 → 2.0.0): Breaking changes
  - API changes break existing code
  - Example: adding required parameters, changing response structure

MINOR (1.1.0 → 1.2.0): Backward-compatible features
  - Add new features
  - Existing functionality continues to work
  - Example: new API endpoints, optional parameters

PATCH (1.1.1 → 1.1.2): Backward-compatible bug fixes
  - Bug fixes
  - Security patches
  - Example: fixing memory leaks, fixing typos
```

**Examples**:

- `1.0.0` → `1.0.1`: bug fix
- `1.0.1` → `1.1.0`: new feature
- `1.1.0` → `2.0.0`: Breaking change

### Step 3: Release Notes (user-friendly)

**Not for this project:** the `CHANGELOG.md` entry is the release notes (the GitHub release and the app both show it), written in the voice of Step 1b. Do not write a separate release-notes document in the format below.

```markdown
# Release Notes v1.2.0

**Released**: January 15, 2025

## 🎉 What's New

### Two-Factor Authentication

You can now enable 2FA for enhanced security. Go to Settings > Security to set it up.

![2FA Setup](https://example.com/images/2fa.png)

### Export Your Data

We've added the ability to export all your data in JSON format. Perfect for backing up or migrating your account.

## ✨ Improvements

- **Faster Search**: Search is now 40% faster thanks to database optimizations
- **Better Emails**: Redesigned email templates for a cleaner look
- **Dashboard Refresh**: Updated UI with modern design

## 🐛 Bug Fixes

- Fixed a bug where password reset emails weren't being sent
- Resolved timezone issues in the date picker
- Fixed memory leak in background jobs

## ⚠️ Breaking Changes

If you're using our API:

- **Removed**: Basic Authentication is no longer supported

  - **Migration**: Use JWT tokens instead (see [Auth Guide](docs/auth.md))

- **Deprecated**: `GET /api/v1/users/list`
  - **Migration**: Use `GET /api/v2/users` with pagination

## 🔒 Security

- Updated all dependencies to latest versions
- Added CSRF protection to all forms
- Implemented security headers with helmet.js

## 📝 Full Changelog

See [CHANGELOG.md](CHANGELOG.md) for complete details.

---

**Upgrade Instructions**: [docs/upgrade-to-v1.2.md](docs/upgrade-to-v1.2.md)
```

### Step 4: Breaking Changes migration guide

```markdown
# Migration Guide: v1.x to v2.0

## Breaking Changes

### 1. Authentication Method Changed

**Before** (v1.x):
\`\`\`javascript
fetch('/api/users', {
headers: {
'Authorization': 'Basic ' + btoa(username + ':' + password)
}
});
\`\`\`

**After** (v2.0):
\`\`\`javascript
// 1. Get JWT token
const { accessToken } = await fetch('/api/auth/login', {
method: 'POST',
body: JSON.stringify({ email, password })
}).then(r => r.json());

// 2. Use token
fetch('/api/users', {
headers: {
'Authorization': 'Bearer ' + accessToken
}
});
\`\`\`

### 2. User List API Response Format

**Before** (v1.x):
\`\`\`json
{
"users": [...]
}
\`\`\`

**After** (v2.0):
\`\`\`json
{
"data": [...],
"pagination": {
"page": 1,
"limit": 20,
"total": 100
}
}
\`\`\`

**Migration**:
\`\`\`javascript
// v1.x
const users = response.users;

// v2.0
const users = response.data;
\`\`\`

## Deprecation Timeline

- v2.0 (Jan 2025): Basic Auth marked as deprecated
- v2.1 (Feb 2025): Warning logs for Basic Auth usage
- v2.2 (Mar 2025): Basic Auth removed
```

## Output format

```
CHANGELOG.md             # Developer-facing detailed log
RELEASES.md              # User-facing release notes
docs/migration/
  ├── v1-to-v2.md        # Migration guide
  └── v2-to-v3.md
```

## Constraints

### Required rules (MUST)

1. **Reverse chronological**: latest version at the top
2. **Include dates**: ISO 8601 format (YYYY-MM-DD)
3. **Categorize entries**: Added, Changed, Fixed, etc.
4. **Identify and credit external contributors**: every release entry MUST be preceded by the Step 0 contributor check (`git log` + `gh pr list` + issue-reporter lookup for closed issues). When any non-maintainer contributed code or reported a fixed bug, a `### Contributors` block with `[@handle](https://github.com/handle)` GitHub-tag links and the relevant PR/issue numbers MUST be added. Resolve handles from real GitHub data — never invent them.

### Prohibited items (MUST NOT)

1. **No copying Git logs**: write from the user's perspective
2. **Vague wording**: "Bug fixes", "Performance improvements" (be specific)
3. **No silent contributor omission**: do not ship a release entry without running the Step 0 check, even if the user didn't ask for credits explicitly. If the check returns maintainer-only, that is fine — but it must have been run.

## Best practices

1. **Keep a Changelog**: follow the standard format
2. **Semantic Versioning**: consistent version management
3. **Breaking Changes**: provide a migration guide

## References

- [Keep a Changelog](https://keepachangelog.com/)
- [Semantic Versioning](https://semver.org/)

## Metadata

### Version

- **Current version**: 1.0.0
- **Last updated**: 2025-01-01
- **Compatible platforms**: Claude, ChatGPT, Gemini

### Tags

`#changelog` `#release-notes` `#versioning` `#semantic-versioning` `#documentation`

## Examples

### Example 1: Basic usage

<!-- Add example content here -->

### Example 2: Advanced usage

<!-- Add advanced example content here -->
