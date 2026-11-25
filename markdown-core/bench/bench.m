// Benchmark of the Markdown core through its C API, with no window.
//
//   mdcore-bench <file.md>
//
// One run is one cold process: it draws the first frame, lays the full
// document out, and scrolls through it two times. It prints one
// "name value" pair on each line. core.py builds and runs it.
//
// The layer is not on a screen. A draw still waits for a free drawable, so
// the cost of a scroll frame is the CPU time of this thread, not the time
// on the clock: the display list, the glyph bitmaps, and the commands sent
// to the GPU.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <malloc/malloc.h>
#include <pthread/qos.h>
#include <sys/resource.h>
#include <time.h>
#include "mdcore.h"

static const double VIEW_WIDTH = 900, VIEW_HEIGHT = 800, VIEW_SCALE = 2;
static const double SCROLL_STEP = 40;
// A scroll pass stops here, so that a long document gives the same number
// of frames in each run.
static const double SCROLL_LIMIT = 24000;

static double now_ms(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
}

static double thread_cpu_ms(void) {
    return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1e6;
}

static double cpu_ms(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1e3
        + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e3;
}

// Memory that the process holds in the heap: the document, the layout, the
// glyph bitmaps, and the quads. The footprint of the process is no use
// here, because a layer that is not on a screen keeps its frames.
static double heap_mb(void) {
    malloc_statistics_t stats;
    malloc_zone_statistics(NULL, &stats);
    return stats.size_in_use / 1048576.0;
}

// Scrolls from the top in steps and prints the CPU time of a frame: the
// mean and the longest.
static void scroll_pass(void *ctx, const char *name, double end) {
    double total = 0, longest = 0;
    int frames = 0;
    for (double y = 0; y <= end; y += SCROLL_STEP) {
        double start = thread_cpu_ms();
        @autoreleasepool {
            mdcore_draw(ctx, y);
        }
        double took = thread_cpu_ms() - start;
        total += took;
        if (took > longest) longest = took;
        frames += 1;
    }
    printf("%s_frame_cpu_ms %.3f\n", name, total / frames);
    printf("%s_longest_frame_cpu_ms %.2f\n", name, longest);
}

