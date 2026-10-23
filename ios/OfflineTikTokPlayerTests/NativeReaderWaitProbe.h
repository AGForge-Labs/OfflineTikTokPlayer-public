#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Test process only. Three recorded OWN executing threads; no task/thread scan,
// external process access, suspension API, entitlement or native media query.
@interface OPNativeReaderWaitProbe : NSObject
- (void)noteOwnThreadForLane:(NSInteger)lane copySequence:(uint64_t)sequence
    NS_SWIFT_NAME(noteOwnThread(forLane:copySequence:));
- (NSDictionary<NSString *, id> *)sampleLane:(NSInteger)lane copySequence:(uint64_t)sequence
    NS_SWIFT_NAME(sampleLane(_:copySequence:));
- (void)close;
@end
NS_ASSUME_NONNULL_END
