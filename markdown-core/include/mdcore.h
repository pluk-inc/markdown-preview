// C API of the Markdown core (libmdcore.a).
//
// The host app owns a view with a CAMetalLayer, the scroll position, and the
// input events. The core parses the Markdown, lays it out, and draws into
// the layer. Sizes and positions are in points; "document space" is the
// view's y plus the scroll offset.
//
// Threads: a call on a renderer can come from any thread. The core lets
// one call at a time work on a renderer, with one exception: mdcore_draw
// gives the renderer free before it waits for the display, so the other
// calls do not wait for a frame. Draws do not overlap, and mdcore_resize
// and mdcore_destroy wait for the draw in progress. Two things stay with
// the host: calls of mdcore_create do not overlap, and no call uses a
// renderer after its mdcore_destroy began.
#ifndef MDCORE_H
#define MDCORE_H

#include <stdbool.h>
#include <stdint.h>

// Creates a renderer that draws into the given CAMetalLayer.
void *mdcore_create(void *metal_layer);

// Frees the renderer. The layer stays with the host.
void mdcore_destroy(void *ctx);

// A color: red, green, blue, alpha, not premultiplied.
typedef struct {
    uint8_t r, g, b, a;
} mdcore_color;

// The reader style. The fonts are font objects of the platform's text system
// (CTFont on Apple systems) at any size; the core makes
// the sizes it needs and keeps its own reference. A null bold or heading font
// falls back on the body font, and a null body or code font on the system's.
typedef struct {
    const void *body_font;
    const void *bold_font;
    const void *heading_font;
    const void *code_font;
    double body_size;     // points
    double line_height;   // multiple of the body size
    double column_width;  // points; 0 = the full width of the view
    double page_padding;  // points, left and right of the column
    double column_inset;  // points, left and right inside the column
    mdcore_color text;
    mdcore_color secondary;
    mdcore_color link;
    mdcore_color code_background;
    mdcore_color code_border;
    mdcore_color rule;
    mdcore_color quote_bar;
    mdcore_color selection;
} mdcore_style;

// Sets the reader style. Call mdcore_resize after it to lay the document
// out with it. A renderer without a style uses the system fonts and the
// app's light palette. The page background is not part of the style: the
// core draws on a transparent surface.
void mdcore_set_style(void *ctx, const mdcore_style *style);

// Replaces the document. Call mdcore_resize after it to lay it out.
void mdcore_set_markdown(void *ctx, const char *utf8, long length);

// Sets the view size and backing scale. Lays out what the view shows now
// when the width or the scale changed.
void mdcore_resize(void *ctx, double width, double height, double scale);

// Continues the layout of a long document for about budget_ms; 0 lays out
// all that is left. Returns true while more is left; call it again from the
// run loop.
bool mdcore_layout_more(void *ctx, double budget_ms);

// Height of the part that is laid out so far.
double mdcore_content_height(void *ctx);

// Draws one frame at the given scroll offset. Can wait for the display;
// see "Threads" above.
//
// `target` is the surface for this frame when the host has it already (a
// CAMetalDrawable from a CAMetalDisplayLink on Apple systems, which is the
// only source of drawables while such a link is on the layer). With NULL
// the core takes the next one from the layer.
void mdcore_draw(void *ctx, double scroll_y, void *target);

// Selection. phase: 0 = mouse down, 1 = drag. x, y are in document space.
void mdcore_mouse(void *ctx, double x, double y, int phase);
void mdcore_select_all(void *ctx);
// The selected text as UTF-8. The pointer is valid until the next call.
const char *mdcore_selection_text(void *ctx, long *length);

#endif