// The keys that move the caret, through all of a document: each step to
// the right is later in the source and each one to the left earlier,
// each line down is lower on the page and each line up higher, and the
// caret gets from one end of the document to the other. Returns what is
// wrong, or NULL.
static const char *caret_walk(void *ctx, long length) {
    // A click: the button down, the caret, and the button up at the
    // same point. Nothing is selected, also when the click made the
    // marks of its line show and the text moved under the pointer.
    int clicks = 0;
    for (double click_y = 20; click_y < 400; click_y += 20) {
        mdcore_mouse(ctx, 60, click_y, 0);
        if (mdcore_caret_set(ctx, 60, click_y)) {
            clicks += 1;
            mdcore_mouse(ctx, 60, click_y, 1);
            mdcore_mouse(ctx, 61, click_y + 1, 1);
            if (mdcore_has_selection(ctx)) return "a click selected text";
        }
    }
    if (clicks == 0) return "no click put a caret in the text";
    if (!mdcore_caret_set(ctx, VIEW_WIDTH / 2, 40)) return "no caret at a click";
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false);
    if (mdcore_caret_move(ctx, MDCORE_MOVE_UP, false) || mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false)) {
        return "a move at the start of the document";
    }
    long first = mdcore_caret_offset(ctx), at = first, steps = 0;
    while (mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false)) {
        long now = mdcore_caret_offset(ctx);
        if (now <= at || ++steps > length) return "a step to the right that is not later in the source";
        at = now;
    }
    long last = at;
    // A step with the selection and the step back with it, from each
    // place: the caret is where it was, with nothing selected. Marks
    // that show at the caret are text for these steps.
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false);
    for (steps = 0; steps <= length; steps++) {
        long from = mdcore_caret_offset(ctx);
        if (mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, true)) {
            if (!mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, true) || mdcore_caret_offset(ctx) != from || mdcore_has_selection(ctx)) {
                return "a step with the selection and the step back do not end where they started";
            }
        }
        if (!mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false)) break;
    }
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false);
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_END, false);
    if (mdcore_caret_offset(ctx) != last) return "the end of the document is not where the steps to the right end";
    if (mdcore_caret_move(ctx, MDCORE_MOVE_DOWN, false)) return "a move at the end of the document";
    for (steps = 0; mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false);) {
        long now = mdcore_caret_offset(ctx);
        if (now >= at || ++steps > length) return "a step to the left that is not earlier in the source";
        at = now;
    }
    if (at != first) return "the steps to the left do not end at the start of the document";
    for (int word = 0; word < 2; word++) {
        for (steps = 0; mdcore_caret_move(ctx, word ? MDCORE_MOVE_WORD_LEFT : MDCORE_MOVE_WORD_RIGHT, false);) {
            long now = mdcore_caret_offset(ctx);
            if ((word ? now >= at : now <= at) || ++steps > length) return "a step of a word in the wrong direction";
            at = now;
        }
        if (at != (word ? first : last)) return "the steps of a word do not end at an end of the document";
    }
    double x = 0, y = 0, line = 0, height = 0;
    if (!mdcore_caret_rect(ctx, &x, &y, &height)) return "no place for the caret at the start";
    // The last press in the last line goes to the end of the document,
    // in that line; each press before it is a line lower.
    for (steps = 0; mdcore_caret_move(ctx, MDCORE_MOVE_DOWN, false);) {
        if (!mdcore_caret_rect(ctx, &x, &line, &height) || line < y || ++steps > length) return "a line down that is higher";
        if (line == y && mdcore_caret_offset(ctx) != last) return "a line down that is not lower";
        y = line;
    }
    if (mdcore_caret_offset(ctx) != last) return "the lines down do not end at the end of the document";
    for (steps = 0; mdcore_caret_move(ctx, MDCORE_MOVE_UP, false);) {
        if (!mdcore_caret_rect(ctx, &x, &line, &height) || line > y || ++steps > length) return "a line up that is lower";
        if (line == y && mdcore_caret_offset(ctx) != first) return "a line up that is not higher";
        y = line;
    }
    if (mdcore_caret_offset(ctx) != first) return "the lines up do not end at the start of the document";
    // Select All puts the caret at the end, so a step with the selection
    // makes it shorter, and one with none goes to its end.
    mdcore_select_all(ctx);
    if (!mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, true) || !mdcore_has_selection(ctx)) return "Select All and a step with the selection";
    mdcore_select_all(ctx);
    long selected_end = mdcore_caret_offset(ctx);
    if (!mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false) || mdcore_has_selection(ctx) || mdcore_caret_offset(ctx) != selected_end) {
        return "Select All and a step to the right";
    }
    // Return at the end of the first paragraph: the caret is in a line
    // of its own below, a character typed there is a new paragraph, and
    // a delete for each takes all of it out again.
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false);
    mdcore_caret_move(ctx, MDCORE_MOVE_PARAGRAPH_END, false);
    long before_length = 0, after_length = 0;
    NSData *before = [NSData dataWithBytes:mdcore_source(ctx, &before_length) length:(NSUInteger)before_length];
    long end_of_first = mdcore_caret_offset(ctx);
    if (!mdcore_caret_rect(ctx, &x, &y, &height)) return "no place for the caret at the end of the first paragraph";
    mdcore_insert_break(ctx);
    if (!mdcore_caret_rect(ctx, &x, &line, &height) || line <= y) return "the caret after Return is not in a line below";
    if (!mdcore_caret_move(ctx, MDCORE_MOVE_UP, false) || mdcore_caret_offset(ctx) > end_of_first) return "up from the line that Return made";
    if (!mdcore_caret_move(ctx, MDCORE_MOVE_DOWN, false) || !mdcore_caret_rect(ctx, &x, &y, &height) || y != line) return "down into the line that Return made";
    mdcore_insert(ctx, "w", 1);
    if (!mdcore_caret_rect(ctx, &x, &y, &height) || y != line) return "a character typed in the line that Return made is in another line";
    mdcore_delete(ctx, MDCORE_MOVE_LEFT);
    if (!mdcore_caret_rect(ctx, &x, &y, &height) || y != line) return "the line that Return made does not stay when its text goes";
    mdcore_delete(ctx, MDCORE_MOVE_LEFT);
    const char *after = mdcore_source(ctx, &after_length);
    if (mdcore_caret_offset(ctx) != end_of_first || after_length != before_length || memcmp(after, before.bytes, (size_t)before_length) != 0) {
        return "a delete in the line that Return made does not give the text of before";
    }
    // A space typed at the end of a paragraph is not in its text: the
    // caret shows after it all the same, and a delete takes the space.
    // Not at a first block with no text: a space there is after nothing.
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false);
    long text_start = mdcore_caret_offset(ctx);
    mdcore_caret_move(ctx, MDCORE_MOVE_PARAGRAPH_END, false);
    // Text, not only the mark of a heading with no text, which shows at
    // the caret and is a place for it.
    bool has_text = false;
    {
        long size = 0;
        const char *bytes = mdcore_source(ctx, &size);
        for (long at = text_start; at < mdcore_caret_offset(ctx) && at < size; at++) {
            has_text = has_text || (bytes[at] != '#' && bytes[at] != ' ' && bytes[at] != '\t');
        }
    }
    if (has_text) {
        double end_x = 0, space_x = 0, two_x = 0;
        if (!mdcore_caret_rect(ctx, &end_x, &y, &height)) return "no place for the caret at the end of the first paragraph";
        mdcore_insert(ctx, " ", 1);
        if (!mdcore_caret_rect(ctx, &space_x, &line, &height) || space_x <= end_x || line != y) return "the caret does not move for a space at the end of a text";
        long one_space = mdcore_caret_offset(ctx);
        mdcore_insert(ctx, " ", 1);
        // At the edge of the column the caret stays there: the second
        // space is in the source all the same.
        if (mdcore_caret_offset(ctx) != one_space + 1 || !mdcore_caret_rect(ctx, &two_x, &line, &height) || two_x < space_x) return "the caret does not move for a second space";
        // A step to the left is one space back, and not a letter, and a
        // step to the right one space on again.
        if (!mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false) || !mdcore_caret_rect(ctx, &x, &line, &height) || x != space_x) return "a step to the left after two spaces is not one space";
        if (!mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false) || !mdcore_caret_rect(ctx, &x, &line, &height) || x != end_x) return "a step to the left after one space is not the end of the text";
        if (!mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false) || mdcore_caret_offset(ctx) != one_space) return "a step to the right from the end of a text is not over its first space";
        if (!mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false) || !mdcore_caret_rect(ctx, &x, &line, &height) || x != two_x) return "a step to the right is not over the second space";
        // With Shift, the steps over the spaces select them.
        if (!mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, true) || !mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, true) || !mdcore_has_selection(ctx)) return "a step to the left with Shift over spaces does not select";
        if (!mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, true) || !mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, true) || mdcore_has_selection(ctx)) return "steps back with Shift over spaces do not end the selection where it started";
        mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false);
        mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false);
        // Two spaces again after the two that are after the caret now,
        // and a delete for each of the four: the text of before.
        mdcore_insert(ctx, "  ", 2);
        mdcore_delete(ctx, MDCORE_MOVE_LEFT);
        mdcore_delete(ctx, MDCORE_MOVE_LEFT);
        mdcore_replace_text(ctx, mdcore_caret_offset(ctx), mdcore_caret_offset(ctx) + 2, "", 0);
        after = mdcore_source(ctx, &after_length);
        if (!mdcore_caret_rect(ctx, &x, &line, &height) || x != end_x || after_length != before_length || memcmp(after, before.bytes, (size_t)before_length) != 0) {
            return "a delete after a space at the end of a text does not take the space";
        }
    }
    // A typed character ends the selection at the caret: a step back
    // with the selection selects that character and no more.
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false);
    mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false);
    mdcore_insert(ctx, "q", 1);
    long selected = 0;
    if (!mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, true)) return "a step with the selection after a typed character";
    const char *text = mdcore_selection_text(ctx, &selected);
    if (selected != 1 || text[0] != 'q') return "the selection after a typed character does not start at the caret";
    // Text that is typed with text selected comes in its place, and a
    // delete takes the selection and no more.
    long size = 0;
    mdcore_source(ctx, &size);
    mdcore_insert(ctx, "Q", 1);
    long now = 0;
    const char *source = mdcore_source(ctx, &now);
    long caret = mdcore_caret_offset(ctx);
    if (now != size || mdcore_has_selection(ctx) || caret < 1 || source[caret - 1] != 'Q') return "a typed character does not take the place of the selection";
    mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, true);
    if (!mdcore_delete(ctx, MDCORE_MOVE_RIGHT) || mdcore_has_selection(ctx)) return "a delete with a selection";
    mdcore_source(ctx, &now);
    if (now != size - 1 || mdcore_caret_offset(ctx) != caret - 1) return "a delete with a selection does not take the selection only";
    // The two characters around the caret change places, and again.
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false);
    if (mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false) && mdcore_transpose(ctx)) {
        NSData *swapped = [NSData dataWithBytes:mdcore_source(ctx, &now) length:(NSUInteger)now];
        mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false);
        if (!mdcore_transpose(ctx)) return "the two characters do not change places again";
        mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false);
        mdcore_transpose(ctx);
        source = mdcore_source(ctx, &size);
        if (size != now || memcmp(source, swapped.bytes, (size_t)now) != 0) return "three changes of two characters are not one";
    }
    // Each kind of delete, from each place that some steps go to: the
    // source gets shorter, nothing is selected after it, and the caret
    // has an offset. Then all of the text goes.
    static const mdcore_move kinds[] = {
        MDCORE_MOVE_RIGHT, MDCORE_MOVE_WORD_RIGHT, MDCORE_MOVE_LEFT, MDCORE_MOVE_WORD_LEFT, MDCORE_MOVE_LINE_END,
        MDCORE_MOVE_PARAGRAPH_END, MDCORE_MOVE_LINE_START, MDCORE_MOVE_PARAGRAPH_START,
    };
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false);
    for (long round = 0; round < 4000; round++) {
        mdcore_source(ctx, &size);
        bool gone = (round % 16) == 15 ? mdcore_delete_lines(ctx) : mdcore_delete(ctx, kinds[round % 8]);
        mdcore_source(ctx, &now);
        if (gone != (now != size)) return "a delete says a thing of the source that is not so";
        if (now > size) return "a delete made the source longer";
        // A selection that has no edit stays (one from code into text).
        if (gone && mdcore_has_selection(ctx)) return "text is selected after a delete";
        if (mdcore_caret_offset(ctx) < 0 || mdcore_caret_offset(ctx) > now) return "the caret has no offset after a delete";
        // On through the text, with a selection that the next delete
        // takes each third time.
        bool more = true;
        for (long step = 0; step < 1 + round % 5 && more; step++) {
            more = mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false);
        }
        if (round % 3 == 2) {
            mdcore_caret_move(ctx, (round % 2) ? MDCORE_MOVE_WORD_RIGHT : MDCORE_MOVE_DOWN, true);
        }
        if (!more) break;
    }
    mdcore_select_all(ctx);
    mdcore_delete(ctx, MDCORE_MOVE_LEFT);
    mdcore_select_all(ctx);
    if (mdcore_selection_text(ctx, &selected) != NULL && selected > 0) return "text is there after a delete of all of it";
    return NULL;
}

