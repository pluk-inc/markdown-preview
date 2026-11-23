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

    double layout_start = now_ms();
    while (mdcore_layout_more(ctx, 0)) {
    }
    printf("full_layout_ms %.2f\n", now_ms() - layout_start);
    double height = mdcore_content_height(ctx);
    printf("page_height_pt %.0f\n", height);

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

    printf("heap_mb %.1f\n", heap_mb());
    printf("total_cpu_ms %.0f\n", cpu_ms());
    mdcore_destroy(ctx);
    return 0;
}
