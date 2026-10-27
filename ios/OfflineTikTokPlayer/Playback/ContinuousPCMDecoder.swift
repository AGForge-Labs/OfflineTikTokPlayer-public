import Foundation
import AVFoundation
import AudioToolbox
import Synchronization
import PlayerCore
import Darwin

/// The only producer for the three fixed PCM sources. All AVAssetReader and
/// buffer work runs on one serial worker; the audio callback never calls here.
final class ContinuousPCMDecoder: @unchecked Sendable {
    enum Failure: Error, Equatable, Sendable {
        case localFileRequired, invalidTimeline, unsupportedPCM, oversizedPacket
        case cannotDecode, slotInUse, cancelled
    }

    enum NativeInputPlacement: Sendable {
        case converterCallback
        #if DEBUG
        case stagedBeforeConversion
        #endif
    }

    struct Prepared: Sendable {
        let token: Int
        let totalFrames: Int64
        let hasAudio: Bool
    }

    struct LifecycleSnapshot: Sendable {
        let createdInstances: Int64
        // Counts entry to Swift deinit, not completed SDK resource destruction.
        let deinitEnteredInstances: Int64
        let shutdownRequestCalls: Int64
        let shutdownRequestedInstances: Int64
        let shutdownCompletedInstances: Int64
        let liveInstances: Int64?
        // Two identical bounded reads, not a transactional/coherent snapshot.
        let stableReread: Bool
    }

    struct RecorderLifecycleSnapshot: Sendable {
        let shutdownRequested: Bool
        let shutdownCompleted: Bool
        let deinitEntered: Bool
    }

    private struct LifecycleRead: Equatable {
        let created: Int64
        let deinitEntered: Int64
        let requestCalls: Int64
        let requested: Int64
        let completed: Int64
    }

    private enum LifecycleCounters {
        static let created = Atomic<Int64>(0)
        static let deinitEntered = Atomic<Int64>(0)
        static let requestCalls = Atomic<Int64>(0)
        static let requested = Atomic<Int64>(0)
        static let completed = Atomic<Int64>(0)

        static func read() -> LifecycleRead {
            LifecycleRead(created: created.load(ordering: .sequentiallyConsistent),
                deinitEntered: deinitEntered.load(ordering: .sequentiallyConsistent),
                requestCalls: requestCalls.load(ordering: .sequentiallyConsistent),
                requested: requested.load(ordering: .sequentiallyConsistent),
                completed: completed.load(ordering: .sequentiallyConsistent))
        }
    }

    /// Fixed process-wide counters contain no registry, object references or
    /// source identities. Multiple threads can initialize/deinitialize decoders;
    /// repeat agreement does not turn these independent atomics into a transaction.
    static func lifecycleSnapshot() -> LifecycleSnapshot {
        let first = LifecycleCounters.read(), second = LifecycleCounters.read()
        let stable = first == second
        var live: Int64?
        if stable, second.created >= 0, second.deinitEntered >= 0,
           second.created >= second.deinitEntered {
            let difference = second.created.subtractingReportingOverflow(second.deinitEntered)
            if !difference.overflow { live = difference.partialValue }
        }
        return LifecycleSnapshot(createdInstances: second.created,
            deinitEnteredInstances: second.deinitEntered, shutdownRequestCalls: second.requestCalls,
            shutdownRequestedInstances: second.requested, shutdownCompletedInstances: second.completed,
            liveInstances: live, stableReread: stable)
    }

    enum ProgressPhase: Int, Sendable {
        case idle = 0, preparing = 1, pumping = 2, openingStream = 3
        case readerStart = 4, nativeCopy = 5, converting = 6, readerCancel = 7, appending = 8
        case rendererSnapshot = 9, streamRequest = 10, readerConfiguration = 11
        case converterConstruction = 12, streamReplacement = 13, poolDrain = 14, retiringSlots = 15
        case readerConstruction = 16
        case calibrationWait = 17
    }

    struct SlotProgressSnapshot: Sendable {
        let token: Int
        // Latest accepted epoch; counts span this token's epochs and reset only
        // when a different token positively appends into this fixed slot.
        let epoch: Int
        let acceptedFrames: Int64
        let appendCount: Int64
        let lastAcceptedUptimeNanoseconds: UInt64
    }

    struct ProgressSnapshot: Sendable {
        let tracingEnabled: Bool
        // Borrowed own-process thread name, used only by workerThreadState.
        // Never include this field in logs or serialized diagnostic records.
        fileprivate let threadPort: UInt32
        let phase: ProgressPhase
        let token: Int
        let slot: Int
        let epoch: Int
        let currentTokenAtLastPump: Int
        let phaseEnteredUptimeNanoseconds: UInt64
        let phaseSequence: Int64
        let pumpCount: Int64
        // Cumulative accepted ring frames across slots, excluding pinned prefixes.
        // The last-accepted tuple identifies the latest successful publication.
        let acceptedFrames: Int64
        let appendCount: Int64
        let lastAcceptedUptimeNanoseconds: UInt64
        let lastAcceptedToken: Int
        let lastAcceptedSlot: Int
        let lastAcceptedEpoch: Int
        let slot0: SlotProgressSnapshot
        let slot1: SlotProgressSnapshot
        let slot2: SlotProgressSnapshot
        let coherent: Bool
    }

    /// Completed copy scopes for one physical slot's latest token/epoch. A key
    /// change invalidates count/sum differences; retirement does not clear history.
    struct NativeCopySlotSnapshot: Sendable, Equatable {
        let token: Int
        let epoch: Int
        let completedCount: UInt64
        let completedWallNanoseconds: UInt64
        let wallTimeOverflowed: Bool
        let maximumWallNanoseconds: UInt64
        let maximumEntrySequence: Int64
        let maximumStartNanoseconds: UInt64
        let maximumEndNanoseconds: UInt64

        static let empty = NativeCopySlotSnapshot(token: 0, epoch: 0, completedCount: 0,
            completedWallNanoseconds: 0, wallTimeOverflowed: false, maximumWallNanoseconds: 0,
            maximumEntrySequence: 0, maximumStartNanoseconds: 0, maximumEndNanoseconds: 0)
    }

    /// Read only at observation boundaries, independently of periodic sampling.
    /// Wall time includes descheduling; it neither identifies a wait owner nor
    /// measures an unfinished copy, which remains in the current phase tuple.
    struct NativeCopyCompletionSnapshot: Sendable, Equatable {
        let tracingEnabled: Bool
        let phase: ProgressPhase
        let token: Int
        let slot: Int
        let epoch: Int
        let phaseSequence: Int64
        let phaseEnteredUptimeNanoseconds: UInt64
        let slot0: NativeCopySlotSnapshot
        let slot1: NativeCopySlotSnapshot
        let slot2: NativeCopySlotSnapshot
        let coherent: Bool

        static let disabled = NativeCopyCompletionSnapshot(tracingEnabled: false, phase: .idle,
            token: 0, slot: -1, epoch: 0, phaseSequence: 0, phaseEnteredUptimeNanoseconds: 0,
            slot0: .empty, slot1: .empty, slot2: .empty, coherent: true)
    }

    struct WorkerThreadState: Sendable {
        // 0 valid, 1 disabled, 2 incoherent, 3 idle, 4 missing port,
        // 5 phase changed, 6 kernel error, 7 unexpected returned info count.
        let statusCode: Int
        // -1 means no kernel query; otherwise the actual thread_info result.
        let kernelReturnCode: Int32
        let runState: Int32
        let userMicros: Int64
        let systemMicros: Int64
        let phaseSequence: Int64
        let acquisitionBeginNs: UInt64
        let acquisitionEndNs: UInt64
    }

    fileprivate struct NativeCopyEntry: Sendable {
        let token: Int
        let slot: Int
        let epoch: Int
        let sequence: Int64
        let startNanoseconds: UInt64
    }

    fileprivate struct ProgressMark: Sendable {
        let enabled: Bool
        let phase: ProgressPhase
        let token: Int
        let slot: Int
        let epoch: Int
        let threadPort: UInt32
        var nativeCopyEntry: NativeCopyEntry? = nil
    }

    struct NativeCopyCalibrationMark: Sendable {
        fileprivate let mark: ProgressMark
    }

    fileprivate struct ProgressContext {
        let token: Int
        let slot: Int
        let epoch: Int
    }

