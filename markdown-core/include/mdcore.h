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
// only the changed parts again, and keeps the reader's place and the
// selection (one in the blocks that changed goes to the start of them). A
// text of another document is the same call; the host then scrolls to the
// top of the page and ends the selection. The text that the document
// has costs one comparison and no parse. Call mdcore_resize after it
// when the view has no layout yet.
void mdcore_set_markdown(void *ctx, const char *utf8, long length);

// Puts a text in the place of the bytes from `start` to `end` of the
// text of the document: the same result as mdcore_set_markdown with the
// full text after that change, for a host that knows what changed (a
// key that was typed). `start == end` puts the text in; an empty text
// takes the range out. The offsets are UTF-8 byte offsets in the text
// that the document has now (after each task that was set, see
// mdcore_set_task_checked), and must not cut a character. A range that
// reaches out of the text is cut to it.
void mdcore_replace_text(void *ctx, long start, long end, const char *utf8, long length);

// The caret of an editor: the place where typed text goes. A view has
// none until one of these calls gives it one, and the core draws it.
//
// Puts the caret at the text that is nearest to a point (x in the view,
// y in the space of the page) and ends the selection. False when no text
// is there. In a document with no text, the caret is at its start.
bool mdcore_caret_set(void *ctx, double x, double y);

// Takes the caret away.
void mdcore_caret_clear(void *ctx);

// Shows the caret or not: the caret is still there and takes text. For a
// host that draws the caret itself (the system's own caret on Apple
// systems) and so wants none from the core. The next frame draws the
// change.
void mdcore_caret_show(void *ctx, bool shown);

// Where the caret is in the text of the document, as a UTF-8 byte
// offset; -1 for no caret. With mdcore_replace_text, a host puts text in
// the place of text that it put in before (the text of an input method
// that is not final yet).
long mdcore_caret_offset(void *ctx);

// The marks of the source at the caret show as text, as they do in a
// source: the two marks of bold, italic, and struck text, of code, and
// of a link (with its target) that the caret is in or at an end of.
// They are text for the caret then: it has a place before a mark and
// after it, and a delete takes one character of a mark. Each other
// mark does not show, and none shows with text selected, with no
// caret, and while the view does not take the keys.
//
// Says if the view takes the keys (true at the start).
void mdcore_set_focused(void *ctx, bool focused);

// Where the caret is: its x in the view, the top of its line in the
// space of the page, and the height of the line. For a host that keeps
// the caret in view or puts an input window at it. In a document with no
// text, it is where the first line starts. False for no caret, and when
// the block of the caret has no layout.
bool mdcore_caret_rect(void *ctx, double *x, double *y, double *height);

// The moves of a caret. Left and right are against the reading order
// and in it.
typedef enum {
    MDCORE_MOVE_LEFT = 0,       // one character
    MDCORE_MOVE_RIGHT = 1,
    MDCORE_MOVE_WORD_LEFT = 2,  // to the start of a word
    MDCORE_MOVE_WORD_RIGHT = 3, // to the end of a word
    MDCORE_MOVE_UP = 4,         // one line, at the same x where the line has text there
    MDCORE_MOVE_DOWN = 5,
    MDCORE_MOVE_LINE_START = 6,
    MDCORE_MOVE_LINE_END = 7,
    MDCORE_MOVE_DOCUMENT_START = 8,
    MDCORE_MOVE_DOCUMENT_END = 9,
    // A text is one paragraph; each line of a code block is one.
    MDCORE_MOVE_PARAGRAPH_START = 10,
    MDCORE_MOVE_PARAGRAPH_END = 11,
} mdcore_move;

// Moves the caret. With `extend`, the text from where the caret was to
// where it is now is selected, or the selection that ends at the caret
// gets longer or shorter; with no `extend`, the selection ends, and a
// step to the left or to the right goes to that end of it. The caret
// goes over each place where the source has no room for text (a table
// cell with no text). The end of a line that goes on in the next line
// is the same place in the text as the start of that one: the caret
// shows at the end of the line after a move to it or a click right of
// it. Up in the first line goes to the start of the document, and down
// in the last line to its end. False when the caret did not move and
// the selection did not change, and for no caret.
bool mdcore_caret_move(void *ctx, mdcore_move move, bool extend);

