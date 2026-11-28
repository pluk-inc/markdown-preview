// Benchmark of the Markdown core through its C API, with no window.
//
//   mdcore-bench <file.md> [--case <name>]... [--caret-walk]
//
// One run is one new process. It runs the cases below one after the other
// (or only the named ones), and prints one "name value" pair on each line.
// A line "name:instructions value" is the number of instructions that the
// process ran for the number before it. core.py builds and runs it.
//
// A case makes what it needs before it measures (a view with the document,
// the view at the end), and that part is not measured. So a case gives the
// same work when it runs alone, for a profile of one step:
//
//   xcrun xctrace record --template 'Time Profiler' --launch -- \
//       build/bench/mdcore-bench long.md --case scroll
//
// Each measured step is a signpost interval ("step", subsystem
// sh.pluk.md-preview.bench, Points of Interest), so the profile shows
// where it starts and ends.
//
// The layer is not on a screen. A draw still waits for a free drawable, so
// the cost of a frame is the CPU time of this thread, not the time on the
// clock: the display list, the glyph bitmaps, and the commands sent to
// the GPU. The instructions are of all threads of the process.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <malloc/malloc.h>
#include <os/signpost.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <sys/resource.h>
#include <time.h>
#include "mdcore.h"

static const double VIEW_WIDTH = 900, VIEW_HEIGHT = 800, VIEW_SCALE = 2;
static const double SCROLL_STEP = 40;
// A scroll pass stops here, so that a long document gives the same number
// of frames in each run.
static const double SCROLL_LIMIT = 24000;
// The time between two frames of a 120 Hz display. A frame that needs more
// CPU time than this is late on such a display.
static const double FRAME_BUDGET_MS = 1000.0 / 120;

static double now_ms(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
}

static double thread_cpu_ms(void) {
    return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1e6;
}

static struct rusage_info_v4 process_usage(void) {
    struct rusage_info_v4 usage = {0};
    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage);
    return usage;
}

// Instructions that the process ran so far. Unlike a time, the number is
// almost the same on a busy Mac and on an efficiency core.
static uint64_t instructions(void) {
    return process_usage().ri_instructions;
}

// Memory that the process holds in the heap: the document, the layout, the
// glyph bitmaps, and the quads. The footprint of the process is no use
// here, because a layer that is not on a screen keeps its frames.
static double heap_mb(void) {
    malloc_statistics_t stats;
    malloc_zone_statistics(NULL, &stats);
    return stats.size_in_use / 1048576.0;
}

// One measured step: a signpost interval, and what it cost.
typedef struct {
    const char *name;
    os_signpost_id_t sign;
    double wall, cpu;
    uint64_t instructions;
} Span;

typedef struct {
    double wall_ms, cpu_ms, instructions;
} Cost;

// The clock of a number: the time that passed, or the CPU time of this
// thread, for a step with frames, which wait for the display.
typedef enum { WALL, CPU } Clock;

static os_log_t signposts;

static Span span_begin(const char *name) {
    Span span = {.name = name, .sign = os_signpost_id_generate(signposts)};
    os_signpost_interval_begin(signposts, span.sign, "step", "%{public}s", name);
    span.instructions = instructions();
    span.wall = now_ms();
    span.cpu = thread_cpu_ms();
    return span;
}

static Cost span_end(Span span) {
    Cost cost = {.wall_ms = now_ms() - span.wall, .cpu_ms = thread_cpu_ms() - span.cpu};
    cost.instructions = (double)(instructions() - span.instructions);
    os_signpost_interval_end(signposts, span.sign, "step");
    return cost;
}

// A number, and the instructions for it.
static void print_cost(const char *name, double value, double instructions) {
    printf("%s %.3f\n", name, value);
    printf("%s:instructions %.0f\n", name, instructions);
}

// Ends a step and prints it under its name, as the cost of one of
// `count` equal parts (the keys of a step that types some).
static void span_print(Span span, Clock clock, int count) {
    Cost cost = span_end(span);
    print_cost(span.name, (clock == CPU ? cost.cpu_ms : cost.wall_ms) / count, cost.instructions / count);
}