    /// Independent of the decoder, renderer and actors. One decode worker writes;
    /// observers make at most three attempts to read the fixed-size atomic record.
    /// A preempted writer produces coherent=false rather than blocking a probe.
    final class ProgressRecorder: @unchecked Sendable {
        let workerIdentifier = UUID().uuidString.lowercased()

        #if DEBUG
        private let stagedNativeReads = Atomic<UInt64>(0)
        /// Completed successful staged reads, including a true EOF return. This
        /// is independent of tracing and does not count pending/blocked calls.
        var debugStagedNativeReadCount: UInt64 { stagedNativeReads.load(ordering: .acquiring) }

        fileprivate func noteStagedNativeRead() {
            let count = stagedNativeReads.load(ordering: .relaxed)
            stagedNativeReads.store(count == UInt64.max ? count : count + 1, ordering: .releasing)
        }
        #endif

        private final class SlotCounters {
            let token = Atomic<Int>(0)
            let epoch = Atomic<Int>(0)
            let frames = Atomic<Int64>(0)
            let appends = Atomic<Int64>(0)
            let time = Atomic<UInt64>(0)

            func snapshot() -> SlotProgressSnapshot {
                SlotProgressSnapshot(token: token.load(ordering: .sequentiallyConsistent),
                    epoch: epoch.load(ordering: .sequentiallyConsistent),
                    acceptedFrames: frames.load(ordering: .sequentiallyConsistent),
                    appendCount: appends.load(ordering: .sequentiallyConsistent),
                    lastAcceptedUptimeNanoseconds: time.load(ordering: .sequentiallyConsistent))
            }

            func noteAccepted(frames count: Int, token nextToken: Int, epoch nextEpoch: Int, now: UInt64) {
                let changed = token.load(ordering: .relaxed) != nextToken
                token.store(nextToken, ordering: .sequentiallyConsistent)
                epoch.store(nextEpoch, ordering: .sequentiallyConsistent)
                frames.store((changed ? 0 : frames.load(ordering: .relaxed)) &+ Int64(count), ordering: .sequentiallyConsistent)
                appends.store((changed ? 0 : appends.load(ordering: .relaxed)) &+ 1, ordering: .sequentiallyConsistent)
                time.store(now, ordering: .sequentiallyConsistent)
            }
        }

        private final class NativeCopyCounters {
            let token = Atomic<Int>(0)
            let epoch = Atomic<Int>(0)
            let completed = Atomic<UInt64>(0)
            let wall = Atomic<UInt64>(0)
            let overflowed = Atomic<Bool>(false)
            let maximum = Atomic<UInt64>(0)
            let maximumSequence = Atomic<Int64>(0)
            let maximumStart = Atomic<UInt64>(0)
            let maximumEnd = Atomic<UInt64>(0)

            func snapshot() -> NativeCopySlotSnapshot {
                NativeCopySlotSnapshot(token: token.load(ordering: .sequentiallyConsistent),
                    epoch: epoch.load(ordering: .sequentiallyConsistent),
                    completedCount: completed.load(ordering: .sequentiallyConsistent),
                    completedWallNanoseconds: wall.load(ordering: .sequentiallyConsistent),
                    wallTimeOverflowed: overflowed.load(ordering: .sequentiallyConsistent),
                    maximumWallNanoseconds: maximum.load(ordering: .sequentiallyConsistent),
                    maximumEntrySequence: maximumSequence.load(ordering: .sequentiallyConsistent),
                    maximumStartNanoseconds: maximumStart.load(ordering: .sequentiallyConsistent),
                    maximumEndNanoseconds: maximumEnd.load(ordering: .sequentiallyConsistent))
            }

            func begin(token nextToken: Int, epoch nextEpoch: Int) {
                guard token.load(ordering: .relaxed) != nextToken
                    || epoch.load(ordering: .relaxed) != nextEpoch else { return }
                token.store(nextToken, ordering: .sequentiallyConsistent)
                epoch.store(nextEpoch, ordering: .sequentiallyConsistent)
                completed.store(0, ordering: .sequentiallyConsistent)
                wall.store(0, ordering: .sequentiallyConsistent)
                overflowed.store(false, ordering: .sequentiallyConsistent)
                maximum.store(0, ordering: .sequentiallyConsistent)
                maximumSequence.store(0, ordering: .sequentiallyConsistent)
                maximumStart.store(0, ordering: .sequentiallyConsistent)
                maximumEnd.store(0, ordering: .sequentiallyConsistent)
            }

            func complete(_ entry: NativeCopyEntry, end: UInt64) {
                guard token.load(ordering: .relaxed) == entry.token,
                      epoch.load(ordering: .relaxed) == entry.epoch else { return }
                let duration = end - entry.startNanoseconds
                let count = completed.load(ordering: .relaxed)
                completed.store(count == UInt64.max ? count : count + 1, ordering: .sequentiallyConsistent)
                let sum = wall.load(ordering: .relaxed).addingReportingOverflow(duration)
                wall.store(sum.overflow ? UInt64.max : sum.partialValue, ordering: .sequentiallyConsistent)
                if sum.overflow { overflowed.store(true, ordering: .sequentiallyConsistent) }
                if count == 0 || duration > maximum.load(ordering: .relaxed) {
                    maximum.store(duration, ordering: .sequentiallyConsistent)
                    maximumSequence.store(entry.sequence, ordering: .sequentiallyConsistent)
                    maximumStart.store(entry.startNanoseconds, ordering: .sequentiallyConsistent)
                    maximumEnd.store(end, ordering: .sequentiallyConsistent)
                }
            }
        }

        private let tracing = Atomic<Bool>(true)
        private let version = Atomic<Int64>(0)
        private let workerPort = Atomic<UInt32>(0)
        private let phaseValue = Atomic<Int>(ProgressPhase.idle.rawValue)
        private let tokenValue = Atomic<Int>(0)
        private let slotValue = Atomic<Int>(-1)
        private let epochValue = Atomic<Int>(0)
        private let currentToken = Atomic<Int>(0)
        private let enteredTime = Atomic<UInt64>(0)
        private let phaseCount = Atomic<Int64>(0)
        private let pumps = Atomic<Int64>(0)
        private let accepted = Atomic<Int64>(0)
        private let appends = Atomic<Int64>(0)
        private let acceptedTime = Atomic<UInt64>(0)
        private let acceptedToken = Atomic<Int>(0)
        private let acceptedSlot = Atomic<Int>(-1)
        private let acceptedEpoch = Atomic<Int>(0)
        private let firstSlot = SlotCounters()
        private let secondSlot = SlotCounters()
        private let thirdSlot = SlotCounters()
        private let firstNativeCopy = NativeCopyCounters()
        private let secondNativeCopy = NativeCopyCounters()
        private let thirdNativeCopy = NativeCopyCounters()
        // These flags have multiple possible callers and remain independent of
        // the decode worker's single-writer phase seqlock and tracing switch.
        private let lifecycleRequested = Atomic<Bool>(false)
        private let lifecycleCompleted = Atomic<Bool>(false)
        private let lifecycleDeinitEntered = Atomic<Bool>(false)

        func lifecycleSnapshot() -> RecorderLifecycleSnapshot {
            RecorderLifecycleSnapshot(shutdownRequested: lifecycleRequested.load(ordering: .sequentiallyConsistent),
                shutdownCompleted: lifecycleCompleted.load(ordering: .sequentiallyConsistent),
                deinitEntered: lifecycleDeinitEntered.load(ordering: .sequentiallyConsistent))
        }

        fileprivate func noteShutdownRequested() {
            _ = LifecycleCounters.requestCalls.wrappingAdd(1, ordering: .sequentiallyConsistent)
            if !lifecycleRequested.exchange(true, ordering: .sequentiallyConsistent) {
                _ = LifecycleCounters.requested.wrappingAdd(1, ordering: .sequentiallyConsistent)
            }
        }

        fileprivate func noteShutdownCompleted() {
            if !lifecycleCompleted.exchange(true, ordering: .sequentiallyConsistent) {
                _ = LifecycleCounters.completed.wrappingAdd(1, ordering: .sequentiallyConsistent)
            }
        }

        fileprivate func noteDeinitEntered() {
            if !lifecycleDeinitEntered.exchange(true, ordering: .sequentiallyConsistent) {
                _ = LifecycleCounters.deinitEntered.wrappingAdd(1, ordering: .sequentiallyConsistent)
            }
        }