// Each line of the source with nothing in it after a block, but the
// last one, shows as an empty line of the page, and a caret can be in
// it (the line that Return makes after a paragraph).
//
// Text that goes in at the caret when the caret is in such a line
// starts a paragraph of its own there:
// the core puts a line break before it, with mdcore_insert and with
// mdcore_replace_text for an empty range at the caret. The text then
// ends at the caret, and starts its own length before it.
//
// Puts text in at the caret, as mdcore_replace_text does at its place in
// the source, and the caret is after the text. Text at the end of bold
// text is bold: it goes where the character before the caret is. With
// text selected, the new text comes in its place (see mdcore_delete for
// what goes). Does nothing with no caret. False when nothing changed: no
// caret, no text, or a selection that has no edit.
bool mdcore_insert(void *ctx, const char *utf8, long length);

// Return at the caret: what the block of the caret needs for it. In
// code, a new line. At the end of the text of a list item, a new item
// of the same kind. At the end of each other text, an empty line after
// the block, with the caret in it. In an empty line, one more. In the
// text, the rest of the text is a paragraph of its own. Text that is selected
// goes first. Does nothing in a table, and with no caret.
void mdcore_insert_break(void *ctx);

// Takes out the text that is selected. With no text selected, the text
// from the caret to where the move of the caret goes (mdcore_move):
// MDCORE_MOVE_LEFT is the Delete key, MDCORE_MOVE_RIGHT a delete forward,
// the moves by a word, to an end of the line, and to an end of the
// paragraph take that much. True when the source changed.
//
// A character goes with all that the source has for it (an entity, a
// run of spaces that shows as one space). An empty paragraph goes as a
// whole. At the start of a block, MDCORE_MOVE_LEFT puts its text at the
// end of the block before it, which keeps its kind; a move by a word or
// to the end of a paragraph takes only that line break there.
//
// The text that stays keeps its styles: a mark of bold text and the
// like that is in the range stays when its other mark is not, and the
// two marks of a style go when all of its text goes. Text of more than
// one block goes on in the first block, and the blocks between go.
// Nothing changes for a range with one end in code or in a table and
// the other end in another block (but when it has all of the text of
// its blocks), and for one from a cell of a table to another cell.
bool mdcore_delete(void *ctx, mdcore_move move);

// The bytes of the source that the last mdcore_delete that changed the
// source took out, as UTF-8: the text with the marks that went with
// it, and no mark that stayed for the text around it. Text that puts
// them in again at the caret gives the text of before (Control-Y after
// Control-K). Valid until the next call that deletes; for the thread
// that makes those calls.
const char *mdcore_deleted_text(void *ctx, long *length);

// Takes out the lines of the source that the caret is in, or the text
// that is selected, with their line breaks. True when the source
// changed.
bool mdcore_delete_lines(void *ctx);

// Changes the places of the character before the caret and the one
// after it (the two before it, at the end of a text), and puts the
// caret after them. False, with no change, when there are no two such
// characters next to each other in the source, with text selected, and
// with no caret.
bool mdcore_transpose(void *ctx);

// The text of the document as it is now, UTF-8: what a host saves after
// edits. The pointer is good until the next call of this.
const char *mdcore_source(void *ctx, long *length);

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
// is the same as mdcore_set_markdown with that one mark changed (the
// source that the core keeps gets the mark too), so a host that then
// gets the changed source from its own save does not have to set it
// again. False when no task has its mark on that line.
bool mdcore_set_task_checked(void *ctx, long line, bool checked);

// The core keeps the reader's place: the first line of text that the view
// shows. A new layout of the same document (another width, another style)
// puts that line at the height of the page that it had, so the host draws
// at the scroll position that it has and sees the same text. At the top of
// the page there is no place, and the top stays the top.
//
// The height of the strip at the top of the view that the host covers (a
// toolbar that the page scrolls under). The first line that shows is the
// one below it. 0 when nothing covers the view.
void mdcore_set_top_inset(void *ctx, double inset);

// The scroll position of the view. The host calls this each time the
// position changes, and before the first frame; it never waits. The core
// takes the place from the last position in each call that changes the
// layout (mdcore_resize with a new width, mdcore_set_style,
// mdcore_set_markdown), so the host has nothing to do there.
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
// A view with a caret has it at the end of the selection that a drag
// moves, where the source has room for text there.
void mdcore_mouse(void *ctx, double x, double y, int phase);
// A view with a caret has it at the end of the selection after this.
void mdcore_select_all(void *ctx);
// Ends the selection. mdcore_set_markdown keeps a selection through a
// change of the text; a host calls this for the text of another document.
void mdcore_select_none(void *ctx);
// True when text is selected. A host that draws the caret itself shows
// none then.
bool mdcore_has_selection(void *ctx);
// The selected text as UTF-8. The pointer is valid until the next call.
const char *mdcore_selection_text(void *ctx, long *length);

#endif
