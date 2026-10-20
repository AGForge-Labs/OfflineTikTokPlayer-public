import Foundation

// Keep these numeric codes stable: exports intentionally contain no free-text values.
enum PlaybackDiagnosticPhase: Int, Codable {
    case sampled = 0
    case playRequested = 1
    case pauseRequested = 2
    case nextRequested = 3
    case previousRequested = 4
    case seekRequested = 5
    case audioSessionActivated = 10
    case audioSessionActivationFailed = 11
    case audioInterruptionBegan = 12
    case audioInterruptionEnded = 13
    case audioRouteChanged = 14
    case audioMediaServicesReset = 15
    case appBackgrounded = 20
    case appForegrounded = 21
    case audioOnlySelected = 22
    case videoSelected = 23
    case pipStateChanged = 30
    case pipWillStart = 31
    case pipDidStart = 32
    case pipWillStop = 33
    case pipDidStop = 34
    case pipStartFailed = 35
    case inlineRestoreRequested = 36
    case inlineRestoreCompleted = 37
    case inlineRestoreUnavailable = 38
    case sourcePreparationBegan = 40
    case sourcePreparationCompleted = 41
    case sourcePreparationFailed = 42
    case rendererStarted = 43
    case rendererStopped = 44
    case rendererUnderrun = 45
    case sourceTimelineAnalyzed = 46
    case videoRateChanged = 46
    case pipCommandsUnavailable = 47
}

enum PlaybackDiagnosticPipeline: Int, Codable {
    case unknown = 0
    case paused = 1
    case waiting = 2
    case playing = 3
    case failed = 4
}

enum PlaybackDiagnosticOutputRoute: Int, Codable {
    case unknown = 0
    case none = 1
    case builtInSpeaker = 2
    case headphones = 3
    case bluetooth = 4
    case airPlay = 5
    case builtInReceiver = 6
    case other = 7
}

struct PlaybackDiagnosticError: Codable, Equatable {
    enum Family: Int, Codable {
        case unknown = 0
        case avKit = 1
        case avFoundation = 2
        case audioSession = 3
        case cocoa = 4
    }

    let family: Family
    let code: Int
}

/// A deliberately closed schema: no filenames, URLs, titles, account/device IDs or error descriptions.
struct PlaybackDiagnosticSnapshot: Encodable, Equatable {
    let generation: Int
    let audioRequested: Bool
    let audioPermitted: Bool
    let audioInterrupted: Bool
    let interruptionReason: Int?
    let interruptionOptions: UInt?
    let wasSuspended: Bool?
    let routeChangeReason: Int?
    let engineRunning: Bool
    let audioOnlySelected: Bool
    let presentation: PlaybackPresentationPolicy.Presentation
    let pipeline: PlaybackDiagnosticPipeline
    let positionSeconds: Double?
    let durationSeconds: Double?
    let playbackRate: Double?
    let retainedItems: Int
    let preparedPCMBytes: Int
    let underrunFrames: UInt64
    let outputRoute: PlaybackDiagnosticOutputRoute
    let sampleRate: Double?
    let ioBufferSeconds: Double?
    let outputLatencySeconds: Double?
    let pipActive: Bool
    let pipPossible: Bool
    let pipSuspended: Bool
    let sourceFrames: Int64?
    let sourceLeadingBelowMinus60DBFrames: Int64?
    let sourceTrailingBelowMinus60DBFrames: Int64?