static int by_value(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// The value below which the given share of the sorted values is.
static double percentile(const double *sorted, int count, double share) {
    return sorted[(int)(share * (count - 1) + 0.5)];
}

// The middle one of some values, which it puts in order.
static double median(double *values, int count) {
    qsort(values, (size_t)count, sizeof(double), by_value);
    return values[count / 2];
}

static void draw(void *ctx, double y) {
    @autoreleasepool {
        mdcore_draw(ctx, y);
    }
}

// A view with the document and its first frame.
static void *open_view(NSData *source) {
    void *ctx = mdcore_create((__bridge void *)[CAMetalLayer layer]);
    mdcore_set_markdown(ctx, source.bytes, (long)source.length);
    mdcore_resize(ctx, VIEW_WIDTH, VIEW_HEIGHT, VIEW_SCALE);
    draw(ctx, 0);
    return ctx;
}

// To the end of the document, as the End key does, and the first frame
// there. Returns the scroll position.
static double go_to_end(void *ctx) {
    mdcore_layout_end(ctx);
    double top = 0, height = 0;
    mdcore_page_area(ctx, &top, &height);
    double bottom = top + height - VIEW_HEIGHT;
    if (bottom < top) bottom = top;
    draw(ctx, bottom);
    mdcore_note_scroll(ctx, bottom);
    return bottom;
}

// Where a scroll pass from the top ends.
static double scroll_end(void *ctx) {
    double top = 0, height = 0;
    mdcore_page_area(ctx, &top, &height);
    double end = height - VIEW_HEIGHT;
    if (end < 0) end = 0;
    return end > SCROLL_LIMIT ? SCROLL_LIMIT : end;
}

// Scrolls from the top in steps and prints the CPU time of a frame: the
// mean, the median, the value that 99 of 100 frames are below, the
// longest, and how many frames are late on a 120 Hz display. The mean
// alone hides a slow frame, and the longest is one frame of one run.
static void scroll_pass(void *ctx, const char *name, double end) {
    int capacity = (int)(end / SCROLL_STEP) + 2, frames = 0, late = 0;
    double *took = malloc(sizeof(double) * (size_t)capacity);
    double total = 0;
    Span span = span_begin(name);
    // One look at the clock for each frame: the end of a frame is the
    // start of the next one.
    double start = thread_cpu_ms();
    for (double y = 0; y <= end && frames < capacity; y += SCROLL_STEP) {
        draw(ctx, y);
        double now = thread_cpu_ms();
        took[frames] = now - start;
        start = now;
        total += took[frames];
        late += took[frames] > FRAME_BUDGET_MS;
        frames += 1;
    }
    Cost cost = span_end(span);
    qsort(took, (size_t)frames, sizeof(double), by_value);
    char line[96];
    snprintf(line, sizeof line, "%s_frame_cpu_ms", name);
    print_cost(line, total / frames, cost.instructions / frames);
    printf("%s_median_frame_cpu_ms %.3f\n", name, percentile(took, frames, 0.5));
    printf("%s_p99_frame_cpu_ms %.3f\n", name, percentile(took, frames, 0.99));
    printf("%s_longest_frame_cpu_ms %.2f\n", name, took[frames - 1]);
    printf("%s_late_frames %d\n", name, late);
    printf("%s_frames %d\n", name, frames);
    free(took);
}

// The keys that move the caret, through all of a document: each step to
// the right is later in the source and each one to the left earlier,
// each line down is lower on the page and each line up higher, and the
// caret gets from one end of the document to the other. Returns what is
// wrong, or NULL.
// Up from a line that is only a list mark, through the empty lines above
// it, into the list: those lines are none in the list once the caret has
// left the mark, and the caret is where typed text goes.
static const char *list_caret_check(void) {
    void *ctx = open_view([@"- a\n\n\n-\n" dataUsingEncoding:NSUTF8StringEncoding]);
    mdcore_caret_set(ctx, 0, 0);
    mdcore_caret_move(ctx, MDCORE_MOVE_DOCUMENT_END, false);
    mdcore_caret_move(ctx, MDCORE_MOVE_LEFT, false);
    draw(ctx, 0);
    mdcore_caret_move(ctx, MDCORE_MOVE_UP, false);
    draw(ctx, 0);
    mdcore_insert(ctx, "q", 1);
    long n = 0;
    const char *out = mdcore_source(ctx, &n);
    const char *want = "- aq\n\n\n-\n";
    bool same = n == (long)strlen(want) && memcmp(out, want, (size_t)n) == 0;
    mdcore_destroy(ctx);
    return same ? NULL : "text typed after Up from a list mark is not where the caret is";
}

// A code block that is typed, with the keys of a reader: the fence,
// Return, the code, and a closing fence, which takes the caret out of the
// code (a second block that is typed after it is a block of its own);
// the same in a list item; typed text and Return in a block with no line
// of code between its two fences; and a delete ("\b") that takes code
// with no text out. Returns what is wrong, or NULL.
static const char *typed_code_check(void) {
    struct { const char *start; double click_y; const char *keys; const char *want; } cases[] = {
        {"Text\n", -1, "\n```\nab\nc", "Text\n\n```\nab\nc\n```\n"},
        {"Text\n", -1, "\n```\nx\n``````\nz\n```q", "Text\n\n```\nx\n```\n\n```\nz\n```\n\nq\n"},
        {"- item\n", -1, "\n```\nx\ny", "- item\n- ```\n  x\n  y\n  ```\n"},
        {"Text\n\nMore\n", -1, "\n```abc", "Text\n\n```\nabc\n```\n\nMore\n"},
        {"Text\n\nMore\n", -1, "\n```\nabc", "Text\n\n```\nabc\n```\n\nMore\n"},
        {"Text\n\nMore\n", -1, "\n```ab\b\b\bq", "Text\n\nq\n\nMore\n"},
        {"Text\n", -1, "\n```ab\vq", "Text\n\n```\nab\n```\n\nq\n"},
        {"```\nx\n```\n```\n```\n", 96, "\bq", "```\nx\n```\n\nq\n"},
        {"a\n```\n```\nb\n", 60, "\bq", "aq\n\nb\n"},
        {"Text\n\n```\nx\n```\n", -1, "\a\fq", "```\nq\n```"},
        {"```\nx\n```\n\nText\n", -1, "\a\fq", "```\nq\n```"},
        {"- a\n- b\n", -1, "\n```\nx\n```q", "- a\n- ```\n  xq\n  ```\n- b\n"},
        {"Text\n\nPara\n\n```\ncode\n```\n\nEnd\n", -1, "\n```\nx", "Text\n\n```\nx\n```\n\nPara\n\n```\ncode\n```\n\nEnd\n"},
        {"Text\n\n```\n```\n\nMore\n", 76, "z\nw", "Text\n\n```\nz\nw\n```\n\nMore\n"},
        {"Text\n\n```\n```\n\nMore\n", 76, "\nq\nr", "Text\n\n```\nq\nr\n```\n\nMore\n"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        void *ctx = mdcore_create((__bridge void *)[CAMetalLayer layer]);
        mdcore_set_markdown(ctx, cases[i].start, (long)strlen(cases[i].start));
        mdcore_resize(ctx, VIEW_WIDTH, VIEW_HEIGHT, VIEW_SCALE);
        @autoreleasepool { mdcore_draw(ctx, 0); }
        if (cases[i].click_y < 0) {
            mdcore_caret_set(ctx, 0, 0);
            mdcore_caret_move(ctx, MDCORE_MOVE_LINE_END, false);
        } else {
            mdcore_caret_set(ctx, 100, cases[i].click_y);
        }
        for (const char *key = cases[i].keys; *key; key++) {
            if (*key == '\n') mdcore_insert_break(ctx);
            else if (*key == '\b') mdcore_delete(ctx, MDCORE_MOVE_LEFT);
            else if (*key == '\a') mdcore_select_all(ctx);
            else if (*key == '\f') mdcore_paste(ctx, "```", 3);
            else if (*key == '\v') { if (!mdcore_caret_move(ctx, MDCORE_MOVE_DOWN, false)) mdcore_paragraph_below(ctx); }
            else mdcore_insert(ctx, key, 1);
            @autoreleasepool { mdcore_draw(ctx, 0); }
        }
        long n = 0;
        const char *out = mdcore_source(ctx, &n);
        bool same = n == (long)strlen(cases[i].want) && memcmp(out, cases[i].want, (size_t)n) == 0;
        // Undo takes each step back, to the source at the start.
        while (mdcore_can_undo(ctx)) mdcore_undo(ctx);
        out = mdcore_source(ctx, &n);
        bool back = n == (long)strlen(cases[i].start) && memcmp(out, cases[i].start, (size_t)n) == 0;
        mdcore_destroy(ctx);
        if (!same) return "text typed in a new code block is not in its code";
        if (!back) return "Undo after a typed code block does not give the source back";
    }
    return NULL;
}

// The first caret of an editor: at the start of the first line that is
// all in a range of the page, not at a line that the top of the range
// cuts.
static const char *first_caret_check(void) {
    void *ctx = mdcore_create((__bridge void *)[CAMetalLayer layer]);
    const char *start = "one\n\ntwo\n\nthree\n";
    mdcore_set_markdown(ctx, start, (long)strlen(start));
    mdcore_resize(ctx, VIEW_WIDTH, VIEW_HEIGHT, VIEW_SCALE);
    @autoreleasepool { mdcore_draw(ctx, 0); }
    const char *wrong = NULL;
    double x = 0, y = 0, height = 0, cut = 0;
    if (!mdcore_caret_set_in(ctx, 0, VIEW_HEIGHT) || !mdcore_caret_rect(ctx, &x, &y, &height) || mdcore_caret_offset(ctx) != 0) {
        wrong = "the first caret is not at the start of the first line";
    } else {
        // The top of the range is in the first line.
        cut = y + 2;
        mdcore_caret_clear(ctx);
        if (!mdcore_caret_set_in(ctx, cut, VIEW_HEIGHT) || !mdcore_caret_rect(ctx, &x, &y, &height) || y < cut || y + height > VIEW_HEIGHT) {
            wrong = "the first caret is in a line that is not all in the view";
        } else {
            mdcore_insert(ctx, "q", 1);
            long n = 0;
            const char *out = mdcore_source(ctx, &n);
            const char *want = "one\n\nqtwo\n\nthree\n";
            if (n != (long)strlen(want) || memcmp(out, want, (size_t)n) != 0) wrong = "the first caret is not at the start of the first line that shows";
        }
    }
    mdcore_destroy(ctx);
    return wrong;
}

static const char *caret_walk(void *ctx, long length) {
    const char *list_wrong = list_caret_check();
    if (list_wrong != NULL) return list_wrong;
    const char *code_wrong = typed_code_check();
    if (code_wrong != NULL) return code_wrong;
    const char *first_wrong = first_caret_check();
    if (first_wrong != NULL) return first_wrong;
    // The source before the first change, for Undo at the end.
    long first_size = 0;
    const char *first_bytes = mdcore_source(ctx, &first_size);
    NSData *first_source = [NSData dataWithBytes:first_bytes length:(NSUInteger)first_size];
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
        } else if (from != last) {
            return "no step with the selection from a place that is not the end";
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
    // The text of Select All before the delete, and the source right
    // after it (Select All can leave what does not show: link
    // definitions).
    mdcore_select_all(ctx);
    const char *all = mdcore_selection_text(ctx, &selected);
    NSData *all_text = [NSData dataWithBytes:all length:(NSUInteger)(all != NULL ? selected : 0)];
    mdcore_delete(ctx, MDCORE_MOVE_LEFT);
    NSData *deleted = [NSData dataWithBytes:mdcore_source(ctx, &size) length:(NSUInteger)size];
    mdcore_select_all(ctx);
    if (mdcore_selection_text(ctx, &selected) != NULL && selected > 0) return "text is there after a delete of all of it";
    // Undo of a change over a selection selects all of that text again,
    // and Redo makes the same source as the change.
    if (!mdcore_undo(ctx)) return "no Undo after a delete of all of the text";
    NSData *whole = [NSData dataWithBytes:mdcore_source(ctx, &size) length:(NSUInteger)size];
    const char *back_text = mdcore_selection_text(ctx, &selected);
    if (back_text == NULL ? all_text.length != 0 : ((NSUInteger)selected != all_text.length || memcmp(back_text, all_text.bytes, all_text.length) != 0)) return "Undo of a delete of a selection does not select that text again";
    if (!mdcore_redo(ctx)) return "no Redo after an Undo";
    source = mdcore_source(ctx, &now);
    if ((NSUInteger)now != deleted.length || memcmp(source, deleted.bytes, deleted.length) != 0) return "Redo did not make the source of the delete";
    if (mdcore_can_redo(ctx)) return "Redo has a change after the last one";
    mdcore_undo(ctx);
    source = mdcore_source(ctx, &now);
    if (now != size || memcmp(source, whole.bytes, (size_t)size) != 0) return "Undo after Redo did not give the same text";
    // Each change of this walk taken back gives the source that the
    // walk started with, byte for byte; made again, the source of the
    // delete; and taken back again, the first one.
    long undone = 1;
    while (mdcore_undo(ctx)) undone++;
    source = mdcore_source(ctx, &now);
    if (now != first_size || memcmp(source, first_source.bytes, (size_t)now) != 0) return "Undo of each change did not give the first source";
    if (mdcore_can_undo(ctx)) return "Undo has a change at the first source";
    long again = 0;
    while (mdcore_redo(ctx)) again++;
    source = mdcore_source(ctx, &now);
    if (again != undone) return "Redo has another count of changes than Undo";
    if ((NSUInteger)now != deleted.length || memcmp(source, deleted.bytes, deleted.length) != 0) return "Redo of each change did not make the source of the delete";
    while (mdcore_undo(ctx)) {
    }
    source = mdcore_source(ctx, &now);
    if (now != first_size || memcmp(source, first_source.bytes, (size_t)now) != 0) return "Undo a second time did not give the first source";
    return NULL;
}

// The same text with one paragraph more in its middle, as another program
// puts it in the file. `at`, when given, gets where the paragraph starts.
static NSData *changed_source(NSData *source, NSUInteger *at) {
    NSMutableData *changed = [source mutableCopy];
    NSRange middle = [source rangeOfData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]
                                 options:0
                                   range:NSMakeRange(source.length / 2, source.length / 2)];
    NSData *more = [@"\n\nA paragraph that another program put in the file.\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    // At the end for a text with no blank line in its second half, so the
    // text is another one in each case.
    NSUInteger start = middle.location != NSNotFound ? middle.location : changed.length;
    [changed replaceBytesInRange:NSMakeRange(start, 0) withBytes:more.bytes length:more.length];
    if (at != NULL) *at = start;
    return changed;
}

// The start of the system (Metal, the shaders, the first font), then the
// document: the parse, and the layout of the first view with its frame.
// The first view two times: in the first one the fonts and the glyphs of
// the document are new to the process, as when the app opens it; the
// later ones have them, and so change less from run to run.
static bool case_open(NSData *source) {
    enum { ROUNDS = 5 };
    Span startup = span_begin("startup_ms");
    void *first = open_view([@"a\n" dataUsingEncoding:NSUTF8StringEncoding]);
    span_print(startup, WALL, 1);
    mdcore_destroy(first);

    double parse[ROUNDS], view[ROUNDS], parse_instructions[ROUNDS], view_instructions[ROUNDS];
    for (int round = 0; round < ROUNDS; round++) {
        void *ctx = mdcore_create((__bridge void *)[CAMetalLayer layer]);
        Span span = span_begin("parse_ms");
        mdcore_set_markdown(ctx, source.bytes, (long)source.length);
        Cost cost = span_end(span);
        parse[round] = cost.wall_ms;
        parse_instructions[round] = cost.instructions;
        span = span_begin(round == 0 ? "first_view_ms" : "first_view_again_ms");
        mdcore_resize(ctx, VIEW_WIDTH, VIEW_HEIGHT, VIEW_SCALE);
        draw(ctx, 0);
        cost = span_end(span);
        view[round] = cost.wall_ms;
        view_instructions[round] = cost.instructions;
        if (round == 0) {
            print_cost("first_view_ms", cost.wall_ms, cost.instructions);
            printf("first_frame_heap_mb %.2f\n", heap_mb());
        }
        mdcore_destroy(ctx);
    }
    print_cost("parse_ms", median(parse, ROUNDS), median(parse_instructions, ROUNDS));
    print_cost("first_view_again_ms", median(view + 1, ROUNDS - 1), median(view_instructions + 1, ROUNDS - 1));
    return true;
}

// Two scroll passes from the top: the first lays out what it comes to and
// makes the glyph bitmaps, the second has them. Between them a jump back
// to the top in one frame, as the Home key does: the text there is shaped
// again.
static bool case_scroll(NSData *source) {
    void *ctx = open_view(source);
    double end = scroll_end(ctx);
    scroll_pass(ctx, "first_scroll", end);
    Span span = span_begin("jump_frame_cpu_ms");
    draw(ctx, 0);
    span_print(span, CPU, 1);
    scroll_pass(ctx, "second_scroll", end);
    printf("scrolled_heap_mb %.2f\n", heap_mb());
    mdcore_destroy(ctx);
    return true;
}

// To the end of the document, as the End key does: the layout there and
// the first frame. Then a new width with the reader at the end, as one
// step of a live resize: the new layout, which keeps the reader's place,
// and the frame at the same scroll position.
static bool case_end(NSData *source) {
    enum { WIDTHS = 5 };
    void *ctx = open_view(source);
    Span span = span_begin("end_frame_ms");
    double bottom = go_to_end(ctx);
    span_print(span, WALL, 1);

    double took[WIDTHS], counted[WIDTHS];
    for (int width = 0; width < WIDTHS; width++) {
        span = span_begin("resize_at_end_ms");
        mdcore_note_scroll(ctx, bottom);
        mdcore_resize(ctx, VIEW_WIDTH - (width % 2 == 0 ? 40 : 0), VIEW_HEIGHT, VIEW_SCALE);
        draw(ctx, bottom);
        Cost cost = span_end(span);
        took[width] = cost.wall_ms;
        counted[width] = cost.instructions;
    }
    print_cost("resize_at_end_ms", median(took, WIDTHS), median(counted, WIDTHS));
    mdcore_destroy(ctx);
    return true;
}

// The file changed outside the app, with the reader at the end: the same
// text with a paragraph more in its middle. The core compares the blocks,
// makes one part again, and draws at the same position.
static bool case_change(NSData *source) {
    void *ctx = open_view(source);
    double bottom = go_to_end(ctx);
    NSData *changed = changed_source(source, NULL);
    Span span = span_begin("change_ms");
    mdcore_set_markdown(ctx, changed.bytes, (long)changed.length);
    draw(ctx, bottom);
    span_print(span, WALL, 1);
    mdcore_destroy(ctx);
    return true;
}

// Keys that are typed, one character each, as an editor gives them: the
// range of the source that changes, and the frame after it. CPU time: a
// frame waits for the display. The view is at the end of the text with
// the paragraph more in its middle (changed_source).
static bool case_type(NSData *source) {
    enum { KEYS = 10 };
    NSUInteger at = 0;
    NSData *changed = changed_source(source, &at);
    void *ctx = open_view(changed);
    double bottom = go_to_end(ctx);

    // First into the paragraph in the middle: in a long text the view at
    // the end does not show it, and the frame has no layout of it.
    Span span = span_begin("type_middle_cpu_ms");
    for (int key = 0; key < KEYS; key++) {
        long caret = (long)at + 4 + key;
        mdcore_replace_text(ctx, caret, caret, "x", 1);
        draw(ctx, bottom);
    }
    span_print(span, CPU, KEYS);

    // Then at the end of the last line of the text, which the view shows:
    // the frame lays out the part of the text that changed. The end of
    // the last line that is text of the page: not an empty line, and not
    // the definition of a link ("[name]: target"), which shows nothing
    // and changes text at other places.
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
    span = span_begin("type_end_cpu_ms");
    for (int key = 0; key < KEYS; key++) {
        // The keys before are in the text too.
        long caret = last + KEYS + key;
        mdcore_replace_text(ctx, caret, caret, "x", 1);
        draw(ctx, bottom);
    }
    span_print(span, CPU, KEYS);

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
    span = span_begin("type_caret_cpu_ms");
    for (int key = 0; caret && key < KEYS; key++) {
        mdcore_insert(ctx, "x", 1);
        draw(ctx, bottom);
    }
    span_print(span, CPU, KEYS);
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
        return false;
    }
    // The keys that move the caret: each step, and the frame after it.
    // A step and the step back give the place of before, the caret of a
    // line below is lower, and a step with the selection selects text.
    long home = mdcore_caret_offset(ctx);
    bool moves = true;
    span = span_begin("caret_move_cpu_ms");
    for (int key = 0; key < KEYS; key++) {
        moves = mdcore_caret_move(ctx, key % 2 == 0 ? MDCORE_MOVE_LEFT : MDCORE_MOVE_RIGHT, false) && moves;
        draw(ctx, bottom);
    }
    span_print(span, CPU, KEYS);
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
        return false;
    }
    mdcore_destroy(ctx);
    return true;
}

