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
//   draw(r, scroll_px)                     one frame; scroll from the origin
//                                          of the display list, in pixels
//
// A frame draws the rectangles, then the selection, then the glyphs.
package renderer
