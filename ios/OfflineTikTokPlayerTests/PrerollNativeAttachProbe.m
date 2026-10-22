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

static BOOL OPDebugAttachReceipt(NSString *operation, uint64_t token, BOOL calibration, NSException *exception,
    NSString *classification, NSString *calibrationCase) {
    NSMutableDictionary *record = [@{@"schema": @3, @"operation": operation, @"phase": @"classified-exception",
        @"token": @(token), @"pid": @(getpid()), @"calibration": @(calibration),
        @"nativeOutcome": classification, @"calibrationCase": calibrationCase,
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
        BOOL written = OPDebugAttachReceipt(operation, token, calibration, exception,
            @"operation-exception", @"not-an-attachment-classification");
        if (observedException) { *observedException = exception; }
        if (exceptionReceiptWritten) { *exceptionReceiptWritten = written; }
        return NO;
    }
}

// Compare the ORIGINAL complete strings. The redacted/truncated public receipt
// is never an input to qualification. This classifier is used only by the
// direct non-nil replaceCurrentItemWithPlayerItem call below.
static NSString * const OPDebugOwnershipRejectionReason =
    @"An AVPlayerItem cannot be associated with more than one instance of AVPlayer";

static OPDebugNativeAttachmentOutcome OPDebugAttachmentExceptionOutcome(NSException *exception) {
    if ([exception.name isEqualToString:NSInvalidArgumentException]
        && [exception.reason isEqualToString:OPDebugOwnershipRejectionReason]) {
        return OPDebugNativeAttachmentOutcomeOwnershipRejected;
    }
    return OPDebugNativeAttachmentOutcomeUnexpectedException;
}

static NSString *OPDebugAttachmentOutcomeLabel(OPDebugNativeAttachmentOutcome outcome) {
    switch (outcome) {
        case OPDebugNativeAttachmentOutcomeAccepted: return @"accepted";
        case OPDebugNativeAttachmentOutcomeOwnershipRejected: return @"ownership-rejected";
        case OPDebugNativeAttachmentOutcomeUnexpectedException: return @"unexpected-exception";
        case OPDebugNativeAttachmentOutcomeObservationUnavailable: return @"observation-unavailable";
    }
    return @"invalid-enum";
}

static OPDebugNativeAttachmentOutcome OPDebugClassifyAttachment(AVPlayer *player, AVPlayerItem *item,
    uint64_t token, NSString *calibrationCase, NSException **observedException, BOOL *exceptionReceiptWritten) {
    @try {
        // The native operation and its catch are wholly Objective-C; no Swift
        // block can intervene, and this observer never substitutes another item.
        [player replaceCurrentItemWithPlayerItem:item];
        return OPDebugNativeAttachmentOutcomeAccepted;
    } @catch (NSException *exception) {
        OPDebugNativeAttachmentOutcome outcome = OPDebugAttachmentExceptionOutcome(exception);
        BOOL written = OPDebugAttachReceipt(@"attach-same-B", token, calibrationCase != nil, exception,
            OPDebugAttachmentOutcomeLabel(outcome), calibrationCase ?: @"not-calibration");
        if (observedException) { *observedException = exception; }
        if (exceptionReceiptWritten) { *exceptionReceiptWritten = written; }
        return written ? outcome : OPDebugNativeAttachmentOutcomeObservationUnavailable;
    }
}

OPDebugNativeAttachmentOutcome OPDebugClassifyPlayerAttachment(AVPlayer *player, AVPlayerItem *item, uint64_t token) {
    return OPDebugClassifyAttachment(player, item, token, nil, NULL, NULL);
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

static BOOL OPDebugCalibrateAttachmentCase(NSString *name, NSString *reason, NSString *calibrationCase,
    OPDebugNativeAttachmentOutcome expected) {
    OPDebugThrowingAttachmentPlayer *player = [[OPDebugThrowingAttachmentPlayer alloc] init];
    NSException *exception = [NSException exceptionWithName:name reason:reason userInfo:nil];
    player.calibrationException = exception;
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:[AVMutableComposition composition]];
    BOOL written = NO;
    NSException *observed = nil;
    OPDebugNativeAttachmentOutcome outcome = OPDebugNativeAttachmentOutcomeObservationUnavailable;
    player.armed = YES;
    @try {
        outcome = OPDebugClassifyAttachment(player, item, 0, calibrationCase, &observed, &written);
    } @finally {
        player.armed = NO;
        player.calibrationException = nil;
    }
    return outcome == expected && observed == exception && player.attachmentCalls == 1 && written;
}

BOOL OPDebugCalibrateNativeAttachProbe(void) {
    // Evaluate all three fixed cases, with separate calibration=true receipts.
    // A shared name or a shared reason alone is insufficient.
    BOOL exact = OPDebugCalibrateAttachmentCase(NSInvalidArgumentException, OPDebugOwnershipRejectionReason,
        @"exact-name-and-reason", OPDebugNativeAttachmentOutcomeOwnershipRejected);
    BOOL wrongReason = OPDebugCalibrateAttachmentCase(NSInvalidArgumentException,
        [OPDebugOwnershipRejectionReason stringByAppendingString:@" (synthetic suffix)"],
        @"wrong-reason", OPDebugNativeAttachmentOutcomeUnexpectedException);
    BOOL wrongName = OPDebugCalibrateAttachmentCase(@"OPDebugSyntheticAttachException", OPDebugOwnershipRejectionReason,
        @"wrong-name", OPDebugNativeAttachmentOutcomeUnexpectedException);
    return exact && wrongReason && wrongName;
}
