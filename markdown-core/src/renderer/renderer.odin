// The renderer draws quads on the GPU. This file says what a backend must
// have; `metal_darwin.odin` is the backend for Apple systems.
//
// A backend defines the type `Renderer` and these procedures:
//
//   init(r, surface)          surface: what the host gives to draw into
//                             (a CAMetalLayer for Metal)
//   destroy(r)
//   resize(r, width, height, scale)        points, and the backing scale
//   set_display(r, rects, glyphs)          replaces the display list
//   set_selection(r, quads)                replaces the selection highlight
//   sync_atlases(r, cache)                 uploads the glyph pixels that changed
//   frame_begin(r, scroll_px) -> Frame     all that one frame draws, with its
//                                          own references; scroll from the
//                                          origin of the display list, in
//                                          pixels
//   frame_draw(frame)                      draws it and waits for the display
//                                          if it must
//
// A frame draws the rectangles, then the selection, then the glyphs. The
// two steps are apart so that the caller can let other threads use the
// view's state while the frame waits for the display.
package renderer
