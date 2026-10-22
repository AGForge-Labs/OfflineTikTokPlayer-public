#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Diagnostics only. An exception is observed and rethrown without recovery.
FOUNDATION_EXPORT void OPDebugObservePlayerAttachment(AVPlayer *player, AVPlayerItem *item, uint64_t token)
    NS_SWIFT_NAME(OPDebugObservePlayerAttachment(_:item:token:));
FOUNDATION_EXPORT BOOL OPDebugCalibrateNativeAttachProbe(void);

NS_ASSUME_NONNULL_END
