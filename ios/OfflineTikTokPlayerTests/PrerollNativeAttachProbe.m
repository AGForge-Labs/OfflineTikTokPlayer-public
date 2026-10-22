#import "PrerollNativeAttachProbe.h"
#include <unistd.h>

// This test target runs only generated/public fixtures. Still omit path-like
// tokens, control characters and unbounded exception text from public receipts.
static NSString *OPDebugBoundedExceptionText(NSString *text, NSUInteger limit) {
    NSString *bounded = [text substringToIndex:MIN(text.length, limit)];
    NSRegularExpression *paths = [NSRegularExpression regularExpressionWithPattern:@"[^\\s]*[/\\\\][^\\s]*"
        options:0 error:nil];
    bounded = [paths stringByReplacingMatchesInString:bounded options:0
        range:NSMakeRange(0, bounded.length) withTemplate:@"<path>"];
    NSMutableString *safe = [NSMutableString stringWithCapacity:bounded.length];
    for (NSUInteger index = 0; index < bounded.length; index++) {
        unichar character = [bounded characterAtIndex:index];
        [safe appendFormat:@"%C", character >= 32 && character < 127 ? character : (unichar)'?'];
    }
    return safe;
}

static BOOL OPDebugAttachReceipt(NSString *operation, uint64_t token, BOOL calibration, NSException *exception) {
    NSMutableDictionary *record = [@{@"schema": @2, @"operation": operation, @"phase": @"classified-exception",
        @"token": @(token), @"pid": @(getpid()), @"calibration": @(calibration),
        @"operationSucceeded": @NO, @"unwindsSwift": @NO, @"stdoutDeliveryAcknowledged": @NO} mutableCopy];
    if (exception) {
        record[@"exceptionName"] = OPDebugBoundedExceptionText(exception.name, 96);
        record[@"exceptionReason"] = OPDebugBoundedExceptionText(exception.reason ?: @"", 384);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (!json) { return NO; }
    NSMutableData *line = [[@"PrerollNativeAttachBoundary " dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [line appendData:json];
    [line appendBytes:"\n" length:1];
    if (line.length > 4096) { return NO; }
    return write(STDERR_FILENO, line.bytes, line.length) == (ssize_t)line.length;
}

// Every block is created below in Objective-C, never supplied from Swift.
static BOOL OPDebugObserveOperation(NSString *operation, uint64_t token, BOOL calibration,
    void (^nativeOperation)(void), NSException **observedException, BOOL *exceptionReceiptWritten) {
    @try {
        nativeOperation();
        return YES;
    } @catch (NSException *exception) {
        BOOL written = OPDebugAttachReceipt(operation, token, calibration, exception);
        if (observedException) { *observedException = exception; }
        if (exceptionReceiptWritten) { *exceptionReceiptWritten = written; }
        return NO;
    }
}

BOOL OPDebugObservePlayerAttachment(AVPlayer *player, AVPlayerItem *item, uint64_t token) {
    return OPDebugObserveOperation(item ? @"attach-same-B" : @"cleanup-detach", token, NO,
        ^{ [player replaceCurrentItemWithPlayerItem:item]; }, NULL, NULL);
}

BOOL OPDebugCancelPlayerPrerolls(AVPlayer *player, uint64_t token) {
    return OPDebugObserveOperation(@"cleanup-cancel", token, NO,
        ^{ [player cancelPendingPrerolls]; }, NULL, NULL);
}

BOOL OPDebugCanRestoreQueueItem(AVQueuePlayer *player, AVPlayerItem *item, AVPlayerItem *after, uint64_t token) {
    __block BOOL canInsert = NO;
    BOOL returned = OPDebugObserveOperation(@"can-insert-same-B", token, NO,
        ^{ canInsert = [player canInsertItem:item afterItem:after]; }, NULL, NULL);
    return returned && canInsert;
}

BOOL OPDebugRestoreQueueItem(AVQueuePlayer *player, AVPlayerItem *item, AVPlayerItem *after, uint64_t token) {
    return OPDebugObserveOperation(@"reinsert-same-B-after-same-A", token, NO,
        ^{ [player insertItem:item afterItem:after]; }, NULL, NULL);
}

// Calibrate classified failure, bounded receipt and original exception identity
// wholly in Objective-C; no exception crosses Swift.
@interface OPDebugThrowingAttachmentPlayer : AVPlayer
@property(nonatomic, strong) NSException *calibrationException;
@property(nonatomic) NSUInteger attachmentCalls;
@property(nonatomic) BOOL armed;
@end

@implementation OPDebugThrowingAttachmentPlayer
- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    if (!self.armed) { [super replaceCurrentItemWithPlayerItem:item]; return; }
    self.attachmentCalls += 1;
    @throw self.calibrationException;
}
@end

BOOL OPDebugCalibrateNativeAttachProbe(void) {
    OPDebugThrowingAttachmentPlayer *player = [[OPDebugThrowingAttachmentPlayer alloc] init];
    NSException *exception = [NSException exceptionWithName:@"OPDebugSyntheticAttachException"
        reason:@"synthetic /private/fixture.mp4\nrethrow calibration" userInfo:nil];
    player.calibrationException = exception;
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:[AVMutableComposition composition]];
    BOOL written = NO;
    NSException *observed = nil;
    BOOL succeeded = NO;
    player.armed = YES;
    @try {
        succeeded = OPDebugObserveOperation(@"attach-same-B", 0, YES,
            ^{ [player replaceCurrentItemWithPlayerItem:item]; }, &observed, &written);
    } @finally {
        player.armed = NO;
        player.calibrationException = nil;
    }
    return !succeeded && observed == exception && player.attachmentCalls == 1 && written;
}
