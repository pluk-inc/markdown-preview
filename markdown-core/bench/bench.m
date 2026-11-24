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

int main(int argc, const char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: mdcore-bench <file.md>\n");
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
        if (last == 0 || text[first] != '[') break;
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