    init(generation: Int = 0, audioRequested: Bool = false, audioPermitted: Bool = false,
         audioInterrupted: Bool = false, interruptionReason: Int? = nil,
         interruptionOptions: UInt? = nil, wasSuspended: Bool? = nil, routeChangeReason: Int? = nil,
         engineRunning: Bool = false, audioOnlySelected: Bool = false,
         presentation: PlaybackPresentationPolicy.Presentation = .inlineVideo,
         pipeline: PlaybackDiagnosticPipeline = .unknown, positionSeconds: Double? = nil,
         durationSeconds: Double? = nil, playbackRate: Double? = nil, retainedItems: Int = 0,
         preparedPCMBytes: Int = 0, underrunFrames: UInt64 = 0,
         outputRoute: PlaybackDiagnosticOutputRoute = .unknown, sampleRate: Double? = nil,
         ioBufferSeconds: Double? = nil, outputLatencySeconds: Double? = nil,
         pipActive: Bool = false, pipPossible: Bool = false, pipSuspended: Bool = false,
         sourceFrames: Int64? = nil, sourceLeadingBelowMinus60DBFrames: Int64? = nil,
         sourceTrailingBelowMinus60DBFrames: Int64? = nil) {
        self.generation = max(0, generation)
        self.audioRequested = audioRequested
        self.audioPermitted = audioPermitted
        self.audioInterrupted = audioInterrupted
        self.interruptionReason = interruptionReason
        self.interruptionOptions = interruptionOptions
        self.wasSuspended = wasSuspended
        self.routeChangeReason = routeChangeReason
        self.engineRunning = engineRunning
        self.audioOnlySelected = audioOnlySelected
        self.presentation = presentation
        self.pipeline = pipeline
        self.positionSeconds = Self.nonnegativeFinite(positionSeconds)
        self.durationSeconds = Self.nonnegativeFinite(durationSeconds)
        self.playbackRate = playbackRate.flatMap { $0.isFinite ? $0 : nil }
        self.retainedItems = max(0, retainedItems)
        self.preparedPCMBytes = max(0, preparedPCMBytes)
        self.underrunFrames = underrunFrames
        self.outputRoute = outputRoute
        self.sampleRate = Self.nonnegativeFinite(sampleRate)
        self.ioBufferSeconds = Self.nonnegativeFinite(ioBufferSeconds)
        self.outputLatencySeconds = Self.nonnegativeFinite(outputLatencySeconds)
        self.pipActive = pipActive
        self.pipPossible = pipPossible
        self.pipSuspended = pipSuspended
        self.sourceFrames = sourceFrames
        self.sourceLeadingBelowMinus60DBFrames = sourceLeadingBelowMinus60DBFrames
        self.sourceTrailingBelowMinus60DBFrames = sourceTrailingBelowMinus60DBFrames
    }

    private static func nonnegativeFinite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// Main/control-thread diagnostics only. Never call from an audio render callback.
/// Storage stays bounded and exports are created only when explicitly requested by the caller.
struct PlaybackDiagnosticJournal {
    struct Entry: Encodable, Equatable {
        let sequence: UInt64
        let elapsedSeconds: Double
        let phase: PlaybackDiagnosticPhase
        let snapshot: PlaybackDiagnosticSnapshot
        let error: PlaybackDiagnosticError?
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let capacity: Int
        let droppedEvents: UInt64
        let events: [Entry]
    }

    let capacity: Int
    private(set) var droppedEvents: UInt64 = 0
    private var storage: [Entry] = []
    private var nextIndex = 0
    private var nextSequence: UInt64 = 0
    private var originUptime: Double?
    private var lastElapsedSeconds = 0.0

    init(capacity: Int = 256) {
        self.capacity = min(1_024, max(1, capacity))
        storage.reserveCapacity(self.capacity)
    }

    var entries: [Entry] {
        guard storage.count == capacity && nextIndex != 0 else { return storage }
        return Array(storage[nextIndex...]) + Array(storage[..<nextIndex])
    }

    mutating func record(_ phase: PlaybackDiagnosticPhase, snapshot: PlaybackDiagnosticSnapshot,
                         error: PlaybackDiagnosticError? = nil,
                         uptime: Double = ProcessInfo.processInfo.systemUptime) {
        if uptime.isFinite {
            if originUptime == nil { originUptime = uptime }
            if let originUptime {
                let elapsed = uptime - originUptime
                if elapsed.isFinite { lastElapsedSeconds = max(lastElapsedSeconds, max(0, elapsed)) }
            }
        }
        let entry = Entry(sequence: nextSequence, elapsedSeconds: lastElapsedSeconds,
                          phase: phase, snapshot: snapshot, error: error)
        nextSequence &+= 1
        if storage.count < capacity {
            storage.append(entry)
        } else {
            storage[nextIndex] = entry
            droppedEvents &+= 1
        }
        nextIndex = (nextIndex + 1) % capacity
    }

    mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        nextIndex = 0
        nextSequence = 0
        droppedEvents = 0
        originUptime = nil
        lastElapsedSeconds = 0
    }

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Report(capacity: capacity, droppedEvents: droppedEvents, events: entries))
    }
}
