//
//  NativeRendererWarmUp.swift
//  md-preview
//
//  The work that the native renderer does only one time in a process, on
//  a thread of its own while the app starts.
//

import AppKit
import MDCore
import QuartzCore

/// The first view of the native renderer pays for what the system makes
/// one time in a process: the Metal device and the shaders, each font in
/// each size of a page, and the image of each glyph. None of that needs
/// the document. This makes one view that no window has, with the reader's
/// style and a text that has each kind of block and the common letters,
/// draws one frame of it, and throws it away. The system keeps what it
/// made, so the view of the document finds it there.
///
/// The work runs while AppKit starts the app and reads the document, on a
/// thread that the main thread does not wait for.
nonisolated enum NativeRendererWarmUp {
    /// Starts the work, one time, when the native renderer is the one that
    /// shows documents. Call it on the main thread, as early as the app
    /// can.
    @MainActor
    static func start() {
        guard RendererSetting.current == .native, !started else { return }
        started = true
        // What needs the main thread is read here: the settings, the
        // appearance, and the scale of the screen.
        let stored = UserDefaults.standard.double(forKey: TextSizeSetting.defaultsKey)
        // The fonts of the style are not changed after this, and only
        // the thread below reads them.
        nonisolated(unsafe) let style = NativeRendererStyle(appearance: NSApp.effectiveAppearance, zoom: stored > 0 ? stored : 1)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let thread = Thread { run(style: style, scale: scale) }
        thread.qualityOfService = .userInitiated
        thread.name = "md-preview.native-warm-up"
        thread.start()
    }

    @MainActor private static var started = false

    private nonisolated static func run(style: NativeRendererStyle, scale: CGFloat) {
        LaunchSignposts.interval("nativeWarmUp") {
            let layer = CAMetalLayer()
            guard let ctx = mdcore_create(Unmanaged.passUnretained(layer).toOpaque()) else { return }
            style.apply(to: ctx)
            text.withCString { mdcore_set_markdown(ctx, $0, strlen($0)) }
            mdcore_resize(ctx, 900, 900, scale)
            autoreleasepool { mdcore_draw(ctx, 0) }
            mdcore_destroy(ctx)
        }
    }

    /// Each kind of block and each style, with the letters, the digits,
    /// and the marks of most text, so that each font of a page is made in
    /// each of its sizes with its common glyphs.
    private nonisolated static let text = """
    # The quick brown fox JUMPS over the lazy dog 0123456789

    ## Sphinx of black quartz, judge my vow: (yes) [no] {ok} <tag>

    ### Pack my box with five dozen liquor jugs! "Quoted" 'single' & more?

    #### How vexingly quick daft zebras jump; x = y + z * 2 / 3 - 1 % 4

    ##### The five boxing wizards jump quickly @ # $ ^ _ | \\ ~

    ###### Waltz, bad nymph, for quick jigs vex

    The quick brown fox jumps over the lazy dog. THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. 0123456789 .,;:!?()[]{}<>'"-_=+*/|@#$%^&~
    **The quick brown fox jumps over the lazy dog. THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. 0123456789 .,;:!?()**
    *The quick brown fox jumps over the lazy dog. THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. 0123456789 .,;:!?()*
    ***The quick brown fox jumps over the lazy dog. THE QUICK BROWN FOX JUMPS.***
    `the quick brown fox jumps over the lazy dog THE QUICK BROWN FOX 0123456789 (){}[]<>=+-*/_.,;:` and [a link to it](https://example.com).

    - A list item with text
    1. A numbered item
    - [ ] An open task
    - [x] A done task

    > A quote with text in it.

    ```
    the quick brown fox jumps over the lazy dog THE QUICK BROWN FOX JUMPS OVER
    0123456789 (){}[]<>=+-*/_.,;:!?'"#$%^&|~@
    ```

    | Head | Cell |
    | --- | --- |
    | The quick | brown fox |
    """
}
