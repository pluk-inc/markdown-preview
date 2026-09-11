# Bullet marker spacing

Each marker should be round, vertically centered, and visibly separated from the first letter at every text size and with every document font.

<details open>
<summary><strong>Expanded details with a Markdown list</strong></summary>

- [Every linked item needs a clear marker gap.](../README.md)
- Run `inline code` after the marker without touching it.
- One item wraps onto a second line so its continuation stays aligned with the first letter rather than the marker or the page edge. This sentence is deliberately long enough to wrap in a normal document window.
- Never let an uppercase vertical stroke merge with the marker.
- New files and proportional fonts should behave alike.
- Tests: punctuation immediately after the first word should not matter.
- Non-public methods provide a hyphenated first word.
- Comments begin with a round letter.
- Exact values include `--mdp-list-gap` and other code.

</details>

- Parent item
  - Nested item beginning with a vertical stroke
  - Another nested item that wraps onto a second line so nested continuation alignment is easy to inspect at a glance in the preview.

1. Ordered markers remain right-aligned.
2. Ordered list text keeps the same visual gap.

- [ ] An unchecked task keeps its checkbox gap.
- [x] A checked task keeps its checkbox gap.
