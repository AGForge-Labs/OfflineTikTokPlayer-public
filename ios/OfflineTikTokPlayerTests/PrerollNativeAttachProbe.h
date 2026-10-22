#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Diagnostics only. NO classifies a rejected operation; it never authorizes
// successful setup or recovery. No native exception may unwind through Swift.
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
