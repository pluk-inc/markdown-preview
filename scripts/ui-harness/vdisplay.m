// vdisplay — a headless virtual display for background UI checks.
//
// Creates a display with the private CGVirtualDisplay API. The display exists
// only while this process runs, and the process exits by itself after
// --timeout seconds, so a forgotten run cannot keep the display (and anything
// macOS moved onto it) around. Developer tool only: never link this into the app.
//
// Build: clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//          scripts/ui-harness/vdisplay.m -o <out>/vdisplay
// Usage: vdisplay [--width 1440] [--height 900] [--timeout 600]
// Prints one line: pid=<pid> displayID=<id> index=<n> origin=<x>,<y> size=<w>x<h>
// `index` is the number for `screencapture -D`.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static const char *argValue(int argc, const char *argv[], const char *name, const char *fallback) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) return argv[i + 1];
    }
    return fallback;
}

static uint32_t activeDisplays(CGDirectDisplayID ids[32]) {
    uint32_t count = 0;
    CGGetActiveDisplayList(32, ids, &count);
    return count;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int w = (unsigned int)atoi(argValue(argc, argv, "--width", "1440"));
        unsigned int h = (unsigned int)atoi(argValue(argc, argv, "--height", "900"));
        int timeout = atoi(argValue(argc, argv, "--timeout", "600"));
        if (timeout <= 0) { fprintf(stderr, "vdisplay: --timeout must be > 0\n"); return 1; }

        // Distinct serial per run, so parallel sessions get separate displays.
        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.queue = dispatch_get_main_queue();
        d.name = @"Headless Test Display";
        d.maxPixelsWide = w * 2;
        d.maxPixelsHigh = h * 2;
        d.sizeInMillimeters = CGSizeMake(w * 25.4 / 110.0, h * 25.4 / 110.0);
        d.vendorID = 0xEEEE;
        d.productID = 0x1234;
        d.serialNum = (unsigned int)getpid();
        d.terminationHandler = ^(id a, CGVirtualDisplay *b) { exit(0); };

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        if (!display) { fprintf(stderr, "vdisplay: could not create display\n"); return 1; }

        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.hiDPI = 1;
        s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        if (![display applySettings:s]) { fprintf(stderr, "vdisplay: could not apply settings\n"); return 1; }

        CGDirectDisplayID did = display.displayID;

        // Put the display on the side of the screen layout the Dock does not
        // use. The Dock moves to an outer display on its own edge, so a display
        // below a bottom Dock (or right of a right-side Dock) takes it.
        CGRect all = CGRectNull;
        CGDirectDisplayID ids[32];
        uint32_t n = activeDisplays(ids);
        for (uint32_t i = 0; i < n; i++) {
            if (ids[i] != did) all = CGRectUnion(all, CGDisplayBounds(ids[i]));
        }
        NSString *dock = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.dock"].dictionaryRepresentation[@"orientation"];
        int32_t x = [dock isEqualToString:@"right"] ? (int32_t)(CGRectGetMinX(all) - w) : (int32_t)CGRectGetMaxX(all);
        int32_t y = (int32_t)CGDisplayBounds(CGMainDisplayID()).origin.y;

        CGDisplayConfigRef cfg;
        CGBeginDisplayConfiguration(&cfg);
        CGConfigureDisplayOrigin(cfg, did, x, y);
        CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);

        // Report the screencapture -D index after macOS settles the layout.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CGDirectDisplayID list[32];
            uint32_t count = activeDisplays(list);
            int index = 0;
            for (uint32_t i = 0; i < count; i++) if (list[i] == did) index = (int)i + 1;
            CGRect b = CGDisplayBounds(did);
            printf("pid=%d displayID=%u index=%d origin=%d,%d size=%dx%d\n", getpid(), did, index,
                   (int)b.origin.x, (int)b.origin.y, (int)b.size.width, (int)b.size.height);
            fflush(stdout);
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(stderr, "vdisplay: timeout after %d s, removing display\n", timeout);
            exit(0);
        });
        dispatch_main();
    }
}
