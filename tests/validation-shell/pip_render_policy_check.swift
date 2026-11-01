import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
struct PiPRenderPolicyCheck {
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }
    static func main() {
        var policy = PlaybackPresentationPolicy()
        _ = policy.applicationDidEnterBackground()
        expect(policy.allowsVideoRendering, "Keep automatic PiP's startup window")
        _ = policy.pictureInPictureChanged(active: true, possible: true, suspended: false)
        _ = policy.pictureInPictureChanged(active: true, possible: false, suspended: true)
        expect(policy.presentation == .audioOnly, "Keep descriptive suspended-window state")
        expect(policy.allowsVideoRendering,
               "An active suspended PiP must keep producing frames so AVKit can recover; stopping its feed deadlocks recovery")
        print("PASS: active suspended PiP retains its recovery frame feed")
        let disabled = policy.setAudioOnly(true)
        expect(disabled.stopPictureInPicture && !policy.allowsVideoRendering,
               "Explicit Audio only still stops video work")
        print("PASS: explicit Audio only stops video work")
        _ = policy.setAudioOnly(false)
        _ = policy.pictureInPictureChanged(active: false, possible: false, suspended: false)
        expect(!policy.allowsVideoRendering, "A closed background PiP must stop video work")
        _ = policy.applicationDidBecomeActive()
        expect(policy.allowsVideoRendering, "Foreground return restores inline video work")
        print("PASS: closed/background and foreground ownership remain correct")
    }
}