// Select All and a copy of all of the text, with the view at the end: the
// two take the text from the document, with no layout.
static bool case_select(NSData *source) {
    void *ctx = open_view(source);
    go_to_end(ctx);
    Span span = span_begin("select_all_ms");
    mdcore_select_all(ctx);
    span_print(span, WALL, 1);
    span = span_begin("copy_all_ms");
    long copied = 0;
    mdcore_selection_text(ctx, &copied);
    span_print(span, WALL, 1);
    mdcore_destroy(ctx);
    return true;
}

// All of the document laid out, by frames from the top to the end. A
// frame lays out two and a half view heights below its scroll position,
// so a step of two view heights reaches the end of the page. CPU time: a
// frame waits for the display.
static bool case_layout(NSData *source) {
    void *ctx = open_view(source);
    // The height is an estimate for what no frame showed yet.
    double top = 0, estimate = 0;
    mdcore_page_area(ctx, &top, &estimate);
    Span span = span_begin("full_layout_cpu_ms");
    double y = top;
    for (;;) {
        double page_top = 0, page_height = 0;
        mdcore_page_area(ctx, &page_top, &page_height);
        if (y >= page_top + page_height) break;
        draw(ctx, y);
        y += 2 * VIEW_HEIGHT;
    }
    span_print(span, CPU, 1);
    // How far the height of the page was from the real one, with only
    // the first view laid out.
    double real = 0;
    mdcore_page_area(ctx, &top, &real);
    printf("estimate_error_percent %.1f\n", real > 0 ? (estimate - real) / real * 100 : 0);
    printf("heap_mb %.2f\n", heap_mb());
    mdcore_destroy(ctx);
    return true;
}

