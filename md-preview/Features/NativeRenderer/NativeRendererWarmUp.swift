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

/// The first view of the native renderer pays for what is made one time
/// in a process: the Metal device and the shaders (the core keeps them
/// for all of its views), and what the text system makes at the first
/// use of a font in a size and of its glyphs. None of that needs the
/// document. This makes one view that no window has, with the reader's
/// style and a text that has each font of a page in each of its sizes,
/// draws one frame of it, and throws it away. The view's own glyph
/// images go with it; what the system and the core keep for the process
/// stays, so the view of the document finds it there.
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
        // The fonts of the style are not changed after this, and only
        // the thread below reads them.
        nonisolated(unsafe) let style = NativeRendererStyle(appearance: NSApp.effectiveAppearance, zoom: TextSizeSetting.currentZoom)
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
            // As wide as a page, and as high as the text: the frame has
            // the glyphs of what is in the view and near it.
            mdcore_resize(ctx, 900, 600, scale)
            autoreleasepool { mdcore_draw(ctx, 0) }
            mdcore_destroy(ctx)
            // The layer was set up on this thread, which has no run loop
            // to end its transaction.
            CATransaction.flush()
        }
    }

    /// Each font that the layout makes, in each of its sizes: the six
    /// heading levels, the text in its four styles, and code in a line
    /// and in a block. With no emoji and no text of another script: their
    /// fonts are large, and most documents have none.
    private nonisolated static let text = """
    # Heading one: The quick brown fox 0123456789

    ## Heading two: jumps over the lazy dog

    ### Heading three: Sphinx of black quartz

    #### Heading four: judge my vow

    ##### Heading five: Pack my box

    ###### Heading six: with five dozen jugs

    The quick brown fox jumps over the lazy dog. THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. 0123456789 .,;:!?()[]'"-
    **Bold: the quick brown fox.** *Italic: jumps over the lazy dog.* ***Both: sphinx of black quartz.***
    `code: the quick brown fox (){}[]<>=+-*/_` and [a link](https://example.com).

    - A list item
    1. A numbered item
    - [ ] A task

    > A quote.

    ```
    code: the quick brown fox jumps over the lazy dog 0123456789 (){}[]<>=+-*/_.,;:
    ```

    | Head | Cell |
    | --- | --- |
    | The quick | brown fox |
    """
}
