# Changelog

## [0.0.52] – 2026-09-01

This release rebuilds the reading experience around a single "aA" control in the toolbar: a theme is now a complete reading look — page color, ink, reading face, and body weight — and a new Customize Theme sheet carries the fonts and the spacing controls. The toolbar is also a native window-drag surface again, editing gains pasted images and a native New Document flow, and a long list of layout and rendering faults are fixed.

### Added

- **A Themes & Settings popover in the toolbar.** The "aA" toolbar item holds the text-size pair with a dot scale, an Appearance button that cycles Automatic → Light → Dark, and a 3 × 3 gallery of nine themes — Original, Quiet, Paper, Bold, Calm, Focus, Graphite, Dusk, and Midnight — each card drawn in its own page color, ink, and reading face ([#333](https://github.com/pluk-inc/markdown-preview/pull/333)).
- **A Customize Theme sheet sets the reading font and the layout.** The sheet offers 12 reading faces, each name set in the face it applies, a Bold Text switch, and — behind a Customize gate — Line Spacing, Character Spacing, Word Spacing, and Margins, with a live preview and per-surface color wells. Quick Look reads with the same layout. Reset Theme restores the applied theme's colors, face, and weight ([#333](https://github.com/pluk-inc/markdown-preview/pull/333)).
- **Images can be pasted into the editor.** A pasted image is written as a PNG into a `<document-name>-pictures` folder beside the Markdown file, numbered from `1.png`, and inserted as a relative Markdown link. The image renders in both preview and edit mode, and a click on it opens a rename sheet that moves the file and rewrites the Markdown destination ([#307](https://github.com/pluk-inc/markdown-preview/pull/307)).
- **A native New Document action.** Markdown documents are declared with the Editor role, so File ▸ New Document and the New Document button in the launch panel create an untitled document that opens directly in edit mode. The first save uses the native save panel ([#320](https://github.com/pluk-inc/markdown-preview/pull/320)).

### Changed

- **The toolbar is built from AppKit-owned items.** The sidebar pull-down, the back and forward pair, and the Inspector, Edit, and Always on Top toggles are now native toolbar items instead of custom control views. They keep the single glass pill and stay individually movable in Customize Toolbar ([#319](https://github.com/pluk-inc/markdown-preview/pull/319), [#330](https://github.com/pluk-inc/markdown-preview/pull/330)).
- **The formatting bar and the find bar sit below the tab bar.** Both bars are content overlays now, so the tab bar no longer moves when edit mode is toggled or find is opened. The order reads tab bar → find bar → formatting bar → document, and the bars tuck into the tab bar's bottom margin so the rows read as one block ([#331](https://github.com/pluk-inc/markdown-preview/pull/331)).
- **The Appearance pane in Settings uses the same theme cards as the popover.** Removing the toolbar item never takes away access to themes ([#333](https://github.com/pluk-inc/markdown-preview/pull/333)).

### Fixed

- **The toolbar moves the window again.** Only two small gaps responded to a drag before. With the transparent titlebar, macOS 26 also re-dispatched clicks in the toolbar padding into the web view, which consumed them; the web views now decline those clicks so the native drag starts ([#319](https://github.com/pluk-inc/markdown-preview/pull/319), [#330](https://github.com/pluk-inc/markdown-preview/pull/330), [#317](https://github.com/pluk-inc/markdown-preview/issues/317)).
- **The Copy button on a code block works in Quick Look.** The Finder preview now writes the block text to the pasteboard through a dedicated handler, with `document.execCommand('copy')` as a last resort, instead of failing without a message inside the extension sandbox ([#327](https://github.com/pluk-inc/markdown-preview/pull/327)).
- **Renaming a pasted image no longer loses the change.** The inserted Markdown is saved before a rename starts, rename waits for a save that is in flight, and the editor replacement stays out of the undo history so Undo cannot restore an old image path. Reload from Disk restores the image and synchronizes the editor, draft, baseline, and dirty state ([#325](https://github.com/pluk-inc/markdown-preview/pull/325)).
- **Escaped square brackets in a link no longer turn into display math.** Brackets inside a valid Markdown link are preserved before the math pass, so `[4]` renders as a link while adjacent `x^2` still renders as math ([#323](https://github.com/pluk-inc/markdown-preview/pull/323), [#322](https://github.com/pluk-inc/markdown-preview/issues/322)).
- **The empty area left of a centered document scrolls.** Wheel gestures over the native gutter reach the document, and the toolbar backing color continues across the gutter, so the seam at the leading edge of the text is gone ([#321](https://github.com/pluk-inc/markdown-preview/pull/321)).
- **The edit and find bars no longer crowd the tabs in full screen.** Full screen draws the tab bar with a thinner bottom margin, so the overlap is now 2 pt there and 6 pt in a normal window ([#332](https://github.com/pluk-inc/markdown-preview/pull/332)).
- **A scrolled image no longer leaves a blur in the titlebar.** The preview web view is hidden after the crossfade into edit mode, so AppKit stops sampling it for the titlebar material ([#307](https://github.com/pluk-inc/markdown-preview/pull/307)).

### Contributors

Thank you to the people outside the project who shipped code or reported a fault in this release:

- [@kud](https://github.com/kud) — made the toolbar a window-drag surface again, and reported the fault ([#319](https://github.com/pluk-inc/markdown-preview/pull/319), [#317](https://github.com/pluk-inc/markdown-preview/issues/317))
- [@wzz6423](https://github.com/wzz6423) — pasted image support and the image rename fixes ([#307](https://github.com/pluk-inc/markdown-preview/pull/307), [#325](https://github.com/pluk-inc/markdown-preview/pull/325))
- [@juanmaramos](https://github.com/juanmaramos) — the native New Document flow ([#320](https://github.com/pluk-inc/markdown-preview/pull/320))
- [@eichiiiwastaken](https://github.com/eichiiiwastaken) — centered preview gutter scrolling and the toolbar seam ([#321](https://github.com/pluk-inc/markdown-preview/pull/321))
- [@qisthidev](https://github.com/qisthidev) — the code-block Copy button in Quick Look ([#327](https://github.com/pluk-inc/markdown-preview/pull/327))
- [@dimiboi](https://github.com/dimiboi) — reported the escaped brackets rendering as display math ([#322](https://github.com/pluk-inc/markdown-preview/issues/322))

## [0.0.51] – 2026-08-25

This release lets you color the whole application with themes, and it lets a link in a browser or another application open a Markdown file directly.

### Added

- **Theme colors change the look of the whole window.** Settings ▸ Appearance offers six built-in presets — Red Graphite, Dark Graphite, High Contrast, Charcoal, Solarized Light, and Solarized Dark — and separate color wells for the window background, the code block background, the text, and the links. A theme reaches the page, the toolbar, the sidebar, edit mode, and full screen, in both light and dark appearance ([#294](https://github.com/pluk-inc/markdown-preview/pull/294)).
- **A `md-preview://` link opens a file from a browser.** A link in the shape `md-preview://file/<absolute path>` opens the file in the application, like `cursor://file/…` does for Cursor. A folder path opens through the normal folder flow, and a malformed link shows an alert that explains the expected shape ([#312](https://github.com/pluk-inc/markdown-preview/pull/312), [#304](https://github.com/pluk-inc/markdown-preview/issues/304)).

### Changed

- **The Appearance pane in Settings replaces the Theme pane.** The Automatic, Light, and Dark picker moved there from the General pane, and the Settings window always opens on the General pane ([#294](https://github.com/pluk-inc/markdown-preview/pull/294)).
- **The tab bar no longer shows a "+" button.** File ▸ New Tab and ⌘T still create a tab ([#294](https://github.com/pluk-inc/markdown-preview/pull/294)).

### Contributors

Thank you to the reporter who helped shape this release:

- [@federicolarumbe](https://github.com/federicolarumbe) — requested the URL scheme that opens a file from a browser ([#304](https://github.com/pluk-inc/markdown-preview/issues/304))

## [0.0.50] – 2026-08-25

This release gives you more control over how Markdown Preview opens, displays, and saves documents. Editing gains automatic saving, bracket pairing, and a more capable fenced-code experience, while several window and navigation problems are fixed.

### Added

- **The inspector shows where a document is stored.** The Document pane now includes a selectable Where row beneath the file name. Paths inside your home folder use `~`, and the complete path appears when you hold the pointer over the row ([#277](https://github.com/pluk-inc/markdown-preview/pull/277)).
- **Rendered Markdown can use a different font.** Settings ▸ General now offers System, Serif, Rounded, and Monospace choices. Open documents update immediately, and the same choice applies to Finder previews ([#302](https://github.com/pluk-inc/markdown-preview/pull/302)).
- **Documents can open as tabs by default.** Enable Open documents in tabs under Settings ▸ General ▸ Windows to place files opened from Finder, File ▸ Open…, or Open Recent into the front window. The existing behaviour remains the default, and Open in New Window still opens a separate window ([#303](https://github.com/pluk-inc/markdown-preview/pull/303), [#230](https://github.com/pluk-inc/markdown-preview/issues/230)).
- **Edited documents can save automatically.** Settings ▸ General includes automatic-saving choices from 30 seconds to 60 minutes. It is off by default and runs only for file-backed documents with unsaved changes. Automatic saving uses the existing external-change protection and reports its status in the window subtitle ([#305](https://github.com/pluk-inc/markdown-preview/pull/305)).
- **The editor pairs brackets automatically.** Typing an opening bracket, parenthesis, brace, quote, or backtick inserts its matching character and leaves the insertion point between the pair. Backspace removes an unused pair together ([#306](https://github.com/pluk-inc/markdown-preview/pull/306)).
- **Anonymous active-install counts can be shared with the project.** Release builds send at most one event per installation per UTC day so the project can measure daily and monthly active installations. The event contains a random installation identifier and coarse compatibility information, but no document content, file names, paths, actions, screens, precise location, personal information, advertising identifiers, or person profile. You can disable it under Settings ▸ Privacy ([#309](https://github.com/pluk-inc/markdown-preview/pull/309)).

### Changed

- **Always on Top is now an application-wide preference.** Turning it on affects every open and future preview window, persists across launches, and stays synchronized between the toolbar, View menu, and Settings ▸ General ▸ Windows ([#301](https://github.com/pluk-inc/markdown-preview/pull/301)).
- **Fenced code blocks are easier to edit.** Tab inserts indentation inside code without changing fence lines, unlabelled blocks can detect and highlight common languages without modifying the source, and an explicit language field lets you add or change the authored language. Typing an opening fence also creates its matching closing fence ([#308](https://github.com/pluk-inc/markdown-preview/pull/308)).

### Fixed

- **The Files sidebar changes selection without flickering.** Its highlight now stays on the current file until the requested document finishes loading, then moves once to the new file ([#296](https://github.com/pluk-inc/markdown-preview/pull/296), [#295](https://github.com/pluk-inc/markdown-preview/issues/295)).
- **A file reopens after its window has been closed.** Opening the same file again from Finder, Open With, or the command-line tool now creates a new window even when its document remained loaded in the running application ([#299](https://github.com/pluk-inc/markdown-preview/pull/299), [#297](https://github.com/pluk-inc/markdown-preview/issues/297)).

### Contributors

Thank you to the external contributors and reporter who helped improve this release:

- [@caic99](https://github.com/caic99) — added the document location to the inspector ([#277](https://github.com/pluk-inc/markdown-preview/pull/277))
- [@zjy365](https://github.com/zjy365) — reported and fixed the Files sidebar selection flicker ([#296](https://github.com/pluk-inc/markdown-preview/pull/296), [#295](https://github.com/pluk-inc/markdown-preview/issues/295))
- [@bosir](https://github.com/bosir) — reported and fixed reopening files whose windows were closed ([#299](https://github.com/pluk-inc/markdown-preview/pull/299), [#297](https://github.com/pluk-inc/markdown-preview/issues/297))
- [@kud](https://github.com/kud) — made Always on Top persistent, added the rendered-document font choices, and added the tab-opening preference ([#301](https://github.com/pluk-inc/markdown-preview/pull/301), [#302](https://github.com/pluk-inc/markdown-preview/pull/302), [#303](https://github.com/pluk-inc/markdown-preview/pull/303))
- [@wzz6423](https://github.com/wzz6423) — added automatic saving and bracket pairing, and improved fenced-code editing ([#305](https://github.com/pluk-inc/markdown-preview/pull/305), [#306](https://github.com/pluk-inc/markdown-preview/pull/306), [#308](https://github.com/pluk-inc/markdown-preview/pull/308))
- [@andrew-hill](https://github.com/andrew-hill) — requested the option to open documents in tabs ([#230](https://github.com/pluk-inc/markdown-preview/issues/230))

## [0.0.49] – 2026-08-15

This release adds a Settings window that collects all the preferences of the application in one place. It also makes the keyboard commands and a new Copy button work in a Finder preview.

### Added

- **The application has a Settings window.** Press ⌘, or use Markdown Preview ▸ Settings… to open it. The window has three panes: General, Privacy, and About. The panes contain the preferences that were only in the menus before: the appearance, the text size, the content width, the application that File ▸ Open in… uses, the crash reports, and the automatic update checks from Sparkle. The window uses the icons and the layout of macOS System Settings. A change in the window and a change in the menu stay equal, and the About pane shows the date of the last update check immediately. A new installation checks for updates automatically, but the application keeps your choice if you made one before. The window is available in English and in Simplified Chinese ([#287](https://github.com/pluk-inc/markdown-preview/pull/287)).
- **A Finder preview has a Copy button.** The button is in the bottom-right corner of the preview. It copies the Markdown source text of the file to the pasteboard, and you do not select the text first. The button shows "Copied" immediately after you click it, and it stays clear of the content of the preview ([#289](https://github.com/pluk-inc/markdown-preview/pull/289)).

### Fixed

- **⌘A and ⌘C work in a Finder preview immediately.** The preview panel opened with the keyboard focus in Finder. Therefore ⌘A selected the files in the Finder window, and the two commands did nothing in the preview until you clicked in it. The preview now takes the keyboard focus when the content is complete, and it accepts ⌘A and ⌘C directly. Finder keeps the other keys: the arrow keys change the selected file, and the space key closes the panel ([#288](https://github.com/pluk-inc/markdown-preview/pull/288)).

## [0.0.48] – 2026-08-15

This release changes the vertical gaps and the type sizes in the preview and in the editor. It also lets you select text in a Finder preview, keep a preview window in front of other applications, and print and export diagrams correctly.

### Added

- **Always on Top keeps a preview window in front of other applications.** Use the item in the View menu, or press ⌃⌘T. A toolbar button is also available in Customize Toolbar. The setting applies to all the tabs in one window. The application does not keep the setting after you quit it ([#266](https://github.com/pluk-inc/markdown-preview/pull/266)).
- **You can select and copy text in a Finder preview.** The Quick Look extension now uses a `WKWebView` view. Therefore the selection belongs to the preview, and ⌘C copies the text that you select. Before this release, ⌘C copied the Markdown file. The text cursor and the link cursor are also correct now. Local images, the resource limits, and external links do not change ([#273](https://github.com/pluk-inc/markdown-preview/pull/273)).
- **The application applies strikethrough to a completed task item.** A task item with `- [x]` shows dim text with strikethrough. A task item with `- [ ]` does not change. If you click the checkbox in the preview, the style changes immediately ([#283](https://github.com/pluk-inc/markdown-preview/pull/283)).

### Changed

- **The headings have new sizes.** The size of the H1 heading and the size of the H2 heading were almost equal. This made the structure of a document difficult to read. The six heading levels now use these sizes: 1.802em, 1.602em, 1.424em, 1.266em, 1.125em, and 1em. Only the H1 heading uses weight 700. The preview and the editor use the same sizes ([#281](https://github.com/pluk-inc/markdown-preview/pull/281)).
- **The list bullets are larger.** The `•` character was very small. The application now makes the character transparent, and draws a circle with a diameter of 0.4em in its position. The character keeps its space in the margin. If you copy the text, the character stays in the copy. The gap between the circle and the text is 0.5em in the preview and in the editor. The application draws the circle with a border and not with a background color. Therefore a PDF export keeps the circle when it does not print background colors ([#282](https://github.com/pluk-inc/markdown-preview/pull/282)).
- **The gaps above and below a horizontal rule are equal.** A horizontal rule had a large margin above it and below it. The margin of the next block increased the gap below it to approximately 51 px, and the gap above it was approximately 39 px. The horizontal rule now has a margin of 12 px above it only, and the next block supplies the gap below it. Both gaps are now equal to the usual gap between two paragraphs ([#280](https://github.com/pluk-inc/markdown-preview/pull/280)).

### Fixed

- **A blank line makes a smaller gap.** One blank line in the source text made a gap of 22.8 px. Therefore the usual gap between two paragraphs was approximately 35 px. One blank line now makes a gap of 4 px, and the gap between two paragraphs is approximately 16 px. Other Markdown applications use approximately the same gap. Each additional blank line adds one more line of height. Therefore you keep larger gaps if you write them in the source text. The gaps above the headings do not change from release 0.0.47 ([#279](https://github.com/pluk-inc/markdown-preview/pull/279), [#271](https://github.com/pluk-inc/markdown-preview/issues/271)).
- **The application renders all the diagrams before it prints or exports a document.** The application renders a diagram when you scroll near to it. But a print operation or an export operation uses the full document at one time. Therefore a diagram that you did not scroll to showed an empty box and its source text. File ▸ Print… and File ▸ Export… now wait until all the diagrams are complete. A print operation also uses the light theme for the diagrams, because the application puts the theme in the diagram when it renders it. The application returns to the theme on the screen after the print panel closes. A diagram also stays on one page ([#275](https://github.com/pluk-inc/markdown-preview/pull/275), [#274](https://github.com/pluk-inc/markdown-preview/issues/274)).
- **Strikethrough needs two tilde characters.** The application applied strikethrough to text between two single tilde characters, for example `~text~`. This was not correct for text that contains paths, version numbers, or approximate values. The application now applies strikethrough only to text between two double tilde characters, for example `~~text~~`. A single tilde character stays as text ([#278](https://github.com/pluk-inc/markdown-preview/pull/278)).

### Contributors

Thank you to the external contributors of this release:

- [@kud](https://github.com/kud) — added the Always on Top function ([#266](https://github.com/pluk-inc/markdown-preview/pull/266))
- [@Avi7ii](https://github.com/Avi7ii) — added text selection and correct cursors to Finder previews ([#273](https://github.com/pluk-inc/markdown-preview/pull/273))
- [@Cuzeth](https://github.com/Cuzeth) — reported and corrected the diagram export problem ([#275](https://github.com/pluk-inc/markdown-preview/pull/275), [#274](https://github.com/pluk-inc/markdown-preview/issues/274))
- [@ray-zzzzz](https://github.com/ray-zzzzz) — changed strikethrough to use two tilde characters ([#278](https://github.com/pluk-inc/markdown-preview/pull/278))
- [@t9mike](https://github.com/t9mike) — reported the large gaps above paragraphs and headings ([#271](https://github.com/pluk-inc/markdown-preview/issues/271))

## [0.0.47] – 2026-08-08

The Appearance setting now covers Finder previews too, so the app and Quick Look stop disagreeing about light and dark. Because 0.0.46 shipped only briefly, its sidebar shortcut and heading-spacing fix are listed here as well — most people will pick them up in this update.

### Added

- **⌘L toggles the sidebar.** A Toggle Sidebar item in the View menu shows and hides the sidebar from the keyboard ([#267](https://github.com/pluk-inc/markdown-preview/pull/267)).

### Changed

- **View ▸ Appearance controls Quick Look as well.** The existing Automatic / Light / Dark choice was stored only in the app's own defaults, so the sandboxed Quick Look extension couldn't see it and kept following the system appearance. The setting now lives in storage shared by both targets — and is migrated over from the old location on first launch — so a fixed Light or Dark applies to the page surface, text, math errors, syntax highlighting, and Mermaid diagrams in Finder previews. Automatic still follows each host's native appearance ([#265](https://github.com/pluk-inc/markdown-preview/pull/265)).

### Fixed

- **Headings after blank lines use compact spacing.** A blank line already renders its own height, and the heading's margin stacked on top of it, producing oversized gaps. Authored blank lines are preserved, but the stacked margin above them drops to 4 px — in reading mode and for both ATX and Setext headings in edit mode ([#264](https://github.com/pluk-inc/markdown-preview/pull/264), [#263](https://github.com/pluk-inc/markdown-preview/issues/263)).

### Contributors

Thanks to the external contributors who helped improve this release:

- [@Avi7ii](https://github.com/Avi7ii) — shared the app's appearance setting with Quick Look ([#265](https://github.com/pluk-inc/markdown-preview/pull/265))
- [@inceenes10](https://github.com/inceenes10) — added the ⌘L sidebar shortcut ([#267](https://github.com/pluk-inc/markdown-preview/pull/267))
- [@t9mike](https://github.com/t9mike) — reported the excess vertical space around headings ([#263](https://github.com/pluk-inc/markdown-preview/issues/263))

## [0.0.46] – 2026-08-08

The sidebar gets a keyboard shortcut, and headings after blank lines no longer leave a gaping hole in the page.

### Added

- **⌘L toggles the sidebar.** A Toggle Sidebar item in the View menu shows and hides the sidebar from the keyboard ([#267](https://github.com/pluk-inc/markdown-preview/pull/267)).

### Fixed

- **Headings after blank lines use compact spacing.** A blank line already renders its own height, and the heading's margin stacked on top of it, producing oversized gaps. Authored blank lines are preserved, but the stacked margin above them drops to 4 px — in reading mode and for both ATX and Setext headings in edit mode ([#264](https://github.com/pluk-inc/markdown-preview/pull/264), [#263](https://github.com/pluk-inc/markdown-preview/issues/263)).

### Contributors

Thanks to the external contributors who helped improve this release:

- [@inceenes10](https://github.com/inceenes10) — added the ⌘L sidebar shortcut ([#267](https://github.com/pluk-inc/markdown-preview/pull/267))
- [@t9mike](https://github.com/t9mike) — reported the excess vertical space around headings ([#263](https://github.com/pluk-inc/markdown-preview/issues/263))

## [0.0.45] – 2026-08-05

Mermaid diagrams in Quick Look now match the system appearance.

### Fixed

- **Mermaid diagrams respect dark mode in Quick Look.** Quick Look now passes its native macOS appearance into the rendered preview, so diagrams use a readable dark theme instead of light colors against a dark background ([#261](https://github.com/pluk-inc/markdown-preview/pull/261), [#260](https://github.com/pluk-inc/markdown-preview/issues/260)).

### Contributors

Thanks to the external reporter who helped improve this release:

- [@GloryAlex](https://github.com/GloryAlex) — reported the Mermaid dark-mode mismatch in Quick Look ([#260](https://github.com/pluk-inc/markdown-preview/issues/260))

## [0.0.44] – 2026-08-02

Exported PDFs now look like the document you were reading.

### Changed

- **PDF export matches the read-only preview.** Exports keep the preview stylesheet and the active light or dark appearance, hold the same 820 px content measure, and turn the reading view's 32/40/48 px padding into real page margins so every page gets matching gutters. The print-only font-size control is hidden from the export panel, while File ▸ Print… keeps its existing paper-oriented sizing and pagination ([#258](https://github.com/pluk-inc/markdown-preview/pull/258)).

## [0.0.43] – 2026-07-30

Large documents open dramatically faster, reading mode is properly white in light mode, and the preview stays on the file you opened while you edit.

### Added

- **Support link in the README.** A Support section and GitHub Sponsors button make it easier to back continued development ([#249](https://github.com/pluk-inc/markdown-preview/pull/249)).

### Changed

- **Large Markdown files render far faster.** Initial rendering no longer forces WebKit to resolve the growing document repeatedly, and table setup stops reading every header through layout-sensitive properties. A generated 1 MB prose file went from 17.5 seconds to 0.36 seconds on a cold launch, with a mixed 250 KB fixture improving 95% on DOM update and 91% on first contentful paint — at flat to slightly lower memory ([#250](https://github.com/pluk-inc/markdown-preview/pull/250)).
- **Reading mode now paints a white page in light mode.** macOS 15 (Sequoia) and earlier previously showed grey, which left code blocks barely distinguishable from surrounding text ([#253](https://github.com/pluk-inc/markdown-preview/pull/253), [#251](https://github.com/pluk-inc/markdown-preview/issues/251)).

### Fixed

- **The preview stays on the original file during editor backup saves.** Automatic reloads no longer follow a temporary backup path, so the window keeps tracking the document you opened ([#254](https://github.com/pluk-inc/markdown-preview/pull/254), [#119](https://github.com/pluk-inc/markdown-preview/issues/119)).
- **The Buy Me a Coffee button image renders in the README.** The badge URL was broken and showed as a missing image ([#252](https://github.com/pluk-inc/markdown-preview/pull/252)).

### Contributors

Thanks to the reporters who helped improve this release:

- [@rblath](https://github.com/rblath) — requested a white background in preview mode ([#251](https://github.com/pluk-inc/markdown-preview/issues/251))
- [@gglanzani](https://github.com/gglanzani) — reported automatic file reloading ([#119](https://github.com/pluk-inc/markdown-preview/issues/119))

## [0.0.42] – 2026-07-28

Mermaid diagrams can now open in their own resizable windows, editing gains natural list indentation, and Markdown projects work better across nested folders and infrastructure code.

### Added

- **Open Mermaid diagrams in a separate window.** A new control opens a diagram in a resizable window titled from its nearest heading, making large diagrams easier to inspect beside the document. The control stays out of Quick Look, the window behaves normally alongside other apps, and the diagram toolbar adapts to narrow figures ([#237](https://github.com/pluk-inc/markdown-preview/pull/237), [#245](https://github.com/pluk-inc/markdown-preview/pull/245), [#247](https://github.com/pluk-inc/markdown-preview/pull/247)).
- **Syntax highlighting for HCL and Terraform.** Fenced code blocks tagged `hcl`, `terraform`, or `tf` now highlight in both read and edit modes ([#238](https://github.com/pluk-inc/markdown-preview/pull/238)).

### Changed

- **Tab and Shift-Tab now indent and outdent Markdown lists.** List items can be nested to any depth directly from edit mode, while Tab still inserts a tab in ordinary text and avoids turning top-level Markdown blocks into code ([#246](https://github.com/pluk-inc/markdown-preview/pull/246), [#243](https://github.com/pluk-inc/markdown-preview/issues/243)).

### Fixed

- **Links and images can navigate to parent folders.** Relative paths such as `../notes.md` and `../images/diagram.png` now resolve correctly in both the app and Quick Look ([#242](https://github.com/pluk-inc/markdown-preview/pull/242)).

### Contributors

Thanks to the external contributors and reporter who helped improve this release:

- [@kwokpia](https://github.com/kwokpia) — added separate windows for Mermaid diagrams ([#237](https://github.com/pluk-inc/markdown-preview/pull/237))
- [@eshack94](https://github.com/eshack94) — added HCL and Terraform syntax highlighting ([#238](https://github.com/pluk-inc/markdown-preview/pull/238))
- [@jurajpiar](https://github.com/jurajpiar) — fixed navigation to files in parent folders ([#242](https://github.com/pluk-inc/markdown-preview/pull/242))
- [@leo-fengchao](https://github.com/leo-fengchao) — requested Tab and Shift-Tab list indentation ([#243](https://github.com/pluk-inc/markdown-preview/issues/243))

## [0.0.41] – 2026-07-26

Documents can now leave the app: export to PDF, self-contained HTML, or a single tall PNG.

### Added

- **Export documents as PDF, HTML, or PNG.** File ▸ Export… and File ▸ Export as PDF… open the system print panel, with page thumbnails as the preview and a "Markdown Preview" pane for the options — including a printed font size, in real points, shared with Print…. HTML is self-contained (math, diagrams, and highlighting inlined) and PNG is one continuous 2× image of the whole document. Both commands are also available as toolbar items in Customize Toolbar ([#239](https://github.com/pluk-inc/markdown-preview/pull/239)).

### Fixed

- **Printing and exporting from a dark-mode window now produces a light document.** Exports previously came out white-on-black; they also drop copy-code buttons and search highlights, and no longer split code blocks, tables, quotes, or alerts across pages ([#239](https://github.com/pluk-inc/markdown-preview/pull/239)).

## [0.0.40] – 2026-07-22

Scrollable previews get their scrollbar back, and the keyboard shortcuts no longer fight with macOS system shortcuts.

### Changed

- **Keyboard shortcuts realigned to macOS standards.** Inline Code moves to `⇧⌘M` (its old `⌘\`` shadowed the system's cycle-through-windows shortcut, leaving window cycling broken in one direction), Heading 1/2/3 move to `⌥⌘1/2/3` (the old `⇧⌘3` was swallowed by the system screenshot shortcut) with `⌥⌘0` for Body, and the Hide Sidebar / TOC / Project Navigator toggles move to `⌃⌘1/2/3` ([#233](https://github.com/pluk-inc/markdown-preview/pull/233), [#231](https://github.com/pluk-inc/markdown-preview/issues/231)).

### Fixed

- **The page scrollbar is back.** Scrollable previews once again show the native macOS overlay scrollbar at the window edge, in both the app and Quick Look, after a regression removed the scroll indicator ([#228](https://github.com/pluk-inc/markdown-preview/pull/228)).

### Contributors

Thanks to the external reporter who helped improve this release:

- [@query](https://github.com/query) — reported the `⌘\`` shortcut conflict with window switching ([#231](https://github.com/pluk-inc/markdown-preview/issues/231))

## [0.0.39] – 2026-07-21

Editing large documents just got dramatically cheaper: the preview now updates in place instead of rebuilding from scratch, Quick Look shows your text before it loads diagram machinery, YAML frontmatter renders as a proper panel, and standard LaTeX math delimiters are supported.

### Added

- **YAML frontmatter renders in document previews.** Documents that start with a frontmatter block now show it as a formatted panel instead of raw text ([#219](https://github.com/pluk-inc/markdown-preview/pull/219), [#217](https://github.com/pluk-inc/markdown-preview/issues/217)).
- **Standard LaTeX math delimiters are supported.** Math written as `\(...\)` and `\[...\]` — including Markdown-escaped forms — now renders alongside the existing `$...$` and `$$...$$` syntax ([#224](https://github.com/pluk-inc/markdown-preview/pull/224), [#226](https://github.com/pluk-inc/markdown-preview/pull/226), [#222](https://github.com/pluk-inc/markdown-preview/issues/222)).
- **A CPU/memory benchmark harness for contributors.** `scripts/bench/` measures first paint, update times, and per-process RSS/CPU for the app and Quick Look, with a new Mermaid-heavy stress sample; it produced the numbers below ([#223](https://github.com/pluk-inc/markdown-preview/pull/223)).

### Changed

- **Preview updates are now incremental, cutting WebKit CPU by 37% and memory by 16% during editing.** Instead of rebuilding the whole page, updates DOM-diff it (via morphdom, the engine behind Phoenix LiveView), so finished Mermaid diagrams, KaTeX math, and highlighted code are left untouched when unrelated text changes — and scroll position and `<details>` open state survive. Measured while editing a 10-diagram document: WebKit process CPU fell 4.1% → 2.6% and memory 553 → 462 MB mean (568 → 498 MB peak) versus the previous full-rebuild path ([#214](https://github.com/pluk-inc/markdown-preview/pull/214), [#225](https://github.com/pluk-inc/markdown-preview/pull/225)).
- **Quick Look shows your text before loading diagram machinery.** Previews paint the document text first and then light up Mermaid, math, and code highlighting, instead of stalling behind the 3.16 MB Mermaid bundle in documents that use diagrams ([#213](https://github.com/pluk-inc/markdown-preview/pull/213)).

### Fixed

- **Files opened from Finder no longer trigger a file-selection dialog.** Double-clicking a Markdown file opens it directly ([#220](https://github.com/pluk-inc/markdown-preview/pull/220), [#216](https://github.com/pluk-inc/markdown-preview/issues/216)).
- **Vertical spacing between blocks is consistent again.** Paragraphs, lists, and headings no longer show irregular gaps in read mode ([#221](https://github.com/pluk-inc/markdown-preview/pull/221), [#211](https://github.com/pluk-inc/markdown-preview/issues/211)).

### Contributors

Thanks to the external reporters who helped improve this release:

- [@mite404](https://github.com/mite404) — requested YAML frontmatter display ([#217](https://github.com/pluk-inc/markdown-preview/issues/217))
- [@gabrielwhite](https://github.com/gabrielwhite) — reported the Finder file-dialog issue ([#216](https://github.com/pluk-inc/markdown-preview/issues/216))
- [@gafiegarcia](https://github.com/gafiegarcia) — reported the irregular vertical spacing ([#211](https://github.com/pluk-inc/markdown-preview/issues/211))
- [@Lowerce](https://github.com/Lowerce) — reported the LaTeX math delimiter gaps ([#222](https://github.com/pluk-inc/markdown-preview/issues/222))

## [0.0.38] – 2026-07-19

Markdown Preview now speaks Simplified Chinese, and shell code blocks look the same in read mode as they do in the editor.

### Added

- **Simplified Chinese localization.** The menu bar, toolbar, sidebar, inspector, and dynamic prompts are now localized to Simplified Chinese, following the system language or a per-app override in System Settings ([#204](https://github.com/pluk-inc/markdown-preview/pull/204)).

### Fixed

- **Shell options highlight correctly in read mode.** Code fences tagged `shell`, `sh`, `zsh`, or `console` now use the same Bash grammar as edit mode, so options like `--check` and `-q` keep their styling instead of rendering as plain text ([#209](https://github.com/pluk-inc/markdown-preview/pull/209), [#205](https://github.com/pluk-inc/markdown-preview/issues/205)).

### Contributors

Thanks to the external contributors and reporters who helped improve this release:

- [@eachann1024](https://github.com/eachann1024) — added Simplified Chinese localization ([#204](https://github.com/pluk-inc/markdown-preview/pull/204))
- [@CreepsoOff](https://github.com/CreepsoOff) — reported the shell option highlighting issue ([#205](https://github.com/pluk-inc/markdown-preview/issues/205))

## [0.0.37] – 2026-07-18

Markdown Preview now keeps long documents sharp, makes section links and navigation history more reliable, and improves handoff to AI apps and Homebrew-installed command-line tools.

### Added

- **The command-line launcher is bundled for Homebrew integration.** The app now includes its launcher at a stable path so Homebrew can expose `mdp`, `md-preview`, and `markdown-preview` without a separate in-app installation step ([#202](https://github.com/pluk-inc/markdown-preview/pull/202), [#200](https://github.com/pluk-inc/markdown-preview/issues/200)).

### Changed

- **AI apps appear first in the Open menu.** When no preference has been saved, the first installed AI app becomes the default handoff while external editors remain available in the same menu ([#207](https://github.com/pluk-inc/markdown-preview/pull/207)).

### Fixed

- **Section links and navigation history now preserve your place.** Links to headings work within and across documents, and Back and Forward restore the previous scroll position instead of reopening at the top ([#206](https://github.com/pluk-inc/markdown-preview/pull/206)).
- **Long documents stay sharp on Retina displays.** Very large Markdown files now remain at native display resolution while scrolling ([#203](https://github.com/pluk-inc/markdown-preview/pull/203)).
- **Closing a preview while assets load no longer crashes.** Cancelled image and other local-asset requests now stop cleanly when a document closes or is replaced ([#199](https://github.com/pluk-inc/markdown-preview/pull/199)).
- **Opening the editor no longer triggers a layout crash.** Switching from the rendered preview into edit mode now avoids recursive AppKit layout ([#201](https://github.com/pluk-inc/markdown-preview/pull/201)).

### Contributors

Thanks to the external contributors and reporters who helped improve this release:

- [@jurajpiar](https://github.com/jurajpiar) — fixed section links and navigation-history restoration ([#206](https://github.com/pluk-inc/markdown-preview/pull/206))
- [@banteg](https://github.com/banteg) — preserved Retina rendering in long documents ([#203](https://github.com/pluk-inc/markdown-preview/pull/203))
- [@dannydorazio](https://github.com/dannydorazio) — requested the bundled CLI launcher for Homebrew integration ([#200](https://github.com/pluk-inc/markdown-preview/issues/200))

## [0.0.36] – 2026-07-15

Tall Mermaid diagrams can now expand to the full article width, and this release fixes two rendering issues in dark mode and long inline code.

### Added

- **Full-width toggle for Mermaid diagrams.** Tall Mermaid diagrams stay compact and centered by default, with a one-click control beside the zoom HUD to fill the article width and restore the fitted layout ([#195](https://github.com/pluk-inc/markdown-preview/pull/195)).

### Fixed

- **The editing cursor is visible in dark mode.** The insertion point no longer renders black-on-black when editing with the system in dark mode ([#194](https://github.com/pluk-inc/markdown-preview/pull/194)).
- **Long inline code no longer gets clipped.** Long inline code tokens now wrap instead of being cut off at the page edge, keeping every glyph and its background intact ([#193](https://github.com/pluk-inc/markdown-preview/pull/193)).

### Contributors

Thanks to the external contributors who shipped in this release:

- [@defia](https://github.com/defia) — full-width toggle for Mermaid diagrams ([#195](https://github.com/pluk-inc/markdown-preview/pull/195))
- [@ivalkenburg](https://github.com/ivalkenburg) — fixed the black cursor in dark mode ([#194](https://github.com/pluk-inc/markdown-preview/pull/194))
- [@berenar](https://github.com/berenar) — fixed clipping for long inline code ([#193](https://github.com/pluk-inc/markdown-preview/pull/193))

## [0.0.35] – 2026-07-14

Markdown Preview now lets you edit Markdown tables directly in the rendered document, with native controls for managing rows and columns.

### Added

- **Direct table editing.** Edit cells in place, drag to select rectangular ranges, and use native context-menu actions to insert, duplicate, select, or delete rows and columns, with undo support ([#191](https://github.com/pluk-inc/markdown-preview/pull/191)).

### Fixed

- **Printing no longer crashes.** The macOS print sheet now opens reliably without triggering a Swift concurrency executor failure ([#189](https://github.com/pluk-inc/markdown-preview/pull/189)).
- **The default Sidebar control is aligned with the sidebar edge.** New toolbar layouts place the native Sidebar menu beside the sidebar divider while preserving customized toolbars ([#190](https://github.com/pluk-inc/markdown-preview/pull/190)).

## [0.0.34] – 2026-07-13

Markdown Preview now makes linked documents easier to navigate and keeps selections and toolbar customizations consistent across sessions.

### Added

- **Back and forward navigation for Markdown links.** Local Markdown links now open in the same window, with native navigation controls for returning to previously viewed documents ([#184](https://github.com/pluk-inc/markdown-preview/pull/184), [#89](https://github.com/pluk-inc/markdown-preview/issues/89)).

### Fixed

- **Text selection is more reliable and visually consistent.** Full-document selections remain visible while scrolling long files, Shift-selection works correctly in read mode, and edit mode now uses the same macOS blue selection color as the rendered preview ([#185](https://github.com/pluk-inc/markdown-preview/pull/185)).
- **Toolbar customizations persist after relaunch.** Added, removed, and reordered toolbar items are restored the next time Markdown Preview opens ([#187](https://github.com/pluk-inc/markdown-preview/pull/187), [#186](https://github.com/pluk-inc/markdown-preview/issues/186)).

### Contributors

Thanks to the external contributors and reporters who helped improve this release:

- [@jjoanna2-debug](https://github.com/jjoanna2-debug) — improved selection behavior in long documents and read mode ([#185](https://github.com/pluk-inc/markdown-preview/pull/185))
- [@Cuzeth](https://github.com/Cuzeth) — fixed and reported toolbar customization persistence ([#187](https://github.com/pluk-inc/markdown-preview/pull/187), [#186](https://github.com/pluk-inc/markdown-preview/issues/186))
- [@mollydoo](https://github.com/mollydoo) — requested back navigation for linked Markdown documents ([#89](https://github.com/pluk-inc/markdown-preview/issues/89))

## [0.0.33] – 2026-07-12

Markdown Preview now includes a live Markdown editor, so you can write and preview documents without switching apps.

### Added

- **Live Markdown edit mode.** Press ⌘E to switch between the rendered preview and an in-place editor with live preview updates, synchronized scrolling, native formatting controls, and ⌘S saving ([#169](https://github.com/pluk-inc/markdown-preview/pull/169)).
- **Bold and italic Markdown editing.** Bold and italic formatting now preserve Markdown syntax cleanly while editing, including selections and existing formatted text ([#171](https://github.com/pluk-inc/markdown-preview/pull/171)).
- **Privacy-filtered crash reporting.** Native Sentry crash reports now help diagnose release failures without collecting document contents, file paths, user information, breadcrumbs, performance traces, or session data, and can be disabled completely from the app menu.

### Fixed

- **Sidebar resizing is steadier.** The sidebar now keeps its intended width priority during window resizing instead of collapsing unexpectedly ([#177](https://github.com/pluk-inc/markdown-preview/pull/177), [#179](https://github.com/pluk-inc/markdown-preview/pull/179)).

## [0.0.32] – 2026-07-12

Markdown Preview now includes a live Markdown editor, so you can write and preview documents without switching apps.

### Added

- **Live Markdown edit mode.** Press ⌘E to switch between the rendered preview and an in-place editor with live preview updates, synchronized scrolling, native formatting controls, and ⌘S saving ([#169](https://github.com/pluk-inc/markdown-preview/pull/169)).
- **Bold and italic Markdown editing.** Bold and italic formatting now preserve Markdown syntax cleanly while editing, including selections and existing formatted text ([#171](https://github.com/pluk-inc/markdown-preview/pull/171)).

### Fixed

- **Sidebar resizing is steadier.** The sidebar now keeps its intended width priority during window resizing instead of collapsing unexpectedly ([#177](https://github.com/pluk-inc/markdown-preview/pull/177), [#179](https://github.com/pluk-inc/markdown-preview/pull/179)).

## [0.0.31] – 2026-07-08

Opening files now respects the macOS window tabbing preference instead of always gathering documents into tabs.

### Fixed

- **Opening files respects the system tab preference.** Files opened from Finder, File > Open, or recent documents now follow the macOS "Prefer tabs when opening documents" setting instead of always becoming a tab in the frontmost window. Open in New Tab, ⌘T, and the tab bar's "+" button still open tabs explicitly, and windows opened via Open in New Window no longer capture subsequently opened files ([#167](https://github.com/pluk-inc/markdown-preview/pull/167)).

## [0.0.30] – 2026-07-08

Markdown Preview now supports native macOS window tabs and keeps centered previews steadier while sidebars, zoom, and window resizing change the reading layout.

### Added

- **Native window tabs.** Markdown files can now open as native macOS tabs in the frontmost document window, with File > New Tab, the window tab controls, and Project Navigator options for opening files in a new tab or separate window ([#164](https://github.com/pluk-inc/markdown-preview/pull/164)).

### Fixed

- **Centered previews no longer jitter during sidebar changes.** Centered mode now keeps the reading column aligned at the AppKit layout layer, so toggling the sidebar or Table of Contents no longer makes the content shift horizontally ([#163](https://github.com/pluk-inc/markdown-preview/pull/163), [#162](https://github.com/pluk-inc/markdown-preview/issues/162)).
- **Zoom no longer resizes or pins the window.** Centered preview zoom keeps the content width stable without growing the window or blocking narrow window resizing ([#165](https://github.com/pluk-inc/markdown-preview/pull/165)).

### Contributors

Thanks to the external reporter who helped improve this release:

- [@huwan](https://github.com/huwan) — reported centered content jitter when toggling the sidebar and Table of Contents ([#162](https://github.com/pluk-inc/markdown-preview/issues/162))

## [0.0.29] – 2026-07-08

Markdown Preview now gives readers direct control over preview width and zoom gestures, while image rendering and Quick Look asset handling are more reliable.

### Added

- **Content Width setting.** View > Content Width now lets you choose between Centered and Full Width preview layouts, with the selected mode applied to open previews and remembered across launches ([#157](https://github.com/pluk-inc/markdown-preview/pull/157)).
- **Trackpad pinch zoom.** Pinch gestures now zoom the rendered preview directly, matching the existing toolbar and menu zoom controls while keeping the selected zoom level in sync ([#156](https://github.com/pluk-inc/markdown-preview/pull/156)).

### Fixed

- **Explicit image sizes are respected.** Markdown images with width or height attributes now keep those requested dimensions instead of being forced back to the default responsive image sizing ([#158](https://github.com/pluk-inc/markdown-preview/pull/158)).
- **Quick Look image rewrites stay scoped to user content.** Quick Look preview asset rewriting no longer touches generated UI assets, avoiding broken internal preview resources when Markdown files contain local images ([#152](https://github.com/pluk-inc/markdown-preview/pull/152)).

### Contributors

Thanks to the external contributors who shipped in this release:

- [@huwan](https://github.com/huwan) — Content Width setting and explicit image dimension handling ([#157](https://github.com/pluk-inc/markdown-preview/pull/157), [#158](https://github.com/pluk-inc/markdown-preview/pull/158))
- [@jjoanna2-debug](https://github.com/jjoanna2-debug) — trackpad pinch zoom and Quick Look asset containment fixes ([#156](https://github.com/pluk-inc/markdown-preview/pull/156), [#152](https://github.com/pluk-inc/markdown-preview/pull/152))

## [0.0.28] – 2026-06-12

Markdown Preview now has a simpler default Open toolbar action that combines editor and AI app handoffs in one menu.

### Changed

- **Combined Open toolbar action.** The default toolbar now uses one Open button with Editors and AI Apps sections, while the standalone Open With and Open in LLM buttons remain available from toolbar customization ([#150](https://github.com/pluk-inc/markdown-preview/pull/150)).
- **Selected Open target becomes the primary action.** Choosing an editor or AI app promotes that app to the main Open button and keeps the menu checkmark focused on the active default ([#150](https://github.com/pluk-inc/markdown-preview/pull/150)).

### Fixed

- **AI app handoff is more reliable.** ChatGPT now receives Markdown documents through the app's document-open flow, and Claude handoff includes the Markdown content directly instead of depending on an unsupported file parameter ([#150](https://github.com/pluk-inc/markdown-preview/pull/150)).

## [0.0.27] – 2026-06-11

Markdown Preview now includes a native Appearance menu for choosing Automatic, Light, or Dark mode, adds Vim-style preview scrolling, and restores standard blockquote styling.

### Added

- **Appearance menu.** View > Appearance now lets you choose Automatic, Light, or Dark mode, persists the selection, and refreshes open previews so WebView content and Mermaid diagrams follow the selected theme ([#148](https://github.com/pluk-inc/markdown-preview/pull/148), [#115](https://github.com/pluk-inc/markdown-preview/issues/115)).
- **Vim-style preview scrolling.** Pressing `j` and `k` in the rendered preview now scrolls down and up one line in read mode, while focused controls and editable content keep their normal keyboard behavior ([#147](https://github.com/pluk-inc/markdown-preview/pull/147), [#142](https://github.com/pluk-inc/markdown-preview/issues/142)).

### Fixed

- **Regular blockquotes no longer look like code blocks.** Standard Markdown blockquotes now use a left rule and subdued text, keeping them visually distinct from GitHub-style alert callouts and code blocks ([#146](https://github.com/pluk-inc/markdown-preview/pull/146), [#145](https://github.com/pluk-inc/markdown-preview/issues/145)).

### Contributors

Thanks to the external reporters who helped improve this release:

- [@rsalesas](https://github.com/rsalesas) — requested a light/dark appearance setting ([#115](https://github.com/pluk-inc/markdown-preview/issues/115))
- [@rtuszik](https://github.com/rtuszik) — requested `j`/`k` preview scrolling ([#142](https://github.com/pluk-inc/markdown-preview/issues/142))
- [@odrobnik](https://github.com/odrobnik) — reported blockquotes being styled like code blocks ([#145](https://github.com/pluk-inc/markdown-preview/issues/145))

## [0.0.26] – 2026-05-31

Markdown Preview now works more naturally as a multi-window document app, can browse Markdown folders directly, and includes app handoff and command-line installation tools for local workflows.

### Added

- **Native document windows.** Markdown files opened from Finder, File > Open, and Open Recent now use macOS document-window behavior, so multiple Markdown files can stay open as separate windows in one Markdown Preview process ([#131](https://github.com/pluk-inc/markdown-preview/pull/131), [#130](https://github.com/pluk-inc/markdown-preview/issues/130)).
- **Folder opening for Project Navigator.** The open panel can choose a folder as a Markdown workspace, mounting it as the Project Navigator root without eagerly loading every file in the tree ([#135](https://github.com/pluk-inc/markdown-preview/pull/135)).
- **Spacebar page scrolling.** Space and Shift-Space now page down and page up in the rendered preview, matching Preview-style reading behavior while leaving focused controls alone ([#132](https://github.com/pluk-inc/markdown-preview/pull/132), [#129](https://github.com/pluk-inc/markdown-preview/issues/129)).
- **Open in LLM toolbar action.** A toolbar menu can hand the current Markdown file to supported local LLM apps, including Codex, Claude, and ChatGPT, when they are installed ([#136](https://github.com/pluk-inc/markdown-preview/pull/136), [#140](https://github.com/pluk-inc/markdown-preview/pull/140)).
- **Command-line tool installer.** The app menu now includes an Install CLI command that installs `md-preview`, `mdp`, and `markdown-preview` launchers into a usable PATH directory ([#139](https://github.com/pluk-inc/markdown-preview/pull/139)).

### Contributors

Thanks to the external reporters who helped improve this release:

- [@tututuhehehe](https://github.com/tututuhehehe) — requested multiple document window support ([#130](https://github.com/pluk-inc/markdown-preview/issues/130))
- [@Ptujec](https://github.com/Ptujec) — requested Space and Shift-Space preview scrolling ([#129](https://github.com/pluk-inc/markdown-preview/issues/129))

## [0.0.25] – 2026-05-21

Markdown Preview now handles common editor save workflows more reliably, strips TOML frontmatter before rendering, and keeps code-copy output clean when selecting the whole preview.

### Changed

- **The preview keeps following the original file after atomic saves.** When editors save by replacing the file behind the scenes, Markdown Preview now reloads the new contents while staying attached to the original path instead of following the temporary replacement file ([#126](https://github.com/pluk-inc/markdown-preview/pull/126), [#119](https://github.com/pluk-inc/markdown-preview/issues/119)).

### Fixed

- **TOML frontmatter is hidden from rendered previews.** Files that start with `+++` frontmatter now render like YAML-frontmatter files, keeping metadata out of the preview body ([#125](https://github.com/pluk-inc/markdown-preview/pull/125), [#118](https://github.com/pluk-inc/markdown-preview/issues/118)).
- **Code copy buttons no longer leak into copied text.** Selecting the whole preview and copying now excludes the inline "Copy" / "Copied" button label from code block clipboard output ([#124](https://github.com/pluk-inc/markdown-preview/pull/124), [#120](https://github.com/pluk-inc/markdown-preview/issues/120)).

### Contributors

Thanks to the external reporters who helped improve this release:

- [@gglanzani](https://github.com/gglanzani) — reported TOML frontmatter rendering and atomic-save reload issues ([#118](https://github.com/pluk-inc/markdown-preview/issues/118), [#119](https://github.com/pluk-inc/markdown-preview/issues/119))
- [@OzzyCzech](https://github.com/OzzyCzech) — reported copy button text leaking into selected code copy output ([#120](https://github.com/pluk-inc/markdown-preview/issues/120))

## [0.0.24] – 2026-05-19

GitHub-style alert blockquotes now render with their intended labels, and the Open With menu finds more Markdown editors.

### Added

- **GitHub-style alert blockquotes render with labels and colors.** Blockquotes that start with `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, or `[!CAUTION]` now render as alert callouts, including custom titles after the marker ([#113](https://github.com/pluk-inc/markdown-preview/pull/113)).

### Fixed

- **More Markdown editors appear in Open With.** Trusted Markdown-first editors such as iA Writer, Typora, MacDown, and Obsidian are now included even when Launch Services exposes them through custom Markdown UTIs, while noisy non-editors are filtered out ([#116](https://github.com/pluk-inc/markdown-preview/pull/116), [#114](https://github.com/pluk-inc/markdown-preview/issues/114)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@jphastings](https://github.com/jphastings) — GitHub-style alert blockquotes ([#113](https://github.com/pluk-inc/markdown-preview/pull/113))

## [0.0.23] – 2026-05-18

Fenced code blocks that carry extra metadata after the language now render the way they should.

### Fixed

- **Fenced code blocks with info-string metadata render correctly.** Only the first word of a fenced code block's info string is treated as the language, so blocks like ` ```mermaid {theme=dark} ` or ` ```swift title="example.swift" ` are recognized properly and Mermaid diagrams and math decorators are no longer broken by trailing metadata ([#109](https://github.com/pluk-inc/markdown-preview/pull/109)).

### Contributors

Thanks to the external contributors who shipped in this release:

- [@jphastings](https://github.com/jphastings) — fenced code block info-string language handling ([#109](https://github.com/pluk-inc/markdown-preview/pull/109))

## [0.0.22] – 2026-05-14

Markdown Preview now sanitizes rendered HTML before it reaches the preview WebView, and Sparkle update checks point at the Amore-published appcast.

### Changed

- **Amore sponsor credit added.** The README now lists Amore among the project sponsors ([#105](https://github.com/pluk-inc/markdown-preview/pull/105)).

### Fixed

- **Sparkle feed URL now matches Amore hosting.** Update checks now use the Amore appcast path at `https://release.md-preview.app/v1/apps/doc.md-preview/appcast.xml`, so installed copies look at the feed that Amore publishes.

### Security

- **Rendered Markdown HTML is sanitized with DOMPurify.** The app and Quick Look extension now route generated article HTML through DOMPurify before inserting it into the WebView, blocking inline event handlers, executable tags, dangerous URL schemes, hidden style-based copy substitutions, and related raw-HTML injection attacks while preserving Markdown rendering, KaTeX, Mermaid, highlight.js, local images, links, task lists, footnotes, code copy buttons, find, scrollspy, and heading IDs ([#104](https://github.com/pluk-inc/markdown-preview/pull/104)).

### Contributors

Thanks to the external contributors who shipped in this release:

- [@luuccaaaa](https://github.com/luuccaaaa) — rendered Markdown HTML sanitization with DOMPurify ([#104](https://github.com/pluk-inc/markdown-preview/pull/104))
- [@lucasfischer](https://github.com/lucasfischer) — Amore sponsor credit ([#105](https://github.com/pluk-inc/markdown-preview/pull/105))

## [0.0.21] – 2026-05-11

The table of contents now follows your reading position, the Project Navigator reacts to folder changes, and code blocks are easier to copy.

### Added

- **Table of contents scrollspy.** The outline highlights the heading currently in view while you scroll, keeps click-selected headings stable, and resumes tracking naturally on the next scroll ([#101](https://github.com/pluk-inc/markdown-preview/pull/101)).
- **Live Project Navigator updates.** The navigator watches visible folders for Markdown file additions, renames, and deletes, updating the sidebar without reopening the document ([#101](https://github.com/pluk-inc/markdown-preview/pull/101)).
- **Copy buttons for code blocks.** Fenced code blocks now expose a hover-revealed Copy button that stays pinned while horizontally scrolling long snippets, writes through the native pasteboard bridge, and provides accessible copied-state feedback ([#102](https://github.com/pluk-inc/markdown-preview/pull/102)).

### Fixed

- **Project Navigator root stays stable.** Opening a deeper file from the navigator no longer narrows the root folder unexpectedly; opening an unrelated file still resets the navigator to the new folder ([#101](https://github.com/pluk-inc/markdown-preview/pull/101)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@luuccaaaa](https://github.com/luuccaaaa) — table of contents scrollspy, live Project Navigator updates, and stable navigator roots ([#101](https://github.com/pluk-inc/markdown-preview/pull/101))

## [0.0.20] – 2026-05-09

The sidebar toolbar menu now stays responsive and shows the correct selected mode after toolbar customization.

### Fixed

- **Sidebar mode menu survives toolbar customization.** The toolbar's Sidebar pull-down no longer lets Customize Toolbar palette copies steal the live menu reference, so Table of Contents and Project Navigator keep responding and their checkmarks stay in sync after closing the native customization sheet.

## [0.0.19] – 2026-05-09

Syntax highlighting is back without the Shiki startup cost, the sidebar can browse sibling Markdown files, and preview reading controls are easier to reach.

### Added

- **Project Navigator sidebar mode.** The sidebar picker now switches between Hide, Table of Contents, and Project Navigator; the navigator lazily browses sibling Markdown files in the current folder and includes contextual actions for opening, revealing, copying paths, and copying file contents ([#93](https://github.com/pluk-inc/md-preview.app/pull/93)).
- **Preview zoom controls.** A default toolbar zoom group and View-menu shortcuts (`⌘+`, `⌘-`, `⌘0`) resize the rendered preview from 50% to 300%, remember the chosen scale across launches, and use `WKWebView.pageZoom` so text, math, diagrams, and code scale together ([#96](https://github.com/pluk-inc/md-preview.app/pull/96), [#97](https://github.com/pluk-inc/md-preview.app/pull/97)).
- **Customizable Print and Copy toolbar items.** Print and Copy are available from View → Customize Toolbar, with Copy placing the current Markdown source on the clipboard and briefly swapping its icon on success ([#96](https://github.com/pluk-inc/md-preview.app/pull/96)).
- **Syntax highlighting returns via highlight.js.** Fenced code blocks are colored again in the app and Quick Look using a bundled highlight.js common-languages build, lazy-loaded after first paint and re-applied on fast-path document swaps so initial preview rendering stays responsive ([#90](https://github.com/pluk-inc/md-preview.app/pull/90)).

### Changed

- **Markdown rendering now runs off the main actor.** Pure Markdown-to-HTML work moved to background tasks with generation checks so large files and rapid file switches do not stall the UI or let stale renders overwrite newer content ([#95](https://github.com/pluk-inc/md-preview.app/pull/95)).
- **Sandbox folder access is simpler.** The app now uses the same read-only absolute-path temporary exception pattern as the Quick Look extension, removing the folder-access banner and bookmark-management flow while keeping writes behind the existing sandbox save path ([#93](https://github.com/pluk-inc/md-preview.app/pull/93)).

### Fixed

- **Launch warmup no longer flashes synthetic content.** The hidden warmup document still primes KaTeX, Mermaid, and highlight.js, but the synthetic Mermaid diagram cannot briefly appear before the first real document renders ([#94](https://github.com/pluk-inc/md-preview.app/pull/94)).
- **Zoom toolbar tooltips are reliable.** The toolbar group and its Zoom In / Zoom Out subitems now expose tooltip metadata at the toolbar-item level as well as on the segmented control ([#98](https://github.com/pluk-inc/md-preview.app/pull/98)).
- **TOC title alignment is flush again.** The table-of-contents title row no longer carries the extra leading inset that made it sit out of alignment with the rest of the sidebar ([#98](https://github.com/pluk-inc/md-preview.app/pull/98)).

### Contributors

Thanks to the external contributors who reported issues fixed in this release:

- [@amiramir](https://github.com/amiramir) — reported the preview zoom request ([#91](https://github.com/pluk-inc/md-preview.app/issues/91))
- [@MyCometG3](https://github.com/MyCometG3) — reported keyboard navigation improvements covered by the new scroll actions ([#92](https://github.com/pluk-inc/md-preview.app/issues/92))

## [0.0.18] – 2026-05-07

A faster cold launch, snappier file switches, and a temporary step back on syntax highlighting while a non-blocking solution is built.

### Added

- **Vendor JS warms up at launch.** A synthetic markdown doc renders into the WebView while the open panel is still on screen, so KaTeX and Mermaid finish parsing before the user picks a file. By the time the picked file lands, the renderers are already ready ([#84](https://github.com/pluk-inc/md-preview.app/pull/84)).

### Changed

- **Cold-open of a 4 KB markdown file dropped from ~400 ms to ~50 ms (5–8× faster perceived load).** Vendor JS used to be inlined in the HTML head, blocking the parser on every load. It now lazy-loads after first paint via the `md-asset:` scheme, so the article is visible before the bundles finish downloading. The asset-scheme handler caches vendor blobs in `NSCache` and resolves `__vendor/<file>` paths from the app bundle independently of the user-file base URL. Quick Look continues to use inline delivery because its `QLPreviewReply` payload model bundles HTML and attachments differently ([#84](https://github.com/pluk-inc/md-preview.app/pull/84)).
- **Switching files takes a fast path instead of a full WebView reload.** When the renderer mix matches what's already loaded, the article body is swapped in place via `MdPreview.update(articleHTML)` and each renderer's idempotent reapplier re-runs — no `loadHTMLString` reload, no vendor re-parse. A `RendererFingerprint.covers(_:)` check lets any subset of renderers fast-path into the all-true warmup state ([#84](https://github.com/pluk-inc/md-preview.app/pull/84)).
- **Stale content clears while sheets are dismissing.** Opening a new file now blanks the preview during sheet dismissal so the previous doc doesn't linger behind the open panel ([#84](https://github.com/pluk-inc/md-preview.app/pull/84)).

### Removed

- **Syntax highlighting (Shiki) removed for now.** Shiki was pinning the JS thread for ~1 s on a code block's first cold grammar compile (TypeScript was the worst offender), even after launch warmup, idle-defer, per-block IntersectionObserver, and post-paint background grammar warmups. The cost is inherent to TextMate-grammar regex compilation on the main thread, so the only viable fix is moving Shiki into a Web Worker, which warrants its own release. Code blocks now render with the existing monospace + rounded grey background, just without per-token color. The 2.5 MB `shiki.bundle.js` is no longer shipped in the app bundle.

## [0.0.17] – 2026-05-07

Two macOS 26 fixes — the window opens at full size again, and inline math renders correctly in RTL paragraphs.

### Fixed

- **Window no longer launches collapsed on macOS 26.** The find bar's bottom rule (an `NSBox` with `boxType = .separator`) inside a bottom `NSTitlebarAccessoryViewController` was triggering an AppKit layout regression that bypassed the window's `contentMinSize` and snapped the window to the toolbar's natural minimum width (~169 pt) on launch. Only vertical resizing worked, and toggling the sidebar made the window disappear. Replaced the find-bar separator and the access banner's separators with a 1 pt `NSView` filled with `NSColor.separatorColor` — same look, no regression ([#79](https://github.com/pluk-inc/md-preview.app/issues/79), [#81](https://github.com/pluk-inc/md-preview.app/pull/81)).
- **Inline KaTeX math stays LTR inside RTL paragraphs.** Math embedded in Hebrew / Arabic paragraphs was inheriting the surrounding RTL direction and rendering reversed (e.g. `$f(x)=x^2$` came out as `f(x) = ^2x`). The Markdown stylesheet now pins `.katex` to `direction: ltr` with `unicode-bidi: isolate`, so math renders LTR while the surrounding RTL text continues to flow right-to-left ([#76](https://github.com/pluk-inc/md-preview.app/pull/76)).

### Contributors

Thanks to the external contributors who shipped in this release:

- [@manemajef](https://github.com/manemajef) — inline KaTeX math direction fix in RTL paragraphs ([#76](https://github.com/pluk-inc/md-preview.app/pull/76))
- [@pryley](https://github.com/pryley) — reported the window-collapse bug on macOS 26 ([#79](https://github.com/pluk-inc/md-preview.app/issues/79))

## [0.0.16] – 2026-05-07

Mermaid diagrams you can pan and zoom, faster live-preview saves, and a polished find bar and sidebar.

### Added

- **Mermaid pan and zoom.** `⌘`+wheel or pinch zooms toward the cursor, drag pans at any zoom, and double-click toggles between 2× and fit. A hover HUD exposes `−` / `100%` / `+` controls, the diagram auto-recenters when you zoom back to 100%, and 100% is the floor (no shrinking below). Plain wheel still scrolls the page, so there's no scroll-jacking ([#62](https://github.com/pluk-inc/md-preview.app/pull/62)).
- **`Match:` label with toggle buttons in the find bar.** The Contains / Begins With picker switched from a segmented control to two `NSButton` toggles fronted by a `Match:` label, matching macOS Preview's accessibility shape (`AXToggle` subrole). Re-clicking the active mode is a no-op so it doesn't trigger a redundant search ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).
- **Hard scroll-edge effect under the find bar on macOS 26.1+.** The find-bar titlebar accessory opts into `preferredScrollEdgeEffectStyle = .hard`, giving it an opaque, sharp boundary against scrolling content. macOS 15 and 26.0 keep their existing look ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).
- **Sidebar file name scrolls with the outline.** The file name moved out of a sticky header into the outline view itself as a non-selectable first row, so it scrolls away alongside the TOC instead of pinning to the top ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).

### Changed

- **Saves no longer reload the whole preview.** When the page is already loaded and the renderer mix (math / Mermaid / Shiki) hasn't changed, the article body is swapped via `evaluateJavaScript` and each renderer's idempotent reapplier re-runs in place — saves no longer reparse the 3 MB Mermaid bundle and 2.5 MB Shiki bundle. First load and renderer-mix changes still do a full HTML load, and `<base href="md-asset:///">` ships unconditionally so asset swaps don't force a reload ([#62](https://github.com/pluk-inc/md-preview.app/pull/62)).
- **Mermaid diagrams render lazily with reserved layout space.** Each figure renders on intersection via `IntersectionObserver` instead of one big `mermaid.run`, and reserves space using `aspect-ratio` from its viewBox so the document height stops bouncing as diagrams stream in. `contain: strict` on the zoom stage isolates layout and paint ([#62](https://github.com/pluk-inc/md-preview.app/pull/62)).
- **Web view height is now push-based.** A new `mdPreviewHost` script-message handler pushes content height from JS via `ResizeObserver` plus per-renderer done events, replacing the staggered Mermaid (`[0.6, 1.2, 2.4]s`), KaTeX / Shiki (`[0.15, 0.4, 0.9]s`), and inner-cascade polls. Height updates arrive exactly when layout changes ([#62](https://github.com/pluk-inc/md-preview.app/pull/62)).
- **Re-displaying the same file is a no-op in the sidebar.** When the file watcher fires with identical markdown and file name, the sidebar skips the parse + reload + re-expand cycle, preserving expansion state without flicker ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).

### Fixed

- **Native overlay scrollbar restored when scrolling is allowed.** Dropped a redundant `::-webkit-scrollbar { display: initial !important; … }` rule that was overriding the macOS overlay scrollbar; WebKit now falls back to the system scrollbar ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@hailam](https://github.com/hailam) — Mermaid pan/zoom, lazy rendering, push-based height, and reload-free saves ([#62](https://github.com/pluk-inc/md-preview.app/pull/62))

## [0.0.15] – 2026-05-06

A proper find bar and right-to-left text support.

### Added

- **Find bar with match navigation, modes, and a burst highlight.** Searching now opens a slim bar below the toolbar with an `X of N` counter, prev/next chevrons, a Done button, and a Contains / Begins With mode toggle. Enter and Shift+Enter cycle forward and backward through matches (the original ask in [#72](https://github.com/pluk-inc/md-preview.app/issues/72)), and the current match scale-pulses with a yellow pill so it's easy to spot after a long scroll. The find pass skips scrolling when the match is already on screen, debounces keystrokes, gates Begins-With on the preceding character, and filters hidden subtrees so KaTeX MathML mirrors and Mermaid source nodes don't show up as phantom matches ([#73](https://github.com/pluk-inc/md-preview.app/pull/73)).
- **Automatic RTL text direction.** Paragraphs, list items, and headings whose first strong character is from an RTL script (Hebrew, Arabic, Syriac, etc.) now render with `dir="rtl"` and right alignment. Detection looks through inline markup (so `**שלום**` works), skips neutral characters like parentheses and punctuation, preserves any existing `dir` attribute, and leaves LTR-only documents unchanged ([#67](https://github.com/pluk-inc/md-preview.app/pull/67)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@manemajef](https://github.com/manemajef) — automatic RTL text direction support ([#67](https://github.com/pluk-inc/md-preview.app/pull/67))

## [0.0.14] – 2026-05-06

Quick Look now renders relative images.

### Added

- **Relative images render in Quick Look previews.** When a Markdown file references sibling assets like `![](images/local.png)`, the Quick Look extension now inlines each readable sibling as a `cid:` attachment on the preview reply and rewrites the `<img src>` to match, so local images appear in Finder/Spotlight previews instead of as broken-image glyphs. The extension gained a read-only `temporary-exception.files.absolute-path.read-only` entitlement so the sandboxed preview process can read sibling files (the main app already handles this through its `md-asset://` scheme). Per-image and cumulative byte budgets cap pathological folders; absolute URLs, fragment refs, host-absolute paths, and unreadable files pass through untouched ([#68](https://github.com/pluk-inc/md-preview.app/pull/68)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@DivineDominion](https://github.com/DivineDominion) — relative images in Quick Look previews ([#68](https://github.com/pluk-inc/md-preview.app/pull/68))

## [0.0.13] – 2026-05-05

Native printing, plus two rendering fixes.

### Added

- **Print the rendered Markdown.** File → Print (⌘P) now prints the previewed document through WKWebView with horizontal fit pagination, instead of falling through to AppKit's generic `print:` and printing the sidebar and window chrome. The app gained the `com.apple.security.print` entitlement so this works in the sandbox.

### Fixed

- **GFM task lists render inline without a duplicate bullet.** Task list items were drawing both a list marker and a checkbox with the label wrapping to a new line below. Task `<li>`s and their checkboxes are now tagged with GitHub's `task-list-item` / `task-list-item-checkbox` class names, so CSS suppresses the marker and the first paragraph stays inline next to the checkbox ([#63](https://github.com/pluk-inc/md-preview.app/issues/63)).
- **No placeholder content on launch.** Removed the leftover "WKWebView pipeline is live" sample that the split view rendered at startup, so the app opens with an empty preview area until you load a document.

## [0.0.12] – 2026-05-05

Code highlighting, richer Markdown heading and footnote rendering, and README sponsor updates.

### Added

- **Code blocks now use Shiki syntax highlighting.** Fenced code blocks render with bundled Shiki highlighting in both the app and Quick Look, so previews show language-aware colors without needing network access.

### Fixed

- **Footnotes now render correctly.** Markdown footnote definitions and references are collected, linked, and rendered as a proper footnotes section instead of appearing as plain paragraph content.
- **Inline markup works inside headings.** Emphasis, links, code spans, and other inline Markdown now render correctly inside heading text while keeping generated heading anchors stable.

## [0.0.11] – 2026-05-04

Homebrew install path and stronger default-handler claims for Markdown files.

### Added

- **Install via Homebrew.** `brew install --cask pluk-inc/tap/markdown-preview` is now the primary install method; the DMG remains as a fallback. The release script auto-bumps the [pluk-inc/homebrew-tap](https://github.com/pluk-inc/homebrew-tap) cask (version + sha256) after each successful `amore release`, so brew users pick up new versions on the same cadence as direct downloads.

### Fixed

- **Markdown Preview now wins as the default `.md` handler on more setups.** `LSHandlerRank` for the standard markdown UTI was promoted from `Default` to `Owner`, so LaunchServices prefers Markdown Preview over apps that only assert a weaker claim. Users who previously had to set "Always Open With" by hand should pick the app up automatically after a fresh install.
- **Long-tail markdown extensions are now claimed uncontested.** `.mdown`, `.mkd`, `.mkdn`, `.mdwn`, `.mdtxt`, and `.mdtext` are exported under app-private UTIs (`doc.md-preview.*`) that conform to `net.daringfireball.markdown`. Because no other app declares UTIs in that namespace, LaunchServices has no competing candidate for these files and Markdown Preview opens them without requiring user intervention.

## [0.0.10] – 2026-05-04

LaTeX math rendering, broader Markdown file-format support, and a rendering fix for inline HTML in body text and code.

### Added

- **LaTeX math now renders via KaTeX.** Inline math (`$…$`, `\(…\)`) and display math (`$$…$$`, `\[…\]`) are typeset on load in both the app and the Quick Look extension. KaTeX ships inside the bundle, so previews work offline.
- **More Markdown file types open natively.** Added `.mkd`, `.mkdn`, `.mdwn`, `.mdtxt`, `.mdtext`, and `.rmd` alongside the existing `.md` / `.markdown` / `.mdown` / `.txt`. Quick Look and the Open With list pick the app up for these extensions too.

### Fixed

- **Math extraction skips code spans and fences.** Dollar signs and `\(…\)` sequences inside backticks or fenced code blocks are no longer mistaken for math, so snippets like `` `$PATH` `` and code samples render verbatim instead of being eaten by the math pass.
- **HTML in body text and code is now properly escaped.** `a < b`, `Tom & Jerry`, `` `<div>` ``, and fenced code containing `<`, `>`, or `&` previously rendered mangled or vanished entirely because swift-markdown's default `HTMLFormatter` doesn't escape those characters in text or code. A new `EscapingHTMLFormatter` walker handles escaping while still passing raw HTML blocks through verbatim per CommonMark.

### Contributors

Thanks to the external contributors who shipped in this release:

- [@dppeak](https://github.com/dppeak) — broader Markdown file-format support ([#31](https://github.com/pluk-inc/md-preview.app/pull/31))
- [@yaksher](https://github.com/yaksher) — reported the HTML-escape bug fixed in [#35](https://github.com/pluk-inc/md-preview.app/pull/35) ([#33](https://github.com/pluk-inc/md-preview.app/issues/33))

## [0.0.9] – 2026-05-03

Mermaid diagram rendering in the app and Quick Look.

- **Fenced `mermaid` code blocks now render as diagrams.** The Markdown pipeline detects `mermaid` fences, swaps them for diagram containers, and runs the Mermaid renderer on load — flowcharts, sequence diagrams, class diagrams, and the rest show up inline instead of as raw code.
- **Renderer is bundled, so previews work offline.** The Mermaid script ships inside the app bundle and is shared with the Quick Look extension; no CDN request is made when opening a document.
- **Diagrams follow the system appearance.** Mermaid initializes with the dark theme when the system is in dark mode and the default theme otherwise, and uses the SF system font so labels match the surrounding text.

## [0.0.8] – 2026-05-03

Tabbed Inspector with native segmented picker.

- **Inspector now has Document and Properties tabs.** A native segmented picker with SF Symbol icons (doc / info) splits the panel into a Document tab for file and content stats and a Properties tab for YAML frontmatter, instead of stacking everything in one scrolling list.
- **Empty Properties tab shows a placeholder.** Documents without frontmatter now display "No YAML frontmatter" filling the available space, so the tab doesn't collapse to nothing.
- **Picker matches Apple's pill-style segmented look on macOS 26 Tahoe.** Uses `.controlSize(.large)` plus `.buttonSizing(.flexible)` on Tahoe and falls back to `.fixedSize()` on macOS 15 Sequoia.

## [0.0.7] – 2026-05-03

YAML frontmatter rendering fix and Inspector metadata.

- **YAML frontmatter no longer collapses into a giant heading.** The CommonMark renderer was treating the closing `---` of a frontmatter block as a setext heading underline, turning `title:` / `date:` / `tags:` into one oversized H2 at the top of the document. The block is now stripped before parsing and the preview matches what GitHub, Obsidian, and VS Code show.
- **Frontmatter shows up in the Inspector.** A new **Properties** section at the top of the Inspector lists each key/value pair from the document's frontmatter, so the metadata is one click away even though it's hidden from the rendered preview. The Quick Look extension hides it too.
- **Word, line, and heading counts now reflect body content.** The Inspector's stats no longer include the frontmatter block in their totals.

## [0.0.6] – 2026-05-02

Toolbar, banner, and table-of-contents polish.

- **Search field collapses to a magnifying-glass button in narrow windows.** When the toolbar is too tight to fit the expanded search field, it now folds into an icon-only button matching the rest of the toolbar instead of being clipped.
- **Open With toolbar item shows the resolved editor.** When a default Markdown editor is set, the toolbar item now reads "Open in <Editor>" as both label and tooltip, and the menu lists apps by their Finder display name without the `.app` suffix. The chosen editor's location is also remembered alongside its bundle ID, so launches still resolve when the bundle ID is unavailable.
- **Folder-access banner no longer clips text on macOS 15.** The banner now advertises a fixed height to the titlebar accessory so descenders in the message label aren't cut off, and the redundant top/bottom separators are hidden on macOS 15 (where AppKit already draws system ones).
- **Folder-access banner stays until access is granted.** Removed the dismiss button so the prompt no longer disappears when accidentally clicked — it now goes away only after you grant read access to the folder.
- **TOC clicks scroll headings below the toolbar.** Jumping to a heading from the sidebar now accounts for the toolbar height plus a small breathing margin, so the target heading lands in view instead of behind the toolbar.
- **Share toolbar button is the right size.** The share item no longer renders an oversized icon next to the other toolbar buttons.

## [0.0.5] – 2026-05-02

Small fullscreen polish for the sidebar.

- **Sidebar title sits correctly in fullscreen.** The document title at the top of the table-of-contents pane no longer slides under the toolbar when the window enters fullscreen — it now anchors to the safe-area inset and stays put in both windowed and fullscreen modes.

## [0.0.4] – 2026-05-02

Relative images and links in Markdown files now render in the sandboxed app.

- **Render relative local assets via a folder-access banner.** When a document references images or files alongside it, Markdown Preview now shows an in-window banner offering to grant read access to the parent folder. Once granted, the access is remembered across launches and assets load through a dedicated `md-asset://` scheme so they appear inline in the preview.
- **Stable DMG filename for GitHub releases.** The DMG attached to each GitHub release is now `Markdown-Preview.dmg` without a version suffix, so download links stay valid across versions.

## [0.0.3] – 2026-05-02

Better Markdown rendering and a tidier **Open With** menu.

- **Switched the Markdown engine to swift-markdown (cmark-gfm).** Rendering is now CommonMark- and GitHub-Flavored-Markdown-compliant, so tables, task lists, strikethrough, and autolinks render the way you'd expect on GitHub.
- **Fixed the Open With list.** No more duplicate Markdown Preview entries from old build copies, and unrelated apps that only claim a generic plain-text association no longer show up — only apps that actually edit Markdown are listed.

## [0.0.2] – 2026-05-01

Compatibility release: Markdown Preview now runs on macOS 15 Sequoia in addition to macOS 26 Tahoe.

- **Lowered the minimum macOS version to 15.0 (Sequoia).** Previously required macOS 26 Tahoe.
- **Replaced the app icon with an Icon Composer `.icon` bundle.** Fixes the icon appearing oversized on Sequoia — the system now applies its own mask and the standard safe-area inset.

## [0.0.1] – 2026-04-30

First public build of Markdown Preview — a fast, native macOS reader for `.md` files.

### Highlights

- Native WKWebView rendering with heading anchors and external link handling
- Sidebar table of contents that mirrors document headings (click to jump)
- Toggleable inspector panel with file metadata
- In-document search via the toolbar field plus standard `⌘F` / `⌘G` / `⌘⇧G`
- Open With menu that filters to apps declaring an editor role for Markdown and remembers your pick
- Share menu that copies the Markdown source itself, so Copy / Mail / Notes / Messages get the content instead of a file URL
- Quick Look extension for system-wide `.md` previews from Finder, Spotlight, and Mail
- Offer to register as the default `.md` handler on first launch
- Supports `.md`, `.markdown`, `.mdown`, and `.txt`
