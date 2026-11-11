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
   sh -c 'echo $$ > "$0/vdisplay.pid"; exec "$0/vdisplay" > "$0/vdisplay.txt" 2>&1' "$OUT"
   ```

   The file gets one line, usually within a second but later when the system
   is busy, so wait for it:
   `pid=48709 displayID=11 index=3 origin=2560,0 size=1440x900`.

   ```bash
   for i in $(seq 1 100); do grep -qs '^pid=' "$OUT/vdisplay.txt" && break; sleep 0.1; done
   VD_PID=$(cat "$OUT/vdisplay.pid")
   LINE=$(grep '^pid=' "$OUT/vdisplay.txt") || {
     kill "$VD_PID" 2>/dev/null; cat "$OUT/vdisplay.txt" >&2
     echo "no virtual display: stop the check" >&2; exit 1; }
   DISPLAY_ID=$(sed -E 's/.*displayID=([0-9]+).*/\1/' <<<"$LINE")
   ORIGIN_X=$(sed -E 's/.*origin=(-?[0-9]+),.*/\1/' <<<"$LINE")
   ORIGIN_Y=$(sed -E 's/.*origin=-?[0-9]+,(-?[0-9]+).*/\1/' <<<"$LINE")
   ```

   Without the line (a late start or a `vdisplay:` error), the block stops the
   tool, so a late display cannot appear afterwards, and stops the check:
   never move the window without a display, or it stays on the user's screen.
   `DISPLAY_ID` finds the `screencapture -D` number (step 6), and the origin
   places windows. Other sessions can run their own display at the same time,
   so always read these values; never assume them. The tool puts the display
   on the side the Dock does not use, and removes it after 600 s (`--timeout`
   changes this).

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

4. Move the window onto the virtual display, at its origin plus a margin. The
   document window can appear after the process, so wait for it, and stop the
   check if the window never comes or the move fails:

   ```bash
   moved=
   for i in $(seq 1 50); do
     [ "$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to count windows")" -gt 0 ] && {
       osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set position of every window to {$((ORIGIN_X + 100)), $((ORIGIN_Y + 60))}" &&
         { moved=1; break; }; }
     sleep 0.1
   done
   [ -n "$moved" ] || { echo "window not moved after 5 s"; kill $PID; }
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
   INDEX=$("$OUT/vdisplay" --index "$DISPLAY_ID") &&
     screencapture -x -D "$INDEX" -t jpg "$OUT/shot.jpg"
   ```

   Look up the index before each capture. When other sessions add or remove
   displays, the number changes, and an old number captures another screen.
   If `--index` fails, the display is gone (for example, the timeout ended).

   The window has the inactive look (gray window buttons, no accent color),
   because the app is not frontmost. Do not report this as a bug.

7. Clean up: `kill $PID $VD_PID`. Never `pkill vdisplay`: other sessions can
   run one. Close the Rex block.

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
