// Records when each XCTest case starts and ends, so CI can show which tests
// to speed up. `swift test --parallel` hides the per-test lines on success
// and its xUnit report gives every test the same time, so the suite records
// its own. Active only when MDP_TEST_TIMING names a file; each line is
// tab-separated: start, end (Unix seconds), seconds, result, pid, test.
// Test processes only append to the file, so delete it before a new run.
//
// Objective-C because only +load can register the observer before the first
// test runs; SwiftPM test bundles have no principal class to do it.

#import <XCTest/XCTest.h>
#include <fcntl.h>
#include <unistd.h>

@interface MDPTestTimingObserver : NSObject <XCTestObservation>
@end

@implementation MDPTestTimingObserver {
    int _fd;
    NSDate *_start;
}

+ (void)load {
    NSString *path = NSProcessInfo.processInfo.environment[@"MDP_TEST_TIMING"];
    if (path.length == 0) return;
    // O_APPEND keeps whole lines intact when parallel test processes share the file.
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    MDPTestTimingObserver *observer = [MDPTestTimingObserver new];
    observer->_fd = fd;
    [XCTestObservationCenter.sharedTestObservationCenter addTestObserver:observer];
}

- (void)testCaseWillStart:(XCTestCase *)testCase {
    _start = [NSDate date];
}

- (void)testCaseDidFinish:(XCTestCase *)testCase {
    NSDate *end = [NSDate date];
    NSString *result = testCase.testRun.hasSucceeded ? @"passed" : @"failed";
    NSString *line = [NSString stringWithFormat:@"%.3f\t%.3f\t%.3f\t%@\t%d\t%@\n",
        _start.timeIntervalSince1970, end.timeIntervalSince1970,
        [end timeIntervalSinceDate:_start], result, getpid(), testCase.name];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    write(_fd, data.bytes, data.length);
}

@end