// The first two views of a process, made by two threads at the same
// time, as when a host warms the renderer on a thread of its own while
// its main thread makes the view of a document. Each thread makes its
// view, draws a frame, and reads the height of its page. What the views
// share (the start of the runtime, the Metal device and pipeline) is
// made one time; with two starts at once this can crash, hang, or give a
// view with no layout. Must run before each other view of the process.
static atomic_bool first_views_go;
static void *first_view_thread(void *source) {
    while (!atomic_load(&first_views_go)) {
    }
    double top = 0, height = 0;
    @autoreleasepool {
        void *ctx = open_view((__bridge NSData *)source);
        mdcore_page_area(ctx, &top, &height);
        mdcore_destroy(ctx);
    }
    return height > 0 ? source : NULL;
}

static const char *two_first_views_check(NSData *source) {
    pthread_t threads[2];
    for (int index = 0; index < 2; index++) {
        if (pthread_create(&threads[index], NULL, first_view_thread, (__bridge void *)source) != 0) return "no thread for a first view";
    }
    atomic_store(&first_views_go, true);
    bool both = true;
    for (int index = 0; index < 2; index++) {
        void *made = NULL;
        pthread_join(threads[index], &made);
        both = both && made != NULL;
    }
    return both ? NULL : "one of two first views at the same time has no page";
}

