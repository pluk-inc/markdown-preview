---
name: headless-ui-test
description: Run and check the app on a hidden virtual display, so UI checks do not take over the user's screen, mouse, keyboard, or focus. Load when you need screenshots or keyboard input for a runtime check while the user keeps working, or when the user asks for a background, headless, or "fake monitor" UI test.
---

# Headless UI test

The app runs on a virtual display that the user cannot see. You read it with
`screencapture` and drive it with events sent to the app's PID. The user's
cursor, keyboard, frontmost app, and Dock do not change.

`scripts/ui-harness/vdisplay.m` creates the display with the private
`CGVirtualDisplay` API. It is a developer tool only. Never link it into the app
or the Quick Look extension.

## Rules

- **Always open a document in the same `open` call that launches the app.**
  With no document, the app calls `NSApp.activate` and shows the file chooser
  (`scheduleDocumentPrompt` in `AppDelegate.swift`). That steals the user's
  focus, and the chooser takes the key events you send.
- **Use `open -g -n -a`, never plain `open -a`.** `-g` keeps the app in the
  background. `-n` starts your own instance.
- **Work by PID only.** Other sessions run builds with the same bundle id.
  Never use the bundle id or the app name to find, drive, or quit the app.
- **Send input with `postToPid` only.** Never use `CGEvent.post(tap:)`, `cliclick`,
  or System Events `keystroke`/`click at`. They move the user's real cursor or
  type into the user's frontmost app.
- Do not call anything that activates the app (Settings window, table preview
  window, `activate`). If a check needs one of these, tell the user that the
  app will come to the front.

## Steps

Use a scratch folder (`$OUT`) for the binary, the app build, and the
screenshots. Start the app build (step 3) in the background first: steps 1 and
2 do not need it.

1. Build the display tool:

   ```bash
   clang -fobjc-arc -framework Foundation -framework CoreGraphics \
     scripts/ui-harness/vdisplay.m -o "$OUT/vdisplay"
   ```

2. Start the display as a long-running process (in Rex, a split beside your
   block), with its output in a file:

   ```bash
   "$OUT/vdisplay" > "$OUT/vdisplay.txt" 2>&1
   ```

   After about one second the file has one line:
   `pid=48709 displayID=11 index=3 origin=2560,0 size=1440x900`.
   Use `index` for `screencapture -D` and `origin` to place windows. Other
   sessions can run their own display at the same time, so always read these
   values; never assume them. The tool puts the display on the side the Dock
   does not use, and removes it after 600 s (`--timeout` changes this).

3. Build the app into your own folder, then launch your own instance in the
   background with a document. `open` returns before the process exists, so
   wait for the PID:

   ```bash
   xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug \
     -derivedDataPath "$OUT/dd" build -quiet
   APP="$OUT/dd/Build/Products/Debug/Markdown Preview.app"
   open -g -n -a "$APP" /path/to/file.md --args -ApplePersistenceIgnoreState YES
   for i in $(seq 1 50); do PID=$(pgrep -nf "$APP/Contents/MacOS/") && break; sleep 0.1; done
   ```

4. Move the window onto the virtual display, at its `origin` plus a margin
   (here origin 2560,0):

   ```bash
   osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set position of every window to {2660, 60}"
   ```

5. Send keys to the PID. Example: ⌘E (key code 14) toggles Edit mode.

   ```bash
   swift -e "import CoreGraphics
   let src = CGEventSource(stateID: .hidSystemState)
   for down in [true, false] {
     let e = CGEvent(keyboardEventSource: src, virtualKey: 14, keyDown: down)!
     e.flags = .maskCommand
     e.postToPid($PID)
   }"
   ```

   Not tested yet: pressing a menu item through Accessibility (`click menu item
   "Toggle Edit Mode" of menu 1 of menu bar item "View" of menu bar 1` inside the
   same `tell` block) on an app that is not frontmost. Check that focus does not
   change before you rely on it.

6. Capture the display, then read the image:

   ```bash
   screencapture -x -D "$INDEX" -t jpg "$OUT/shot.jpg"
   ```

   The window has the inactive look (gray window buttons, no accent color),
   because the app is not frontmost. Do not report this as a bug.

7. Clean up: `kill $PID <vdisplay pid>`, with the `pid=` value from
   `vdisplay.txt`. Never `pkill vdisplay`: other sessions can run one. Close the
   Rex block.

## Limits

- Keyboard input is tested. Mouse clicks sent with `postToPid` are not tested
  yet. Menus, popovers, sheets, and drags can need an active app. If a check
  needs them, tell the user first.
- The user's cursor can move onto the virtual display past the right edge of
  the main display. It comes back the same way.
- Both `screencapture` and the System Events steps need the Screen Recording and
  Accessibility permissions for the terminal app.
- A macOS update can break the private API. If `vdisplay` prints
  `could not create display`, fall back to a normal on-screen check and tell
  the user.
