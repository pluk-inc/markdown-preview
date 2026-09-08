# German localization review

This is an AI-assisted first translation for issue #351, pending review by a fluent German speaker. Language feedback is welcome directly on the PR; no development experience is required.

## Where to suggest changes

- `md-preview/de.lproj/Localizable.strings`: settings, toolbar labels, dialogs, inspector, and preview controls. The left side is the English lookup key; suggest changes to the German text on the right.
- `md-preview/de.lproj/MainMenu.strings`: menu titles. Suggest changes to the text inside `<string>…</string>`; keep the preceding identifier unchanged.

Keep placeholders such as `%@` and `%d`, and escaped line breaks (`\n`) intact. Product names, font names, command names, and URL examples are intentionally preserved. The initial translation uses formal “Sie” in dialogs, “Sichern” for saving, and “Schnellvorschau” for Quick Look.

## Check in the app

Use a build from this branch. In Xcode, edit the **md-preview** scheme, then select **Run → Options → App Language → German** and run it. Alternatively, set German for Markdown Preview in macOS **System Settings → General → Language & Region → Applications**, then relaunch that build.

Please check:

- Menus, toolbar labels and tooltips, search, and the document information sidebar.
- All settings tabs, theme customization, and the longer privacy explanations.
- Save/discard dialogs using a disposable document, export, and print options.
- Table editing, code-copy controls, and Mermaid diagram controls.
- Narrow windows and larger text sizes for clipped labels or awkward wrapping.

Quick Look runs separately from the app. An app-only language override does not establish that Finder's Quick Look preview is German; testing that requires the extension from this build to be registered and the preview process to use German.

Please flag wording that sounds unnatural, inconsistent terms, remaining English UI, and any layout problems. A screenshot plus the preferred wording is enough. This initial PR does not close #351; fluent-speaker review is still needed before treating German as validated.
