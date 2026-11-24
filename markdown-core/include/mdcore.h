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
// the sizes it needs and keeps its own reference. A null bold font falls back
// on the body font, a null heading font on the bold font, and a null body or
// code font on the system's.
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

// Takes the text of the document, UTF-8. For a text that is the text
// before with a change (the same file, saved by another app), the layout
// stays for all that did not change: the core compares the blocks, makes
// only the changed parts again, and keeps the reader's place when it is
// not in them. A text of another document is the same call; the top of
// the page stays then, and the host scrolls to it. Call mdcore_resize
// after it when the view has no layout yet.
void mdcore_set_markdown(void *ctx, const char *utf8, long length);

// Sets the view size and backing scale. Starts a new layout when the
// document, the style, or the width changed; the next frame lays out
// what it shows. A new scale only makes the glyph bitmaps again.
void mdcore_resize(void *ctx, double width, double height, double scale);

// The page is laid out in the left `width` points of the view, and the
// rest stays empty: for a host that covers a strip at the right edge of
// the view (a scroll bar that takes room). 0, the default, is the full
// width. Call mdcore_resize after it.
void mdcore_set_page_width(void *ctx, double width);

// The core lays out a document where the view is, not from its top. What
// nobody looked at has a height that is estimated from its text. So the
// height of the page is near the real one from the start, and gets exact
// where the reader goes.
//
// Text that the view shows stays at its height when a part above it gets
// its real height: the top of the page moves in its place, below 0 or
// above it. All heights of the page in this API (a scroll position, a
// place, a task, the pointer) count in the same space, in which the page
// is from its top down for its height (mdcore_page_area). A host gives
// its scroll area that range.

// A number that goes up each time the layout gave something a place or a
// height: a frame or a layout call laid out a part, or a new layout
// started. A host that keeps something from the layout (the range of the
// page, the places of its controls) takes it again when this changed.
long mdcore_layout_revision(void *ctx);

// The top and the height of the page, and the number of the layout that
// they are of (mdcore_layout_revision), from one look: a frame on another
// thread can change each between two calls.
long mdcore_page_area(void *ctx, double *top, double *height);

// Lays out the last view heights of the document, so its end is at its
// real height: for a scroll to the end. The text that the view shows now
// stays where it is.
void mdcore_layout_end(void *ctx);

// Draws one frame at the given scroll offset. Can wait for the display;
// see "Threads" above.
void mdcore_draw(void *ctx, double scroll_y);

// The same, for a frame that must show together with a change of the
// window or of the host's views (a new size, a control that the host
// moved): the frame goes to the screen with the Core Animation
// transaction of the calling thread. Call it on the thread that changes
// the views.
void mdcore_draw_with_window(void *ctx, double scroll_y);

// A frame of a scroll that the host animates to a fixed place of the
// document (its top, its end): target_y is where the scroll ends. A part
// that this frame lays out on the way leaves the text at the target
// where it is, so the scroll ends at the place it started for.
void mdcore_draw_toward(void *ctx, double scroll_y, double target_y);

typedef struct {
    double x, y, size; // the box: its top left and its side, in document space
    long line;         // source line of the "[ ]", from 1
    bool checked;
} mdcore_task;

// The core draws no check box for a task: it keeps the place free, and
// the host puts its own control there (the system's check box on Apple
// systems). This gives the tasks whose boxes are between two heights of
// the page that is laid out now, down the page. Writes at most `capacity`
// of them and returns how many there are: with a larger number, call
// again with more room. To check one, see mdcore_set_task_checked.
long mdcore_tasks(void *ctx, double top, double bottom, mdcore_task *out, long capacity);

// Checks or opens the task whose "[ ]" is on a source line, in place: the
// document that is set stays, with no new parse and no new layout, and
// the next frame shows the text of the item in its new color. The result
// is the same as mdcore_set_markdown with that one mark changed, so a
// host that then gets the changed source from its own save does not have
// to set it again. False when no task has its mark on that line.
bool mdcore_set_task_checked(void *ctx, long line, bool checked);

// The core keeps the reader's place: the first line of text that the view
// shows. A new layout of the same document (another width, another style)
// puts that line at the height of the page that it had, so the host draws
// at the scroll position that it has and sees the same text. The place is
// taken from a frame after each scroll. At the top of the page there is
// none, and the top stays the top.
//
// The height of the strip at the top of the view that the host covers (a
// toolbar that the page scrolls under). The first line that shows is the
// one below it. 0 when nothing covers the view.
void mdcore_set_top_inset(void *ctx, double inset);

// The scroll position of the view now. A frame says it too, but a frame
// can be one refresh behind: a host calls this before it changes what
// the layout is made from (mdcore_resize with a new width, mdcore_set_style,
// mdcore_set_markdown), so the place that is kept is the one of the text
// that the reader sees at that moment.
void mdcore_note_scroll(void *ctx, double scroll_y);

// The shape that the pointer has over a point in document space. The core
// decides it and the host shows it: the text cursor on a line of text,
// the default one in the margin, between blocks, and at a list marker or
// a check box. Ask again when the pointer moves and when the page moves
// under it. This call never waits: when a layout call or a frame works on
// the renderer, it returns MDCORE_POINTER_BUSY, and the host keeps the
// shape that it shows and asks again a little later.
typedef enum {
    MDCORE_POINTER_DEFAULT = 0,
    MDCORE_POINTER_TEXT = 1,
    MDCORE_POINTER_BUSY = 2,
} mdcore_pointer;
mdcore_pointer mdcore_pointer_shape(void *ctx, double x, double y);

// Selection. phase: 0 = mouse down, 1 = drag. x, y are in document space.
void mdcore_mouse(void *ctx, double x, double y, int phase);
void mdcore_select_all(void *ctx);
// The selected text as UTF-8. The pointer is valid until the next call.
const char *mdcore_selection_text(void *ctx, long *length);

#endif