        /// Controls diagnostic publication only. Set once before preparing a
        /// fresh fixture; disabled snapshots retain the last published record.
        func setTracingEnabled(_ enabled: Bool) {
            tracing.store(enabled, ordering: .sequentiallyConsistent)
        }

        func snapshot() -> ProgressSnapshot {
            var result = readSnapshot()
            for _ in 0..<2 {
                if result.coherent { return result }
                result = readSnapshot()
            }
            return result
        }

        func nativeCopyCompletionSnapshot() -> NativeCopyCompletionSnapshot {
            var result = readNativeCopyCompletionSnapshot()
            for _ in 0..<2 {
                if result.coherent { return result }
                result = readNativeCopyCompletionSnapshot()
            }
            return result
        }

        private func readNativeCopyCompletionSnapshot() -> NativeCopyCompletionSnapshot {
            // Disabled observers do not read any of the new per-slot atomics.
            guard tracing.load(ordering: .sequentiallyConsistent) else { return .disabled }
            let before = version.load(ordering: .sequentiallyConsistent)
            let phase = ProgressPhase(rawValue: phaseValue.load(ordering: .sequentiallyConsistent)) ?? .idle
            let token = tokenValue.load(ordering: .sequentiallyConsistent)
            let slot = slotValue.load(ordering: .sequentiallyConsistent)
            let epoch = epochValue.load(ordering: .sequentiallyConsistent)
            let sequence = phaseCount.load(ordering: .sequentiallyConsistent)
            let entered = enteredTime.load(ordering: .sequentiallyConsistent)
            let first = firstNativeCopy.snapshot(), second = secondNativeCopy.snapshot(), third = thirdNativeCopy.snapshot()
            let coherent = before & 1 == 0 && before == version.load(ordering: .sequentiallyConsistent)
                && tracing.load(ordering: .sequentiallyConsistent)
            return NativeCopyCompletionSnapshot(tracingEnabled: true, phase: phase, token: token, slot: slot,
                epoch: epoch, phaseSequence: sequence, phaseEnteredUptimeNanoseconds: entered,
                slot0: first, slot1: second, slot2: third, coherent: coherent)
        }

