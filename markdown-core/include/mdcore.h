// C API of the Markdown core (libmdcore.a).
//
// The host app owns a view with a CAMetalLayer, the scroll position, and the
// input events. The core parses the Markdown, lays it out, and draws into
// the layer. All calls are made on the main thread. Sizes and positions are
// in points; "document space" is the view's y plus the scroll offset.
#ifndef MDCORE_H
#define MDCORE_H

#include <stdbool.h>

// Creates a renderer that draws into the given CAMetalLayer.
void *mdcore_create(void *metal_layer);

// Frees the renderer. The layer stays with the host.
void mdcore_destroy(void *ctx);

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
