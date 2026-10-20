/// Video presentation decisions only. Audio intent and audio-session ownership stay with the service.
struct PlaybackPresentationPolicy {
    enum Presentation: Int, Codable {
        case inlineVideo = 0
        case pictureInPicture = 1
        case audioOnly = 2
    }

    struct Actions: Equatable {
        var stopPictureInPicture = false
        var restoreInlineVideo = false
    }

    private(set) var audioOnly: Bool
    private(set) var applicationIsActive = true
    private(set) var pictureInPictureIsActive = false
    private(set) var pictureInPictureIsPossible = false
    private(set) var pictureInPictureIsSuspended = false
    private var restoreInlineOnActivation = false

    init(audioOnly: Bool = false) {
        self.audioOnly = audioOnly
    }

    var allowsPictureInPicture: Bool { !audioOnly }

    var presentation: Presentation {
        if audioOnly { return .audioOnly }
        if pictureInPictureIsActive && !pictureInPictureIsSuspended { return .pictureInPicture }
        // Give automatic PiP its transition window. Backgrounding alone must
        // not pause the muted video before AVKit can finish starting PiP.
        if !applicationIsActive && restoreInlineOnActivation { return .audioOnly }
        return .inlineVideo
    }

    mutating func setAudioOnly(_ enabled: Bool) -> Actions {
        guard audioOnly != enabled else { return Actions() }
        audioOnly = enabled
        if enabled {
            restoreInlineOnActivation = false
            return Actions(stopPictureInPicture: pictureInPictureIsActive)
        }
        // Switching video on never starts PiP automatically or changes the user's audio intent.
        restoreInlineOnActivation = !applicationIsActive
        return Actions(restoreInlineVideo: applicationIsActive)
    }

    mutating func applicationDidEnterBackground() -> Actions {
        applicationIsActive = false
        if !audioOnly && pictureInPictureIsSuspended { restoreInlineOnActivation = true }
        return Actions(stopPictureInPicture: audioOnly && pictureInPictureIsActive)
    }

    mutating func applicationDidBecomeActive() -> Actions {
        guard !applicationIsActive else { return Actions() }
        applicationIsActive = true
        let restore = !audioOnly && restoreInlineOnActivation
        restoreInlineOnActivation = false
        return Actions(stopPictureInPicture: restore && pictureInPictureIsActive,
                       restoreInlineVideo: restore)
    }

    mutating func pictureInPictureChanged(active: Bool, possible: Bool, suspended: Bool) -> Actions {
        let wasActive = pictureInPictureIsActive
        pictureInPictureIsActive = active
        pictureInPictureIsPossible = possible
        pictureInPictureIsSuspended = suspended
        if audioOnly {
            return Actions(stopPictureInPicture: active)
        }
        if !applicationIsActive {
            if active && !suspended {
                // The system recovered its visible PiP window before the app returned.
                restoreInlineOnActivation = false
            } else if suspended || (wasActive && !active) {
                restoreInlineOnActivation = true
            }
        }
        return Actions()
    }

    mutating func pictureInPictureFailedToStart() -> Actions {
        pictureInPictureIsActive = false
        pictureInPictureIsSuspended = false
        if !audioOnly && !applicationIsActive { restoreInlineOnActivation = true }
        return Actions()
    }
}
