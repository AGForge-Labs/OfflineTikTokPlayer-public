#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Only a caught exception from the actual non-nil attachment call can be an
// ownership rejection. Other exceptions and missing receipts never qualify.
typedef NS_ENUM(NSInteger, OPDebugNativeAttachmentOutcome) {
    OPDebugNativeAttachmentOutcomeAccepted = 0,
    OPDebugNativeAttachmentOutcomeOwnershipRejected = 1,
    OPDebugNativeAttachmentOutcomeUnexpectedException = 2,
    OPDebugNativeAttachmentOutcomeObservationUnavailable = 3
};
FOUNDATION_EXPORT OPDebugNativeAttachmentOutcome OPDebugClassifyPlayerAttachment(AVPlayer *player, AVPlayerItem *item, uint64_t token)
    NS_SWIFT_NAME(OPDebugClassifyPlayerAttachment(_:item:token:));

// Cleanup/restoration still return NO for any caught exception. These boolean
// operations cannot authorize the typed ownership-refusal branch.
FOUNDATION_EXPORT BOOL OPDebugObservePlayerAttachment(AVPlayer *player, AVPlayerItem * _Nullable item, uint64_t token)
    NS_SWIFT_NAME(OPDebugObservePlayerAttachment(_:item:token:));
FOUNDATION_EXPORT BOOL OPDebugCancelPlayerPrerolls(AVPlayer *player, uint64_t token)
    NS_SWIFT_NAME(OPDebugCancelPlayerPrerolls(_:token:));
FOUNDATION_EXPORT BOOL OPDebugCanRestoreQueueItem(AVQueuePlayer *player, AVPlayerItem *item, AVPlayerItem *after, uint64_t token)
    NS_SWIFT_NAME(OPDebugCanRestoreQueueItem(_:item:after:token:));
FOUNDATION_EXPORT BOOL OPDebugRestoreQueueItem(AVQueuePlayer *player, AVPlayerItem *item, AVPlayerItem *after, uint64_t token)
    NS_SWIFT_NAME(OPDebugRestoreQueueItem(_:item:after:token:));
FOUNDATION_EXPORT BOOL OPDebugCalibrateNativeAttachProbe(void);

NS_ASSUME_NONNULL_END
