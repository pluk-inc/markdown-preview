# Long scrollable preview — arrow keys must still navigate files

This fixture reproduces pluk-inc/markdown-preview#292 by hand. It is longer
than any Quick Look preview pane, so the preview has somewhere to scroll —
which is exactly the condition under which the bug showed up.

**Reading this by eye:**

1. Put this file in a folder with several other files (a few more `.md` files
   and some plain-text or image files work well).
2. Select a *different* file, then open Finder's preview:
   - press <kbd>Space</kbd> for the Quick Look panel, **or**
   - show the right-hand Preview pane (View ▸ Show Preview).
3. Press <kbd>↓</kbd> / <kbd>↑</kbd> to walk the selection down onto this file
   and past it.

**EXPECT:** every arrow press moves the Finder selection to the next / previous
file, including while this file is the one being previewed. The preview follows
the selection.

**REGRESSION (#292):** once this file is selected, <kbd>↓</kbd> / <kbd>↑</kbd>
scroll the rendered Markdown instead of moving the selection, and file
navigation is stuck until you click another file. That happened because the
extension made its web view first responder on load; it no longer does.

Also check, with this file previewed and **no click** into the preview:

- <kbd>Space</kbd> still closes the Quick Look panel.
- <kbd>⌘A</kbd> then <kbd>⌘C</kbd> copies the rendered text (not the Finder
  file list) — served by `performKeyEquivalent`, not by focus.

---

## Filler

The sections below exist only to make the document taller than the preview.

### Section 1

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor
incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis
nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.

- Duis aute irure dolor in reprehenderit in voluptate velit esse cillum.
- Excepteur sint occaecat cupidatat non proident.
- Sunt in culpa qui officia deserunt mollit anim id est laborum.

### Section 2

> A block quote, so the rendered height is not just paragraphs.

```swift
func neverCalled() {
    // A code block adds scrollable height and its own selection behaviour.
    print("arrow keys should not scroll this into view for you")
}
```

### Section 3

| Column A | Column B | Column C |
| -------- | -------- | -------- |
| one      | two      | three    |
| four     | five     | six      |
| seven    | eight    | nine     |

### Section 4

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor
incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis
nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu
fugiat nulla pariatur.

### Section 5

1. First item in a longer ordered list.
2. Second item.
3. Third item.
4. Fourth item.
5. Fifth item, and the page should comfortably exceed the preview height by now.

### Section 6

Closing paragraph. If you have arrowed from a file above this one, through this
file, to a file below it without the selection ever getting stuck, #292 is
fixed.