int main(int argc, const char *argv[]) {
    bool walk = argc == 3 && strcmp(argv[2], "--caret-walk") == 0;
    if (argc != 2 && !walk) {
        fprintf(stderr, "usage: mdcore-bench <file.md> [--caret-walk]\n");
        return 2;
    }
    // The class of an app's main thread. Without it the system can run the
    // program on an efficiency core, where the same work takes three times
    // the CPU time.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    NSData *source = [NSData dataWithContentsOfFile:@(argv[1])];
    if (source == nil) {
        fprintf(stderr, "cannot read %s\n", argv[1]);
        return 1;
    }
    printf("source_kb %.0f\n", source.length / 1024.0);

    double start = now_ms();
    CAMetalLayer *layer = [CAMetalLayer layer];
    void *ctx = mdcore_create((__bridge void *)layer);
    mdcore_set_markdown(ctx, source.bytes, (long)source.length);
    mdcore_resize(ctx, VIEW_WIDTH, VIEW_HEIGHT, VIEW_SCALE);
    @autoreleasepool {
        mdcore_draw(ctx, 0);
    }
    if (walk) {
        const char *wrong = caret_walk(ctx, (long)source.length);
        if (wrong != NULL) {
            fprintf(stderr, "the caret in %s: %s\n", argv[1], wrong);
            return 1;
        }
        return 0;
    }
    printf("first_frame_ms %.2f\n", now_ms() - start);
    printf("first_frame_heap_mb %.1f\n", heap_mb());

    // The height is an estimate for what no frame showed yet.
    double top = 0, height = 0;
    mdcore_page_area(ctx, &top, &height);

    double end = height - VIEW_HEIGHT;
    if (end < 0) end = 0;
    if (end > SCROLL_LIMIT) end = SCROLL_LIMIT;
    // The first pass makes the glyph bitmaps; the second has them all.
    scroll_pass(ctx, "first_scroll", end);
    // Back to the top in one frame, as the Home key does: the text there
    // is shaped again.
    double jump_start = thread_cpu_ms();
    @autoreleasepool {
        mdcore_draw(ctx, 0);
    }
    printf("jump_frame_cpu_ms %.2f\n", thread_cpu_ms() - jump_start);
    scroll_pass(ctx, "second_scroll", end);
    printf("scrolled_heap_mb %.1f\n", heap_mb());

    // To the end of the document, as the End key does: the first frame
    // there.
    double end_start = now_ms();
    mdcore_layout_end(ctx);
    double end_top = 0, end_height = 0;
    mdcore_page_area(ctx, &end_top, &end_height);
    double bottom = end_top + end_height - VIEW_HEIGHT;
    if (bottom < end_top) bottom = end_top;
    @autoreleasepool {
        mdcore_draw(ctx, bottom);
    }
    printf("end_frame_ms %.2f\n", now_ms() - end_start);

    // A new width with the reader at the end, as one step of a live
    // resize: the new layout, which keeps the reader's place, and the
    // frame at the same scroll position.
    double resize_start = now_ms();
    mdcore_note_scroll(ctx, bottom);
    mdcore_resize(ctx, VIEW_WIDTH - 40, VIEW_HEIGHT, VIEW_SCALE);
    @autoreleasepool {
        mdcore_draw(ctx, bottom);
    }
    printf("resize_at_end_ms %.2f\n", now_ms() - resize_start);
    // The estimate of the page height in this width, with only the last
    // view laid out, for the comparison with the real one below.
    mdcore_page_area(ctx, &top, &height);

    // The file changed outside the app, with the reader at the end: the
    // same text with a paragraph more in its middle. The core compares
    // the blocks, makes one part again, and draws at the same position.
    NSMutableData *changed = [source mutableCopy];
    NSRange middle = [source rangeOfData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]
                                 options:0
                                   range:NSMakeRange(source.length / 2, source.length / 2)];
    NSData *more = [@"\n\nA paragraph that another program put in the file.\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    // At the end for a text with no blank line in its second half, so the
    // text is another one in each case.
    NSUInteger at = middle.location != NSNotFound ? middle.location : changed.length;
    [changed replaceBytesInRange:NSMakeRange(at, 0) withBytes:more.bytes length:more.length];
    double change_start = now_ms();
    // The reader is at the end, as the view says it when it scrolls.
    mdcore_note_scroll(ctx, bottom);
    mdcore_set_markdown(ctx, changed.bytes, (long)changed.length);
    @autoreleasepool {
        mdcore_draw(ctx, bottom);
    }
    printf("change_ms %.2f\n", now_ms() - change_start);

    // Keys that are typed, one character each, as an editor gives them:
    // the range of the source that changes, and the frame after it. CPU
    // time: a frame waits for the display. First into the new paragraph
    // in the middle: in a long text the view at the end does not show
    // it, and the frame has no layout of it. Then at the end of the last
    // line of the text, which the view shows: the frame lays out the
    // part of the text that changed.
    enum { KEYS = 10 };
    double type_start = thread_cpu_ms();
    for (int key = 0; key < KEYS; key++) {
        long caret = (long)at + 4 + key;
        mdcore_replace_text(ctx, caret, caret, "x", 1);
        @autoreleasepool {
            mdcore_draw(ctx, bottom);
        }
    }
    printf("type_middle_cpu_ms %.2f\n", (thread_cpu_ms() - type_start) / KEYS);
    // The end of the last line that is text of the page: not an empty
    // line, and not the definition of a link ("[name]: target"), which
    // shows nothing and changes text at other places.
    long last = (long)changed.length;
    const char *text = changed.bytes;
    for (;;) {
        while (last > 0 && (text[last - 1] == '\n' || text[last - 1] == '\r')) last--;
        long line = last;
        while (line > 0 && text[line - 1] != '\n' && text[line - 1] != '\r') line--;
        long first = line;
        while (first < last && text[first] == ' ') first++;
        // A definition has "]:" after its name; a line that starts with
        // a link ("[text](target)") shows on the page.
        bool definition = false;
        if (first < last && text[first] == '[') {
            for (long at = first + 1; at + 1 < last && !definition; at++) {
                definition = text[at] == ']' && text[at + 1] == ':';
            }
        }
        if (last == 0 || !definition) break;
        last = line;
    }
    type_start = thread_cpu_ms();
    for (int key = 0; key < KEYS; key++) {
        // The keys before are in the text too.
        long caret = last + KEYS + key;
        mdcore_replace_text(ctx, caret, caret, "x", 1);
        @autoreleasepool {
            mdcore_draw(ctx, bottom);
        }
    }
    printf("type_end_cpu_ms %.2f\n", (thread_cpu_ms() - type_start) / KEYS);

    // The same through the caret, as a key in an editor is: a click in
    // the middle of the view puts the caret in the text there, each key
    // goes in at the caret, and then each is taken out again. The text
    // is then the one of before.
    long before_length = 0, after_length = 0;
    NSData *before = [NSData dataWithBytes:mdcore_source(ctx, &before_length) length:(NSUInteger)before_length];
    bool caret = false;
    for (double y = bottom + VIEW_HEIGHT / 2; !caret && y < bottom + VIEW_HEIGHT; y += 20) {
        caret = mdcore_caret_set(ctx, VIEW_WIDTH / 2, y);
    }
    double caret_x = 0, caret_y = 0, caret_height = 0;
    caret = caret && mdcore_caret_rect(ctx, &caret_x, &caret_y, &caret_height);
    type_start = thread_cpu_ms();
    for (int key = 0; caret && key < KEYS; key++) {
        mdcore_insert(ctx, "x", 1);
        @autoreleasepool {
            mdcore_draw(ctx, bottom);
        }
    }
    printf("type_caret_cpu_ms %.2f\n", (thread_cpu_ms() - type_start) / KEYS);
    // To the right, or on another line when the text went over the end
    // of its line.
    double moved_x = 0, moved_y = 0;
    bool moved = caret && mdcore_caret_rect(ctx, &moved_x, &moved_y, &caret_height)
        && (moved_x > caret_x || moved_y != caret_y);
    for (int key = 0; caret && key < KEYS; key++) {
        mdcore_delete(ctx, MDCORE_MOVE_LEFT);
    }
    const char *after = mdcore_source(ctx, &after_length);
    bool same = caret && after_length == before_length && memcmp(after, before.bytes, (size_t)before_length) == 0;
    if (!caret || !moved || !same) {
        fprintf(stderr, "the caret did not work: caret %d, moved %d, text as before %d\n", caret, moved, same);
        return 1;
    }
    // The keys that move the caret: each step, and the frame after it.
    // A step and the step back give the place of before, the caret of a
    // line below is lower, and a step with the selection selects text.
    long home = mdcore_caret_offset(ctx);
    bool moves = true;
    double move_start = thread_cpu_ms();
    for (int key = 0; key < KEYS; key++) {
        moves = mdcore_caret_move(ctx, key % 2 == 0 ? MDCORE_MOVE_LEFT : MDCORE_MOVE_RIGHT, false) && moves;
        @autoreleasepool {
            mdcore_draw(ctx, bottom);
        }
    }
    printf("caret_move_cpu_ms %.2f\n", (thread_cpu_ms() - move_start) / KEYS);
    moves = moves && (KEYS % 2 != 0 || mdcore_caret_offset(ctx) == home);
    double line_x = 0, line_y = 0, below_y = 0;
    moves = moves && mdcore_caret_rect(ctx, &line_x, &line_y, &caret_height);
    moves = moves && mdcore_caret_move(ctx, MDCORE_MOVE_DOWN, false) && mdcore_caret_rect(ctx, &line_x, &below_y, &caret_height) && below_y > line_y;
    moves = moves && mdcore_caret_move(ctx, MDCORE_MOVE_UP, false) && mdcore_caret_rect(ctx, &line_x, &below_y, &caret_height) && below_y == line_y;
    moves = moves && !mdcore_has_selection(ctx) && mdcore_caret_move(ctx, MDCORE_MOVE_WORD_LEFT, true) && mdcore_has_selection(ctx);
    moves = moves && mdcore_caret_move(ctx, MDCORE_MOVE_RIGHT, false) && !mdcore_has_selection(ctx);
    // The two ends of the document, from the middle of it.
    long caret_middle = mdcore_caret_offset(ctx);
    moves = moves && mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_START, false) && mdcore_caret_offset(ctx) < caret_middle;
    moves = moves && !mdcore_caret_move(ctx, MDCORE_MOVE_UP, false);
    if (!moves) {
        fprintf(stderr, "the caret did not move as the keys say\n");
        return 1;
    }
    mdcore_caret_clear(ctx);
    // The estimate for the comparison below is of this text.
    mdcore_page_area(ctx, &top, &height);

    // Select All and a copy of all of the text: the two take the text
    // from the document, with no layout.
    double select_start = now_ms();
    mdcore_select_all(ctx);
    printf("select_all_ms %.2f\n", now_ms() - select_start);
    double copy_start = now_ms();
    long copied = 0;
    mdcore_selection_text(ctx, &copied);
    printf("copy_all_ms %.2f\n", now_ms() - copy_start);
    printf("scrolled_and_copied_heap_mb %.1f\n", heap_mb());

    // All of the document laid out, by frames from the top to the end.
    // A frame lays out two and a half view heights below its scroll
    // position, so a step of two view heights reaches the end of the page.
    // CPU time: a frame waits for the display.
    double layout_start = thread_cpu_ms();
    double y = 0, unused = 0;
    mdcore_page_area(ctx, &y, &unused);
    for (;;) {
        double page_top = 0, page_height = 0;
        mdcore_page_area(ctx, &page_top, &page_height);
        if (y >= page_top + page_height) break;
        @autoreleasepool {
            mdcore_draw(ctx, y);
        }
        y += 2 * VIEW_HEIGHT;
    }
    printf("full_layout_cpu_ms %.2f\n", thread_cpu_ms() - layout_start);
    // How far the height of the page was from the real one in the same
    // width, before any of it was laid out but one view.
    double real = 0;
    mdcore_page_area(ctx, &top, &real);
    printf("estimate_error_percent %.1f\n", real > 0 ? (height - real) / real * 100 : 0);

    printf("heap_mb %.1f\n", heap_mb());
    printf("total_cpu_ms %.0f\n", cpu_ms());
    mdcore_destroy(ctx);
    return 0;
}