        /// Observes only this worker's cached, borrowed pthread Mach port. The
        /// call neither acquires a send right nor enumerates threads/processes.
        /// A phase transition before/during this single query fails closed.
        func workerThreadState(matching snapshot: ProgressSnapshot) -> WorkerThreadState {
            let begin = DispatchTime.now().uptimeNanoseconds
            func result(_ status: Int, kernel: Int32 = -1, state: Int32 = 0,
                        user: Int64 = 0, system: Int64 = 0) -> WorkerThreadState {
                WorkerThreadState(statusCode: status, kernelReturnCode: kernel,
                    runState: state, userMicros: user, systemMicros: system,
                    phaseSequence: snapshot.phaseSequence, acquisitionBeginNs: begin,
                    acquisitionEndNs: DispatchTime.now().uptimeNanoseconds)
            }
            guard snapshot.tracingEnabled, tracing.load(ordering: .acquiring) else { return result(1) }
            guard snapshot.coherent else { return result(2) }
            guard snapshot.phase != .idle else { return result(3) }
            guard snapshot.threadPort != 0 else { return result(4) }
            guard stillMatches(snapshot) else { return result(5) }

            var info = thread_basic_info_data_t()
            let expected = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            var count = expected
            let kernel = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) { words in
                    thread_info(thread_t(snapshot.threadPort), thread_flavor_t(THREAD_BASIC_INFO), words, &count)
                }
            }
            guard stillMatches(snapshot) else { return result(5, kernel: kernel) }
            guard kernel == KERN_SUCCESS else { return result(6, kernel: kernel) }
            guard count == expected else { return result(7, kernel: kernel) }
            return result(0, kernel: kernel, state: info.run_state,
                user: Int64(info.user_time.seconds) * 1_000_000 + Int64(info.user_time.microseconds),
                system: Int64(info.system_time.seconds) * 1_000_000 + Int64(info.system_time.microseconds))
        }

        private func stillMatches(_ snapshot: ProgressSnapshot) -> Bool {
            let before = version.load(ordering: .sequentiallyConsistent)
            guard before & 1 == 0,
                  tracing.load(ordering: .sequentiallyConsistent),
                  phaseCount.load(ordering: .sequentiallyConsistent) == snapshot.phaseSequence,
                  phaseValue.load(ordering: .sequentiallyConsistent) == snapshot.phase.rawValue,
                  workerPort.load(ordering: .sequentiallyConsistent) == snapshot.threadPort else { return false }
            return before == version.load(ordering: .sequentiallyConsistent)
                && tracing.load(ordering: .sequentiallyConsistent)
        }

        /// Calibration owns a separate sleeping queue; this never runs audio or
        /// impersonates an AVAssetReader/AVAudioConverter native call.
        func withKnownWorkerWait(_ operation: () -> Void) {
            let previous = enter(.calibrationWait, token: 0, slot: -1, epoch: 0)
            defer { restore(previous) }
            operation()
        }

        /// Synthetic calibration of the same entry/return path as nextSample;
        /// this does not create an asset reader or claim a native SDK wait.
        func beginNativeCopyCalibration(token: Int, slot: Int, epoch: Int) -> NativeCopyCalibrationMark {
            precondition(token > 0 && (0..<3).contains(slot))
            return NativeCopyCalibrationMark(mark: enter(.nativeCopy, token: token, slot: slot, epoch: epoch))
        }

        func endNativeCopyCalibration(_ calibration: NativeCopyCalibrationMark) {
            restore(calibration.mark)
        }

        private func readSnapshot() -> ProgressSnapshot {
            let enabled = tracing.load(ordering: .sequentiallyConsistent)
            let before = version.load(ordering: .sequentiallyConsistent)
            let port = workerPort.load(ordering: .sequentiallyConsistent)
            let phase = ProgressPhase(rawValue: phaseValue.load(ordering: .sequentiallyConsistent)) ?? .idle
            let token = tokenValue.load(ordering: .sequentiallyConsistent)
            let slot = slotValue.load(ordering: .sequentiallyConsistent)
            let epoch = epochValue.load(ordering: .sequentiallyConsistent)
            let active = currentToken.load(ordering: .sequentiallyConsistent)
            let entered = enteredTime.load(ordering: .sequentiallyConsistent)
            let transitions = phaseCount.load(ordering: .sequentiallyConsistent)
            let pumpCount = pumps.load(ordering: .sequentiallyConsistent)
            let frames = accepted.load(ordering: .sequentiallyConsistent)
            let appendCount = appends.load(ordering: .sequentiallyConsistent)
            let lastAccepted = acceptedTime.load(ordering: .sequentiallyConsistent)
            let lastToken = acceptedToken.load(ordering: .sequentiallyConsistent)
            let lastSlot = acceptedSlot.load(ordering: .sequentiallyConsistent)
            let lastEpoch = acceptedEpoch.load(ordering: .sequentiallyConsistent)
            let slot0 = firstSlot.snapshot(), slot1 = secondSlot.snapshot(), slot2 = thirdSlot.snapshot()
            let coherent = before & 1 == 0 && before == version.load(ordering: .sequentiallyConsistent)
                && enabled == tracing.load(ordering: .sequentiallyConsistent)
            return ProgressSnapshot(tracingEnabled: enabled, threadPort: port, phase: phase, token: token, slot: slot, epoch: epoch,
                currentTokenAtLastPump: active, phaseEnteredUptimeNanoseconds: entered,
                phaseSequence: transitions, pumpCount: pumpCount, acceptedFrames: frames,
                appendCount: appendCount, lastAcceptedUptimeNanoseconds: lastAccepted,
                lastAcceptedToken: lastToken, lastAcceptedSlot: lastSlot, lastAcceptedEpoch: lastEpoch,
                slot0: slot0, slot1: slot1, slot2: slot2,
                coherent: coherent)
        }

        fileprivate func enter(_ phase: ProgressPhase, token: Int, slot: Int, epoch: Int) -> ProgressMark {
            guard tracing.load(ordering: .acquiring) else {
                return ProgressMark(enabled: false, phase: .idle, token: 0, slot: -1, epoch: 0, threadPort: 0)
            }
            var previous = ProgressMark(enabled: true, phase: ProgressPhase(rawValue: phaseValue.load(ordering: .relaxed)) ?? .idle,
                token: tokenValue.load(ordering: .relaxed), slot: slotValue.load(ordering: .relaxed),
                epoch: epochValue.load(ordering: .relaxed), threadPort: workerPort.load(ordering: .relaxed))
            previous.nativeCopyEntry = publish(phase, token: token, slot: slot, epoch: epoch,
                recordsNativeCopy: phase == .nativeCopy)
            return previous
        }

        fileprivate func restore(_ previous: ProgressMark) {
            guard previous.enabled, tracing.load(ordering: .acquiring) else { return }
            if let entry = previous.nativeCopyEntry {
                // A duplicate or obsolete return cannot overwrite a later
                // call's phase or another generation's physical-slot summary.
                guard phaseValue.load(ordering: .relaxed) == ProgressPhase.nativeCopy.rawValue,
                      phaseCount.load(ordering: .relaxed) == entry.sequence,
                      tokenValue.load(ordering: .relaxed) == entry.token,
                      slotValue.load(ordering: .relaxed) == entry.slot,
                      epochValue.load(ordering: .relaxed) == entry.epoch else { return }
                let end = DispatchTime.now().uptimeNanoseconds
                guard end >= entry.startNanoseconds else { return }
                beginUpdate()
                nativeCopyCounters(slot: entry.slot)?.complete(entry, end: end)
                _ = writePhase(previous.phase, token: previous.token, slot: previous.slot, epoch: previous.epoch,
                    port: previous.threadPort, now: end)
                endUpdate()
                return
            }
            publish(previous.phase, token: previous.token, slot: previous.slot, epoch: previous.epoch,
                publisherPort: previous.threadPort)
        }

        fileprivate func enter(_ phase: ProgressPhase, context: ProgressContext) -> ProgressMark {
            enter(phase, token: context.token, slot: context.slot, epoch: context.epoch)
        }

        fileprivate func notePump(currentToken token: Int) {
            guard tracing.load(ordering: .acquiring) else { return }
            beginUpdate()
            currentToken.store(token, ordering: .sequentiallyConsistent)
            pumps.store(pumps.load(ordering: .relaxed) &+ 1, ordering: .sequentiallyConsistent)
            endUpdate()
        }

        fileprivate func noteAccepted(frames: Int, token: Int, slot: Int, epoch: Int) {
            guard tracing.load(ordering: .acquiring), frames > 0 else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            beginUpdate()
            accepted.store(accepted.load(ordering: .relaxed) &+ Int64(frames), ordering: .sequentiallyConsistent)
            appends.store(appends.load(ordering: .relaxed) &+ 1, ordering: .sequentiallyConsistent)
            acceptedTime.store(now, ordering: .sequentiallyConsistent)
            acceptedToken.store(token, ordering: .sequentiallyConsistent)
            acceptedSlot.store(slot, ordering: .sequentiallyConsistent)
            acceptedEpoch.store(epoch, ordering: .sequentiallyConsistent)
            switch slot {
            case 0: firstSlot.noteAccepted(frames: frames, token: token, epoch: epoch, now: now)
            case 1: secondSlot.noteAccepted(frames: frames, token: token, epoch: epoch, now: now)
            case 2: thirdSlot.noteAccepted(frames: frames, token: token, epoch: epoch, now: now)
            default: break
            }
            endUpdate()
        }

        fileprivate func streamRequest(from source: ContinuousPCMSource, context: ProgressContext) -> ContinuousPCMStreamRequest {
            let previous = enter(.streamRequest, context: context)
            defer { restore(previous) }
            return source.streamRequest
        }

        @discardableResult
        private func publish(_ phase: ProgressPhase, token: Int, slot: Int, epoch: Int,
                             publisherPort: UInt32? = nil, recordsNativeCopy: Bool = false) -> NativeCopyEntry? {
            // Hide the previous phase before querying the actual publisher's
            // borrowed port. A serialized native callback may use another
            // thread; an in-progress lookup must never look like an SDK wait.
            beginUpdate()
            let port: UInt32
            if phase == .idle { port = 0 }
            else if let publisherPort { port = publisherPort }
            else { port = pthread_mach_thread_np(pthread_self()) }
            if recordsNativeCopy { nativeCopyCounters(slot: slot)?.begin(token: token, epoch: epoch) }
            let now = DispatchTime.now().uptimeNanoseconds
            let sequence = writePhase(phase, token: token, slot: slot, epoch: epoch, port: port, now: now)
            endUpdate()
            return recordsNativeCopy
                ? NativeCopyEntry(token: token, slot: slot, epoch: epoch, sequence: sequence, startNanoseconds: now) : nil
        }

        private func writePhase(_ phase: ProgressPhase, token: Int, slot: Int, epoch: Int,
                                port: UInt32, now: UInt64) -> Int64 {
            // Caller owns the one writer transaction; never nest beginUpdate.
            workerPort.store(port, ordering: .sequentiallyConsistent)
            phaseValue.store(phase.rawValue, ordering: .sequentiallyConsistent)
            tokenValue.store(token, ordering: .sequentiallyConsistent)
            slotValue.store(slot, ordering: .sequentiallyConsistent)
            epochValue.store(epoch, ordering: .sequentiallyConsistent)
            enteredTime.store(now, ordering: .sequentiallyConsistent)
            let sequence = phaseCount.load(ordering: .relaxed) &+ 1
            phaseCount.store(sequence, ordering: .sequentiallyConsistent)
            return sequence
        }

        private func nativeCopyCounters(slot: Int) -> NativeCopyCounters? {
            switch slot {
            case 0: return firstNativeCopy
            case 1: return secondNativeCopy
            case 2: return thirdNativeCopy
            default: return nil
            }
        }

        private func beginUpdate() {
            version.store(version.load(ordering: .relaxed) &+ 1, ordering: .sequentiallyConsistent)
        }
        private func endUpdate() {
            version.store(version.load(ordering: .relaxed) &+ 1, ordering: .sequentiallyConsistent)
        }
    }

    /// A measurement of the complete decoded presentation at -60 dBFS. Quiet
    /// source frames remain untouched; these counts are not player underruns.
    struct SourceSilence: Sendable {
        let totalFrames: Int64
        let leadingFrames: Int64
        let trailingFrames: Int64
        let peak: Float
    }

    private final class Cancellation: @unchecked Sendable {
        let value = Atomic<Bool>(false)
    }

    private enum ReadControl: Error { case deferred }

    private final class Description: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack?
        let totalFrames: Int64
        let endTime: CMTime
        let nativeRate: Double
        let nativeChannels: UInt32
        let nativeInputPlacement: NativeInputPlacement
        init(asset: AVURLAsset, track: AVAssetTrack?, totalFrames: Int64, endTime: CMTime, nativeRate: Double, nativeChannels: UInt32,
             nativeInputPlacement: NativeInputPlacement) {
            self.asset = asset; self.track = track; self.totalFrames = totalFrames
            self.endTime = endTime
            self.nativeRate = nativeRate; self.nativeChannels = nativeChannels
            self.nativeInputPlacement = nativeInputPlacement
        }
    }

    private final class Slot {
        let index: Int
        let token: Int
        let source: ContinuousPCMSource
        let description: Description
        let cancellation: Cancellation
        var stream: Stream
        var epoch: Int = 1
        var finished = false
        init(index: Int, token: Int, source: ContinuousPCMSource, description: Description, cancellation: Cancellation, stream: Stream) {
            self.index = index; self.token = token; self.source = source; self.description = description
            self.cancellation = cancellation; self.stream = stream
        }
    }

    private let renderer: ContinuousPCMRenderer
    private let nativeInputPlacement: NativeInputPlacement
    let progressRecorder: ProgressRecorder
    private let worker: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var slots: [Slot?] = [nil, nil, nil]
    private var scratch = [Float](repeating: 0, count: 8_192 * 2)
    private var stopped = false
    private var failureHandler: (@Sendable (Int, Failure) -> Void)?
    private var sourceSilenceHandler: (@Sendable (Int, SourceSilence) -> Void)?
    private let yieldCount = Atomic<Int64>(0)

    /// Numeric cooperative scheduling evidence; never includes source identity.
    var cooperativeYieldCount: Int64 { yieldCount.load(ordering: .acquiring) }

    init(renderer: ContinuousPCMRenderer, nativeInputPlacement: NativeInputPlacement = .converterCallback) {
        let recorder = ProgressRecorder()
        self.renderer = renderer
        self.nativeInputPlacement = nativeInputPlacement
        progressRecorder = recorder
        worker = DispatchQueue(label: "OfflineTikTokPlayer.PCMDecode." + recorder.workerIdentifier, qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: worker)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pump() }
        _ = LifecycleCounters.created.wrappingAdd(1, ordering: .sequentiallyConsistent)
        timer.resume()
    }

    deinit { progressRecorder.noteDeinitEntered() }

    /// Test calibration only: a finite hold on this exact decoder's worker, with
    /// no reader, audio graph, media or production call site involved.
    func enqueueLifecycleCalibrationHold(entered: DispatchSemaphore, release: DispatchSemaphore) {
        worker.async { [self] in
            progressRecorder.withKnownWorkerWait {
                entered.signal()
                _ = release.wait(timeout: .now() + .seconds(12))
            }
        }
    }

    /// Metadata loading may suspend; decoding and publishing are serialized.
    /// Token values identify a preparation, never a media URL or persistent ID.
    func prepare(url: URL, token: Int, slot index: Int) async throws -> Prepared {
        guard url.isFileURL else { throw Failure.localFileRequired }
        guard token > 0, (0..<3).contains(index) else { throw Failure.invalidTimeline }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        // An approximate endpoint must never become an implicit content trim.
        guard try await asset.load(.providesPreciseDurationAndTiming) else { throw Failure.unsupportedPCM }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        // Do not mix alternate-language tracks together. Select the first enabled
        // audio track, matching the asset's ordinary default presentation.
        var selected: AVAssetTrack?
        for track in tracks where selected == nil {
            if try await track.load(.isEnabled) { selected = track }
        }
        selected = selected ?? tracks.first
        var end = duration
        if let selected {
            let range = try await selected.load(.timeRange)
            if range.end.isNumeric, CMTimeCompare(range.end, end) > 0 { end = range.end }
        }
        let frames = try Self.frame(end)
        guard frames > 0 else { throw Failure.invalidTimeline }
        var nativeRate = 48_000.0, nativeChannels: UInt32 = 2
        if let selected {
            let formats = try await selected.load(.formatDescriptions)
            guard let format = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  asbd.pointee.mSampleRate.isFinite, asbd.pointee.mSampleRate > 0,
                  (1...8).contains(asbd.pointee.mChannelsPerFrame) else { throw Failure.unsupportedPCM }
            nativeRate = asbd.pointee.mSampleRate; nativeChannels = asbd.pointee.mChannelsPerFrame
        }
        let description = Description(asset: asset, track: selected, totalFrames: frames, endTime: end,
            nativeRate: nativeRate, nativeChannels: nativeChannels, nativeInputPlacement: nativeInputPlacement)
        let hasAudio = selected != nil
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                worker.async { [self] in
                    let previous = progressRecorder.enter(.preparing, token: token, slot: index, epoch: 0)
                    defer { progressRecorder.restore(previous) }
                    autoreleasepool {
                        defer { _ = progressRecorder.enter(.poolDrain, token: token, slot: index, epoch: 0) }
                        do {
                            guard !stopped, !cancellation.value.load(ordering: .acquiring) else { throw Failure.cancelled }
                            let source = renderer.source(at: index)
                            let stream = try Stream(description: description, startFrame: 0,
                                progress: progressRecorder, context: ProgressContext(token: token, slot: index, epoch: 0),
                                shouldCancel: { cancellation.value.load(ordering: .acquiring) })
                            var prefix = [Float](repeating: 0, count: source.prefixCapacityFrames * 2)
                            let count = try prefix.withUnsafeMutableBufferPointer {
                                try stream.read(into: $0, maximumFrames: source.prefixCapacityFrames)
                            }
                            guard !cancellation.value.load(ordering: .acquiring) else { throw Failure.cancelled }
                            let published = prefix.withUnsafeBufferPointer {
                                source.prepare(token: token, totalFrames: stream.totalFrames,
                                    prefix: UnsafeBufferPointer(rebasing: $0[..<(count * 2)]))
                            }
                            guard published else { throw Failure.slotInUse }
                            let state = Slot(index: index, token: token, source: source, description: description, cancellation: cancellation, stream: stream)
                            let beforeReplacement = progressRecorder.enter(.retiringSlots,
                                token: slots[index]?.token ?? 0, slot: index, epoch: slots[index]?.epoch ?? 0)
                            slots[index] = state
                            progressRecorder.restore(beforeReplacement)
                            let context = ProgressContext(token: token, slot: index, epoch: 0)
                            guard source.beginStream(epoch: progressRecorder.streamRequest(from: source, context: context).epoch) else { throw Failure.cancelled }
                            state.epoch = progressRecorder.streamRequest(from: source, context: context).epoch
                            stream.setProgressEpoch(state.epoch)
                            try fill(state, chunks: 8)
                            continuation.resume(returning: Prepared(token: token, totalFrames: stream.totalFrames, hasAudio: hasAudio))
                        } catch {
                            continuation.resume(throwing: (error as? Failure) ?? Failure.cannotDecode)
                        }
                    }
                }
            }
        } onCancel: {
            cancellation.value.store(true, ordering: .releasing)
            self.worker.async { [self] in
                let previous = progressRecorder.enter(.retiringSlots, token: token, slot: -1, epoch: 0)
                defer { progressRecorder.restore(previous) }
                for index in slots.indices where slots[index]?.token == token { retireSlot(at: index) }
            }
        }
    }

    /// Drop readers that are no longer in the bounded current/adjacent window.
    /// Storage retirement itself remains the renderer/source owner's decision.
    func retain(tokens: Set<Int>) {
        worker.async { [self] in
            let previous = progressRecorder.enter(.retiringSlots, token: 0, slot: -1, epoch: 0)
            defer { progressRecorder.restore(previous) }
            for index in slots.indices {
                if let slot = slots[index], !tokens.contains(slot.token) { retireSlot(at: index) }
            }
        }
    }

    private func retireSlot(at index: Int) {
        let previous = progressRecorder.enter(.retiringSlots,
            token: slots[index]?.token ?? 0, slot: index, epoch: slots[index]?.epoch ?? 0)
        slots[index] = nil
        progressRecorder.restore(previous)
    }

    /// The callback runs on the decode worker. Only an ephemeral numeric token
    /// and a fixed reason code cross this boundary; native NSError text may
    /// contain a private filename/URL and must not enter diagnostics.
    func setFailureHandler(_ handler: @escaping @Sendable (Int, Failure) -> Void) {
        worker.async { [self] in failureHandler = handler }
    }

    /// Runs once on the serial worker after a complete start-to-EOF decode. A
    /// cancelled/partial decode or a seek/reopen produces no guessed measurement.
    func setSourceSilenceHandler(_ handler: @escaping @Sendable (Int, SourceSilence) -> Void) {
        worker.async { [self] in sourceSilenceHandler = handler }
    }

    func shutdown() {
        progressRecorder.noteShutdownRequested()
        worker.async { [self] in
            let previous = progressRecorder.enter(.retiringSlots, token: 0, slot: -1, epoch: 0)
            defer { progressRecorder.restore(previous) }
            stopped = true
            timer?.setEventHandler {}; timer?.cancel(); timer = nil
            slots = [nil, nil, nil]
            // Only this existing cleanup body has returned from releasing slots.
            // This is not proof that all SDK-internal/autoreleased state is gone.
            progressRecorder.noteShutdownCompleted()
        }
    }

    private func pump() {
        guard !stopped else { return }
        let previous = progressRecorder.enter(.pumping, token: 0, slot: -1, epoch: 0)
        // Restore outside the closure: a deferred marker remains observable
        // throughout Objective-C autorelease-pool pop, including native releases.
        defer { progressRecorder.restore(previous) }
        autoreleasepool {
            let beforeSnapshot = progressRecorder.enter(.rendererSnapshot, token: 0, slot: -1, epoch: 0)
            let active = renderer.snapshot.token
            progressRecorder.restore(beforeSnapshot)
            progressRecorder.notePump(currentToken: active)
            _ = progressRecorder.enter(.pumping, token: active, slot: -1, epoch: 0)
            defer { _ = progressRecorder.enter(.poolDrain, token: active, slot: -1, epoch: 0) }
            // Current replenishment takes precedence over speculative neighbours.
            for isCurrent in [true, false] {
                for index in slots.indices {
                    guard let slot = slots[index], (slot.token == active) == isCurrent else { continue }
                    if slot.cancellation.value.load(ordering: .acquiring) || slot.source.token != slot.token {
                        retireSlot(at: index); continue
                    }
                    do { try fill(slot, chunks: isCurrent ? 8 : 2) }
                    catch {
                        if (error as? Failure) == .cancelled {
                            if slot.source.token != slot.token || slot.cancellation.value.load(ordering: .acquiring) {
                                retireSlot(at: index)
                            }
                            // Retirement/task cancellation is normal cleanup.
                            // An epoch change retains this slot for the next pump.
                            continue
                        }
                        // A failed reader must not publish fabricated success/EOF.
                        // Its source will report an underrun if it is selected.
                        retireSlot(at: index)
                        failureHandler?(slot.token, (error as? Failure) ?? .cannotDecode)
                    }
                }
            }
        }
    }

    private func fill(_ slot: Slot, chunks: Int) throws {
        let request = progressRecorder.streamRequest(from: slot.source,
            context: ProgressContext(token: slot.token, slot: slot.index, epoch: slot.epoch))
        let context = ProgressContext(token: slot.token, slot: slot.index, epoch: request.epoch)
        let previous = progressRecorder.enter(.pumping, context: context)
        defer { progressRecorder.restore(previous) }
        if request.epoch != slot.epoch {
            if request.startFrame >= slot.source.totalFrames {
                // A fully pinned short source loops entirely from its prefix.
                // No decoder is needed beyond EOF, and reopening there must not
                // turn a successful loop into a reader failure or new analysis.
                guard slot.source.beginStream(epoch: request.epoch) else { return }
                slot.epoch = request.epoch; slot.finished = true
                slot.source.finishStream(totalFrames: slot.source.totalFrames, epoch: slot.epoch)
                return
            }
            let source = slot.source, token = slot.token, cancellation = slot.cancellation, progress = progressRecorder
            let stream = try Stream(description: slot.description, startFrame: request.startFrame,
                progress: progressRecorder, context: context,
                shouldCancel: {
                    cancellation.value.load(ordering: .acquiring) || source.token != token
                        || progress.streamRequest(from: source, context: context).epoch != request.epoch
                })
            guard slot.source.beginStream(epoch: request.epoch) else { return }
            let beforeReplacement = progressRecorder.enter(.streamReplacement, context: context)
            slot.stream = stream; slot.epoch = request.epoch; slot.finished = false
            progressRecorder.restore(beforeReplacement)
        }
        guard !slot.finished else { return }
        for _ in 0..<chunks {
            guard slot.source.token == slot.token,
                  progressRecorder.streamRequest(from: slot.source, context: context).epoch == slot.epoch else { return }
            let capacity = min(8_192, slot.source.writableStreamFrames)
            guard capacity > 0 else { return }
            let count: Int
            do {
                count = try scratch.withUnsafeMutableBufferPointer {
                    try slot.stream.read(into: $0, maximumFrames: capacity)
                }
            } catch ReadControl.deferred {
                yieldCount.store(yieldCount.load(ordering: .relaxed) &+ 1, ordering: .releasing)
                // Stream keeps its converter and generated-frame cursor. Returning
                // to the pump lets the current source refill before the next
                // bounded discard step of a retained, far-away seek.
                return
            }
            if let analysis = slot.stream.takeSourceSilence() {
                sourceSilenceHandler?(slot.token, analysis)
            }
            if count == 0 {
                slot.source.finishStream(totalFrames: slot.stream.totalFrames, epoch: slot.epoch)
                slot.finished = true; return
            }
            let beforeAppend = progressRecorder.enter(.appending, context: context)
            let accepted = scratch.withUnsafeBufferPointer {
                slot.source.append(interleaved: UnsafeBufferPointer(rebasing: $0[..<(count * 2)]), epoch: slot.epoch)
            }
            progressRecorder.noteAccepted(frames: accepted, token: slot.token, slot: slot.index, epoch: slot.epoch)
            progressRecorder.restore(beforeAppend)
            // Only a new render epoch can invalidate an append after a read. The
            // next pump reopens at that request; stale PCM is never carried over.
            guard accepted == count else { return }
        }
    }

    private static func frame(_ time: CMTime, rate: Double = 48_000) throws -> Int64 {
        guard time.isNumeric, time.seconds.isFinite, abs(time.seconds) < 86_400 else { throw Failure.invalidTimeline }
        guard rate.isFinite, rate > 0, rate.rounded() == rate, rate <= 384_000 else { throw Failure.unsupportedPCM }
        return CMTimeConvertScale(time, timescale: CMTimeScale(rate), method: .roundHalfAwayFromZero).value
    }

    /// Native-rate demux/decode followed by an explicit, flushed converter. The
    /// reader's implicit sample-rate conversion is deliberately avoided: native
    /// regression runs found that it could omit buffered resampler tail samples.
    private final class Stream {
        #if DEBUG
        /// Diagnostic storage only: one interleaved 4,096-frame native buffer,
        /// at most 131,072 sample bytes at the accepted eight-channel limit.
        /// Reader replacement may briefly retain the old and new Stream.
        private final class StagedInput {
            let buffer: AVAudioPCMBuffer
            let channels: Int
            var cursor = 0
            var count = 0
            var requestedRefillFrames = 0
            var nativeEOF = false

            init(format: AVAudioFormat) throws {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else { throw Failure.unsupportedPCM }
                self.buffer = buffer; channels = Int(format.channelCount)
            }
        }
        private let stagedInput: StagedInput?
        #endif
        private let progress: ProgressRecorder
        private var progressContext: ProgressContext
        private let native: NativeReader?
        private let converter: AVAudioConverter?
        private let input: AVAudioPCMBuffer?
        private let output: AVAudioPCMBuffer?
        private let nativeRate: Double
        private let shouldCancel: () -> Bool
        private var outputStart: Int64 = 0
        private var outputCount = 0
        private var generatedFrames: Int64 = 0
        private var supportFramesSupplied: Int64 = 0
        private var converterFinished = false
        private var cursor: Int64
        private var eof = false
        private(set) var totalFrames: Int64
        private var analysisValid: Bool
        private var analysisReported = false
        private var firstAboveThreshold: Int64?
        private var lastAboveThreshold: Int64?
        private var peak: Float = 0

        init(description: Description, startFrame: Int64, progress: ProgressRecorder, context: ProgressContext,
             shouldCancel: @escaping () -> Bool) throws {
            self.progress = progress; progressContext = context
            let previous = progress.enter(.openingStream, context: context)
            defer { progress.restore(previous) }
            totalFrames = description.totalFrames; cursor = max(0, startFrame)
            nativeRate = description.nativeRate
            self.shouldCancel = shouldCancel
            analysisValid = startFrame == 0
            guard description.track != nil else {
                #if DEBUG
                stagedInput = nil
                #endif
                native = nil; converter = nil; input = nil; output = nil; return
            }
            let native = try NativeReader(description: description, progress: progress, context: context)
            guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: description.nativeRate,
                    channels: description.nativeChannels, interleaved: true),
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true) else { throw Failure.unsupportedPCM }
            let beforeConverter = progress.enter(.converterConstruction, context: context)
            let createdConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
            progress.restore(beforeConverter)
            guard let converter = createdConverter,
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_096),
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { throw Failure.unsupportedPCM }
            if description.nativeChannels == 1 { converter.channelMap = [0, 0] }
            self.native = native; self.converter = converter; self.input = input; self.output = output
            #if DEBUG
            switch description.nativeInputPlacement {
            case .converterCallback: stagedInput = nil
            case .stagedBeforeConversion: stagedInput = try StagedInput(format: inputFormat)
            }
            #endif
            // A reopen starts from the source's beginning and discards converted
            // output up to the requested frame. This retains exactly the original
            // SRC phase/history with bounded storage. Ordinary loop/reversal
            // refills only need to rebuild the fixed two-second pinned prefix.
        }

        func setProgressEpoch(_ epoch: Int) {
            progressContext = ProgressContext(token: progressContext.token, slot: progressContext.slot, epoch: epoch)
            native?.setProgressEpoch(epoch)
        }

        func read(into destination: UnsafeMutableBufferPointer<Float>, maximumFrames: Int) throws -> Int {
            let maximum = min(maximumFrames, destination.count / 2)
            let firstFrame = cursor
            var written = 0
            var skippedBuffers = 0
            while written < maximum {
                if shouldCancel() { throw Failure.cancelled }
                if native == nil {
                    let count = min(maximum - written, Int(max(0, totalFrames - cursor)))
                    guard count > 0 else { eof = true; break }
                    destination.baseAddress!.advanced(by: written * 2).update(repeating: 0, count: count * 2)
                    cursor += Int64(count); written += count; continue
                }
                if outputCount == 0, !eof { try convertNext() }
                if eof {
                    // No synthetic zeros may conceal an unflushed/short converter.
                    guard cursor >= totalFrames else { throw Failure.cannotDecode }
                    break
                }
                let end = outputStart + Int64(outputCount)
                if end <= cursor {
                    outputCount = 0
                    skippedBuffers += 1
                    // Yield only before emitting anything. No copied frames can
                    // be lost, and initial prefix preparation is unaffected.
                    if written == 0, skippedBuffers >= 8 { throw ReadControl.deferred }
                    continue
                }
                if outputStart >= totalFrames { outputCount = 0; continue }
                guard outputStart <= cursor, let samples = output?.floatChannelData?[0] else { throw Failure.invalidTimeline }
                let offset = Int(cursor - outputStart)
                let count = min(maximum - written, outputCount - offset, Int(max(0, totalFrames - cursor)))
                guard count > 0 else { outputCount = 0; continue }
                destination.baseAddress!.advanced(by: written * 2).update(from: samples.advanced(by: offset * 2), count: count * 2)
                cursor += Int64(count); written += count
                if cursor >= end { outputCount = 0 }
            }
            if analysisValid {
                // Inspect only the PCM already copied by this read. This adds no
                // demux pass, allocations, retained audio or render-thread work.
                for frame in 0..<written {
                    let left = destination[frame * 2], right = destination[frame * 2 + 1]
                    guard left.isFinite, right.isFinite else { analysisValid = false; break }
                    let magnitude = max(abs(left), abs(right))
                    peak = max(peak, magnitude)
                    if magnitude >= 0.001 {
                        if firstAboveThreshold == nil { firstAboveThreshold = firstFrame + Int64(frame) }
                        lastAboveThreshold = firstFrame + Int64(frame)
                    }
                }
            }
            return written
        }

        func takeSourceSilence() -> SourceSilence? {
            guard analysisValid, !analysisReported, eof, cursor >= totalFrames else { return nil }
            analysisReported = true
            return SourceSilence(totalFrames: totalFrames,
                leadingFrames: firstAboveThreshold ?? totalFrames,
                trailingFrames: lastAboveThreshold.map { totalFrames - $0 - 1 } ?? totalFrames,
                peak: peak)
        }

        private func convertNext() throws {
            #if DEBUG
            if let stagedInput { try convertNextStaged(stagedInput); return }
            #endif
            guard !converterFinished else { eof = true; return }
            guard let native, let converter, let input, let output else { throw Failure.cannotDecode }
            for _ in 0..<8 {
                if shouldCancel() { throw Failure.cancelled }
                output.frameLength = 0
                var inputFailure: Failure?
                var conversionError: NSError?
                let sourceTarget = totalFrames, rate = nativeRate
                var suppliedSupport = supportFramesSupplied
                let previous = progress.enter(.converting, context: progressContext)
                let status = converter.convert(to: output, error: &conversionError) { requested, status in
                    do {
                        guard requested > 0 else { status.pointee = .noDataNow; return nil }
                        let count = try native.read(into: input, maximumFrames: min(Int(requested), Int(input.frameCapacity)))
                        if count == 0 {
                            guard native.reachedEnd else { throw Failure.cannotDecode }
                            // A fractional target frame may require the next native
                            // sample for interpolation. Supply only the mathematically
                            // required zero support outside the original timeline;
                            // never append fabricated output PCM or change its end.
                            let target = sourceTarget
                            // Integral rates and the <24-hour source limit make
                            // this integer ceiling safe without floating ambiguity.
                            let requiredNative = (target * Int64(rate) + 47_999) / 48_000
                            let support = max(0, requiredNative - native.totalFrames)
                            let maximumSupport = Int64(ceil(rate / 96_000 + 0.5))
                            guard support <= maximumSupport else { throw Failure.invalidTimeline }
                            let needed = support - suppliedSupport
                            if needed > 0 {
                                let frames = min(Int(needed), Int(requested), Int(input.frameCapacity))
                                guard frames > 0, let samples = input.floatChannelData?[0] else { throw Failure.cannotDecode }
                                samples.update(repeating: 0, count: frames * Int(input.format.channelCount))
                                input.frameLength = AVAudioFrameCount(frames)
                                suppliedSupport += Int64(frames)
                                status.pointee = .haveData; return input
                            }
                            status.pointee = .endOfStream; return nil
                        }
                        status.pointee = .haveData; return input
                    } catch {
                        inputFailure = (error as? Failure) ?? .cannotDecode
                        status.pointee = .endOfStream; return nil
                    }
                }
                progress.restore(previous)
                supportFramesSupplied = suppliedSupport
                if let inputFailure { throw inputFailure }
                guard status != .error, conversionError == nil else { throw Failure.cannotDecode }
                if status == .endOfStream { converterFinished = true }
                outputStart = generatedFrames; outputCount = Int(output.frameLength)
                generatedFrames += Int64(outputCount)
                if outputCount > 0 { return }
                if converterFinished { eof = true; return }
            }
            throw Failure.cannotDecode
        }

        #if DEBUG
        /// Default-off nesting control. Native pulls remain synchronous on the
        /// same worker; this cannot cancel a blocked SDK call or ensure readiness.
        /// A callback first requests missing input with noDataNow. Only after
        /// convert returns may this path perform that bounded native read.
        private func convertNextStaged(_ stage: StagedInput) throws {
            guard !converterFinished else { eof = true; return }
            guard let native, let converter, let input, let output else { throw Failure.cannotDecode }
            var successfulRefills = 0
            var noProgressConversions = 0
            while true {
                if shouldCancel() { throw Failure.cancelled }
                if stage.requestedRefillFrames > 0, !stage.nativeEOF {
                    // A large downsample can require more than eight native
                    // pulls for one output buffer. Bound positive refill work
                    // separately from eight consecutive no-progress conversions.
                    guard successfulRefills < 64, stage.cursor == stage.count else { throw Failure.cannotDecode }
                    let count = try native.read(into: stage.buffer, maximumFrames: stage.requestedRefillFrames)
                    progress.noteStagedNativeRead()
                    if shouldCancel() { throw Failure.cancelled }
                    guard count > 0 || native.reachedEnd else { throw Failure.cannotDecode }
                    stage.cursor = 0; stage.count = count
                    stage.requestedRefillFrames = 0
                    if count == 0 { stage.nativeEOF = true }
                    successfulRefills += 1
                    noProgressConversions = 0
                }

                output.frameLength = 0
                var inputFailure: Failure?
                var conversionError: NSError?
                var consumedFrames = 0
                let sourceTarget = totalFrames, rate = nativeRate
                let previousSupport = supportFramesSupplied
                var suppliedSupport = previousSupport
                let previous = progress.enter(.converting, context: progressContext)
                let status = converter.convert(to: output, error: &conversionError) { requested, status in
                    do {
                        guard requested > 0 else { status.pointee = .noDataNow; return nil }
                        let maximum = min(Int(requested), Int(input.frameCapacity))
                        let available = stage.count - stage.cursor
                        if available > 0 {
                            let count = min(maximum, available)
                            guard let destination = input.floatChannelData?[0],
                                  let source = stage.buffer.floatChannelData?[0] else { throw Failure.unsupportedPCM }
                            destination.update(from: source.advanced(by: stage.cursor * stage.channels), count: count * stage.channels)
                            input.frameLength = AVAudioFrameCount(count)
                            stage.cursor += count; consumedFrames += count
                            status.pointee = .haveData; return input
                        }
                        guard stage.nativeEOF else {
                            // Remember the actual request instead of eagerly
                            // reading 4,096 frames. Leftovers survive later calls.
                            stage.requestedRefillFrames = max(1, min(maximum, 4_096))
                            status.pointee = .noDataNow; return nil
                        }
                        // Identical finite native-domain support and persistent
                        // EOS policy to the original callback path. No output
                        // zeros or presentation-duration changes are introduced.
                        let requiredNative = (sourceTarget * Int64(rate) + 47_999) / 48_000
                        let support = max(0, requiredNative - native.totalFrames)
                        let maximumSupport = Int64(ceil(rate / 96_000 + 0.5))
                        guard support <= maximumSupport else { throw Failure.invalidTimeline }
                        let needed = support - suppliedSupport
                        if needed > 0 {
                            let frames = min(Int(needed), maximum)
                            guard frames > 0, let samples = input.floatChannelData?[0] else { throw Failure.cannotDecode }
                            samples.update(repeating: 0, count: frames * stage.channels)
                            input.frameLength = AVAudioFrameCount(frames)
                            suppliedSupport += Int64(frames)
                            status.pointee = .haveData; return input
                        }
                        status.pointee = .endOfStream; return nil
                    } catch {
                        inputFailure = (error as? Failure) ?? .cannotDecode
                        status.pointee = .endOfStream; return nil
                    }
                }
                progress.restore(previous)
                supportFramesSupplied = suppliedSupport
                if let inputFailure { throw inputFailure }
                guard status != .error, conversionError == nil else { throw Failure.cannotDecode }
                if status == .endOfStream { converterFinished = true }
                outputStart = generatedFrames; outputCount = Int(output.frameLength)
                generatedFrames += Int64(outputCount)
                // inputRanDry may carry valid partial output. Publish it before
                // servicing the remembered request on the next invocation.
                if outputCount > 0 { return }
                if converterFinished { eof = true; return }
                if consumedFrames > 0 || suppliedSupport > previousSupport {
                    noProgressConversions = 0
                } else if stage.requestedRefillFrames == 0 || stage.nativeEOF {
                    noProgressConversions += 1
                    guard noProgressConversions < 8 else { throw Failure.cannotDecode }
                }
            }
        }
        #endif
    }

    /// Preserve native PCM sample counts; only explicit codec trim attachments
    /// may remove samples. Timestamps place edits/gaps on the source timeline.
    private final class NativeReader {
        private let progress: ProgressRecorder
        private var progressContext: ProgressContext
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let rate: Double
        private let channels: Int
        private var samples: [Float] = []
        private var sampleOffset = 0
        private var sampleCount = 0
        private var sampleStart: Int64 = 0
        private var cursor: Int64 = 0
        private var eof = false
        private(set) var totalFrames: Int64
        var reachedEnd: Bool { eof && sampleCount == 0 && cursor >= totalFrames }

        init(description: Description, progress: ProgressRecorder, context: ProgressContext) throws {
            self.progress = progress; progressContext = context
            let previous = progress.enter(.readerConfiguration, context: context)
            defer { progress.restore(previous) }
            guard let track = description.track else { throw Failure.cannotDecode }
            rate = description.nativeRate; channels = Int(description.nativeChannels)
            totalFrames = try ContinuousPCMDecoder.frame(description.endTime, rate: rate)
            do {
                let beforeConstruction = progress.enter(.readerConstruction, context: context)
                defer { progress.restore(beforeConstruction) }
                reader = try AVAssetReader(asset: description.asset)
            }
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.cannotDecode }
            reader.add(output)
            // The default range extends to positive infinity and may expose
            // decoder postroll outside a compressed asset's presentation.
            // Request the complete declared asset/track interval explicitly.
            reader.timeRange = CMTimeRange(start: .zero, duration: description.endTime)
            let beforeStart = progress.enter(.readerStart, context: context)
            let started = reader.startReading()
            progress.restore(beforeStart)
            guard started else { throw Failure.cannotDecode }
        }

        deinit {
            let previous = progress.enter(.readerCancel, context: progressContext)
            reader.cancelReading()
            progress.restore(previous)
        }

        func setProgressEpoch(_ epoch: Int) {
            progressContext = ProgressContext(token: progressContext.token, slot: progressContext.slot, epoch: epoch)
        }

        func read(into destination: AVAudioPCMBuffer, maximumFrames: Int) throws -> Int {
            guard let target = destination.floatChannelData?[0] else { throw Failure.unsupportedPCM }
            let maximum = min(maximumFrames, Int(destination.frameCapacity))
            var written = 0
            while written < maximum {
                if sampleCount == 0, !eof { try nextSample() }
                if sampleCount == 0, eof {
                    let count = min(maximum - written, Int(max(0, totalFrames - cursor)))
                    guard count > 0 else { break }
                    target.advanced(by: written * channels).update(repeating: 0, count: count * channels)
                    cursor += Int64(count); written += count; continue
                }
                let end = sampleStart + Int64(sampleCount)
                if end <= cursor { sampleCount = 0; continue }
                if sampleStart > cursor {
                    let count = min(maximum - written, Int(sampleStart - cursor))
                    target.advanced(by: written * channels).update(repeating: 0, count: count * channels)
                    cursor += Int64(count); written += count; continue
                }
                let offset = Int(cursor - sampleStart)
                let count = min(maximum - written, sampleCount - offset)
                samples.withUnsafeBufferPointer {
                    target.advanced(by: written * channels).update(from: $0.baseAddress!.advanced(by: (sampleOffset + offset) * channels), count: count * channels)
                }
                cursor += Int64(count); written += count
                if cursor >= end { sampleCount = 0 }
            }
            destination.frameLength = AVAudioFrameCount(written)
            return written
        }

        private func nextSample() throws {
            let previous = progress.enter(.nativeCopy, context: progressContext)
            let next = output.copyNextSampleBuffer()
            progress.restore(previous)
            guard let buffer = next else {
                guard reader.status == .completed else { throw Failure.cannotDecode }
                eof = true; return
            }
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                  asbd.pointee.mSampleRate == rate,
                  asbd.pointee.mChannelsPerFrame == channels,
                  asbd.pointee.mBytesPerFrame == channels * 4,
                  asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { throw Failure.unsupportedPCM }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes > 0, bytes % (channels * 4) == 0 else { throw Failure.unsupportedPCM }
            let frames = bytes / (channels * 4)
            // Reject an unexpectedly huge demux packet rather than allowing one
            // source to defeat the fixed prefix/ring memory budget.
            guard bytes <= 1_048_576 else { throw Failure.oversizedPacket }
            let outputPTS = CMSampleBufferGetOutputPresentationTimeStamp(buffer)
            let start = try ContinuousPCMDecoder.frame(outputPTS, rate: rate)
            // Output PTS may also contain a track edit/offset. Only the explicit
            // trim attachment identifies samples to omit from the PCM buffer;
            // subtracting raw PTS would mistake a legitimate edit for priming.
            func trim(_ key: CFString) throws -> Int64 {
                guard let dictionary = CMGetAttachment(buffer, key: key, attachmentModeOut: nil) as? [String: Any] else { return 0 }
                return max(0, try ContinuousPCMDecoder.frame(CMTimeMakeFromDictionary(dictionary as CFDictionary), rate: rate))
            }
            let trimStart = try trim(kCMSampleBufferAttachmentKey_TrimDurationAtStart)
            let trimEnd = try trim(kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
            guard trimStart + trimEnd <= Int64(frames) else { throw Failure.invalidTimeline }
            let decodedFrames = Int64(frames) - trimStart - trimEnd
            let outputDuration = CMSampleBufferGetOutputDuration(buffer)
            if outputDuration.isNumeric {
                let durationFrames = try ContinuousPCMDecoder.frame(outputDuration, rate: rate)
                // The native-rate output has no SRC discrepancy. A scaled edit
                // needs an explicit time-pitch implementation, not silent sample
                // deletion or duplication to force it onto the timeline.
                guard abs(durationFrames - decodedFrames) <= 1 else { throw Failure.unsupportedPCM }
            }
            // Explicit finite reader ranges can still straddle a packet. Keep
            // the intersection with the precise declared presentation, after
            // declared codec trims; decoder postroll cannot extend playback.
            let validFrames = max(0, min(decodedFrames, totalFrames - start))
            samples = [Float](repeating: 0, count: frames * channels)
            let result = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
            }
            guard result == kCMBlockBufferNoErr else { throw Failure.cannotDecode }
            sampleStart = start; sampleOffset = Int(trimStart); sampleCount = Int(validFrames)
        }
    }
}