static const struct {
    const char *name;
    bool (*run)(NSData *source);
} CASES[] = {
    {"open", case_open},     {"scroll", case_scroll}, {"end", case_end},       {"change", case_change},
    {"type", case_type},     {"select", case_select}, {"layout", case_layout},
};
enum { CASE_COUNT = sizeof CASES / sizeof CASES[0] };

static int usage(void) {
    fprintf(stderr, "usage: mdcore-bench <file.md> [--case <name>]... [--caret-walk]\ncases:");
    for (int index = 0; index < CASE_COUNT; index++) fprintf(stderr, " %s", CASES[index].name);
    fprintf(stderr, "\n");
    return 2;
}

int main(int argc, const char *argv[]) {
    if (argc < 2) return usage();
    bool walk = false, chosen[CASE_COUNT] = {false}, any = false;
    for (int arg = 2; arg < argc; arg++) {
        if (strcmp(argv[arg], "--caret-walk") == 0) {
            walk = true;
            continue;
        }
        if (strcmp(argv[arg], "--case") != 0 || ++arg == argc) return usage();
        int index = 0;
        while (index < CASE_COUNT && strcmp(argv[arg], CASES[index].name) != 0) index++;
        if (index == CASE_COUNT) return usage();
        chosen[index] = any = true;
    }
    // The class of an app's main thread. Without it the system can run the
    // program on an efficiency core, where the same work takes three times
    // the CPU time.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    signposts = os_log_create("sh.pluk.md-preview.bench", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
    NSData *source = [NSData dataWithContentsOfFile:@(argv[1])];
    if (source == nil) {
        fprintf(stderr, "cannot read %s\n", argv[1]);
        return 1;
    }
    if (walk) {
        const char *apart = two_first_views_check(source);
        if (apart != NULL) {
            fprintf(stderr, "the first views of %s: %s\n", argv[1], apart);
            return 1;
        }
        void *ctx = open_view(source);
        const char *wrong = caret_walk(ctx, (long)source.length);
        if (wrong != NULL) {
            fprintf(stderr, "the caret in %s: %s\n", argv[1], wrong);
            return 1;
        }
        return 0;
    }
    printf("source_kb %.0f\n", source.length / 1024.0);
    for (int index = 0; index < CASE_COUNT; index++) {
        if (any && !chosen[index]) continue;
        // The layers and the other objects of a case go when it ends.
        @autoreleasepool {
            if (!CASES[index].run(source)) return 1;
        }
    }
    // Of all of the run, with what each case made before it measured.
    struct rusage_info_v4 usage = process_usage();
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    double cpu_ns = (double)(usage.ri_user_time + usage.ri_system_time) * base.numer / base.denom;
    print_cost("total_cpu_ms", cpu_ns / 1e6, (double)usage.ri_instructions);
    return 0;
}
