---
name: pull-requests
description: How this repo names branches, writes PR titles and descriptions, what to run before opening a PR, and how to wait for and handle the CodeRabbit and Greptile reviews after. Load when creating a branch, opening or updating a PR, or handling bot review comments on a PR.
---

## Branch naming

Branch prefixes: `feature/`, `fix/`, `refactor/`, `perf/`, `docs/`, then a
lowercase kebab-case title. Never `codex/`.

## Title

The title names the **one main change** and why it matters, in words a person
reads at a glance. The rest goes in the description.

BAD
> fix (preview): set mermaid svg width to max-content

GOOD
> fix (preview): draw diagrams at their natural size instead of stretching them

## Description

The diff already says what changed. The description is for what the diff can't
show: why the bug happens, why this fix over the alternatives, what you tried
that didn't work.

- **Summarise, don't enumerate.** Don't account for every change, trace code
  paths by function name, or list each case you checked — that inventory is the
  diff. Give the one-level-up story: what was broken, what it does now, what to
  watch out for. Two or three short paragraphs, about 150 words, even for a
  large change. A dependency bump or a typo fix gets one line.
- **Prose, not bullets.** Reasoning is causal, and bullets break it into
  disconnected facts. Use a list only for genuinely parallel items. No section
  headers on anything under a few paragraphs.
- Name a symbol only when the reviewer needs it to find the change. Compress
  the verification to a clause ("checked in the app and Quick Look").
- Flag what the reviewer can't see in the diff: a behavior change, a trade-off
  you took on purpose, a decision you want a second opinion on.
- Agent-written descriptions run long and bury the point. Trim before opening.

BAD
> Changed `MarkdownHTML+Stylesheet.swift` to remove `width: 100%` from
> `.mermaid svg` and added `max-width: 100%`. Updated `EditorHTML.swift` to
> match. Verified with flowchart, sequence, gantt, pie, and class diagrams in
> light and dark mode, in the app and Quick Look, at three window widths.

GOOD
> Small diagrams were stretched to fill the column, so a three-box flowchart
> rendered with huge text. They now draw at their natural size and only shrink
> when wider than the column. Checked in the app and Quick Look.

## Creating a PR

Do these without being asked, in order:

1. Run `/simplify` on the diff. Fix what holds up; skip a finding only with a
   reason you can state.
2. Run the checks CI runs (`.github/workflows/swift-tests.yml`), plus an app build:
   ```bash
   swift test --package-path tests/swift-tests
   python3 tests/test-mode-transitions.py
   python3 tests/test-checkbox-saves.py
   xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build
   ```
   Fix failures before opening the PR. Do not open a PR on red checks.
3. Check `git diff` for a `DEVELOPMENT_TEAM` hunk in `project.pbxproj` and
   revert it (see "Signing & secrets" in `AGENTS.md`), and grep docs for claims the change made false.
4. Open the PR ready for review (`gh pr create`), not as a draft. Say in the PR
   description what you skipped from step 1, and why.
5. Wait for the bot reviews and handle them (below). The PR is not
   handed off until both bots have reviewed the latest commit.

## Bot reviews: CodeRabbit and Greptile

Both bots (`coderabbitai[bot]`, `greptile-apps[bot]`) review every PR on their
own, usually 3–5 minutes after it opens. Wait for them; don't hand off the PR
or end the turn first. Poll in the background (a Monitor or a background shell),
not with foreground sleeps:

```bash
pr=<N>; head=$(gh pr view $pr --json headRefOid -q .headRefOid)
for i in $(seq 1 10); do
  bots=$(gh api --paginate repos/pluk-inc/markdown-preview/pulls/$pr/reviews \
    -q ".[] | select(.commit_id==\"$head\") | .user.login
         | select(. == \"coderabbitai[bot]\" or . == \"greptile-apps[bot]\")" | sort -u | wc -l | tr -d " ")
  busy=$(gh pr view $pr --json comments -q '[.comments[] | select(.author.login=="coderabbitai")
         | select(.body | test("Come back again in a few minutes"))] | length')
  [ "$bots" -eq 2 ] && [ "$busy" -eq 0 ] && { echo reviewed; exit 0; }
  sleep 60
done; echo "timeout: $bots of 2 bots"
```

The loop counts only the two bots, and waits while CodeRabbit's PR comment says
"Come back again in a few minutes" (its review is still running). They don't
always re-review a later push. On a timeout, ask for the missing review in a PR comment:
`@coderabbitai review` or `@greptileai review`. Run the loop one more time; if it
times out again, tell the user which bot is missing rather than waiting on.

When the reviews are in, handle them with the `resolve` skill — it has the
thread query and the rules for reading bot findings:

- Verify each finding against the current code. Fix the valid ones with the
  smallest change; skip the rest with a reason. Bots are often wrong about
  WebKit, AppKit, and sandbox behavior — check before you change anything.
- If you changed files, run the step 2 checks, check `project.pbxproj` for a
  signing hunk, then commit and push without asking. No valid findings means
  nothing to commit.
- Reply to **every** bot thread with what you did or why you skipped it, then
  mark it resolved.
- A push starts a new review round. Wait again and repeat until a round has
  no new valid findings, then hand off with one line per finding: fixed or
  skipped, and why.
