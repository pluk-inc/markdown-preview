// C API of the Markdown core (libmdcore.a).
//
// The host app owns a view with a CAMetalLayer, the scroll position, and the
// input events. The core parses the Markdown, lays it out, and draws into
// the layer. All calls are made on the main thread. Sizes and positions are
// in points; "document space" is the view's y plus the scroll offset.
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

// The reader style. The fonts are CTFont objects at any size; the core makes
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
    double page_padding;  // points, left and right
    mdcore_color text;
    mdcore_color secondary;
    mdcore_color link;
    mdcore_color code_background;
    mdcore_color code_border;
    mdcore_color rule;
    mdcore_color quote_bar;
    mdcore_color selection;
} mdcore_style;

// Sets the reader style and parses the document again with it. Call
// mdcore_resize after it to lay it out. A renderer without a style uses the
// system fonts and the app's light palette. The page background is not part
// of the style: the core draws on a transparent layer.
void mdcore_set_style(void *ctx, const mdcore_style *style);

// Replaces the document. Call mdcore_resize after it to lay it out.
void mdcore_set_markdown(void *ctx, const char *utf8, long length);

// Sets the view size and backing scale. Lays out what the view shows now
// when the width or the scale changed.
void mdcore_resize(void *ctx, double width, double height, double scale);

// Continues the layout of a long document for about budget_ms. Returns true
// while more is left; call it again from the run loop.
bool mdcore_layout_more(void *ctx, double budget_ms);

// Height of the part that is laid out so far.
double mdcore_content_height(void *ctx);

// Draws one frame at the given scroll offset.
void mdcore_draw(void *ctx, double scroll_y);

// Selection. phase: 0 = mouse down, 1 = drag. x, y are in document space.
void mdcore_mouse(void *ctx, double x, double y, int phase);
void mdcore_select_all(void *ctx);
// The selected text as UTF-8. The pointer is valid until the next call.
const char *mdcore_selection_text(void *ctx, long *length);

#endif
