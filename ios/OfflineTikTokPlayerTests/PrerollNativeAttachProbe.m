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

static BOOL OPDebugAttachReceipt(NSString *phase, uint64_t token, BOOL calibration, NSException *exception) {
    NSMutableDictionary *record = [@{@"schema": @1, @"operation": @"attach-same-B", @"phase": phase,
        @"token": @(token), @"pid": @(getpid()), @"calibration": @(calibration),
        @"swallowsException": @NO, @"stdoutDeliveryAcknowledged": @NO} mutableCopy];
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

static void OPDebugObserveAttachment(AVPlayer *player, AVPlayerItem *item, uint64_t token,
                                     BOOL calibration, BOOL *exceptionReceiptWritten) {
    @try {
        // No Swift closure/frame intervenes between this call and its catch.
        [player replaceCurrentItemWithPlayerItem:item];
    } @catch (NSException *exception) {
        BOOL written = OPDebugAttachReceipt(@"exception-rethrow", token, calibration, exception);
        if (exceptionReceiptWritten) { *exceptionReceiptWritten = written; }
        @throw;
    }
}

void OPDebugObservePlayerAttachment(AVPlayer *player, AVPlayerItem *item, uint64_t token) {
    OPDebugObserveAttachment(player, item, token, NO, NULL);
}

// Calibrate the same observer's catch, bounded receipt and unchanged exception
// identity wholly in Objective-C; no exception crosses Swift during calibration.
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
    player.armed = YES;
    @try {
        OPDebugObserveAttachment(player, item, 0, YES, &written);
    } @catch (NSException *observed) {
        return observed == exception && player.attachmentCalls == 1 && written;
    } @finally {
        player.armed = NO;
        player.calibrationException = nil;
    }
    return NO;
}
