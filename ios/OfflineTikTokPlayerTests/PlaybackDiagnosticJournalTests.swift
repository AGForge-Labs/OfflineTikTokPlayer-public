import Foundation
import XCTest
#if canImport(OfflineTikTokPlayer)
@testable import OfflineTikTokPlayer
#else
@testable import PlaybackSupport
#endif

final class PlaybackDiagnosticJournalTests: XCTestCase {
    func testCapacityEvictsOnlyTheOldestEventsInChronologicalOrder() {
        var journal = PlaybackDiagnosticJournal(capacity: 3)
        for generation in 0..<7 {
            journal.record(.pipStateChanged, snapshot: .init(generation: generation), uptime: Double(generation))
        }
        XCTAssertEqual(journal.entries.map(\.snapshot.generation), [4, 5, 6])
        XCTAssertEqual(journal.entries.map(\.sequence), [4, 5, 6])
        XCTAssertEqual(journal.droppedEvents, 4)
        XCTAssertEqual(journal.entries.count, 3)
    }

    func testNumericalSnapshotRejectsNonfiniteValuesAndExportHasNoFreeTextFields() throws {
        var journal = PlaybackDiagnosticJournal()
        let snapshot = PlaybackDiagnosticSnapshot(generation: 7, audioRequested: true, audioPermitted: false,
            audioInterrupted: true, presentation: .audioOnly, pipeline: .paused,
            positionSeconds: .nan, durationSeconds: .infinity, playbackRate: -.infinity,
            retainedItems: -10, preparedPCMBytes: -20, outputRoute: .builtInSpeaker,
            sampleRate: .nan, ioBufferSeconds: -.infinity, outputLatencySeconds: -1,
            pipActive: true, pipPossible: false, pipSuspended: true)
        journal.record(.pipStateChanged, snapshot: snapshot, uptime: 100)
        journal.record(.audioInterruptionBegan, snapshot: snapshot, uptime: 99)
        journal.record(.sampled, snapshot: snapshot, uptime: .nan)
        let data = try journal.exportJSON()
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(document["events"] as? [[String: Any]])
        let recorded = try XCTUnwrap(entries.first?["snapshot"] as? [String: Any])
        XCTAssertNil(recorded["positionSeconds"])
        XCTAssertNil(recorded["durationSeconds"])
        XCTAssertNil(recorded["playbackRate"])
        XCTAssertNil(recorded["sampleRate"])
        XCTAssertNil(recorded["ioBufferSeconds"])
        XCTAssertNil(recorded["outputLatencySeconds"])
        XCTAssertEqual(recorded["retainedItems"] as? Int, 0)
        XCTAssertEqual(recorded["preparedPCMBytes"] as? Int, 0)
        XCTAssertEqual(entries.compactMap { $0["elapsedSeconds"] as? Double }, [0, 0, 0])
        XCTAssertTrue(try containsOnlyNumbersAndContainers(document))
    }

    func testClearingRemovesPreviousSessionAndBoundsInvalidCapacity() throws {
        var journal = PlaybackDiagnosticJournal(capacity: .max)
        XCTAssertEqual(journal.capacity, 1_024)
        journal.record(.pipStartFailed, snapshot: .init(), error: .init(family: .avKit, code: -100), uptime: 10)
        journal.clear()
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertEqual(journal.droppedEvents, 0)
        journal.record(.appForegrounded, snapshot: .init(), uptime: 300)
        XCTAssertEqual(journal.entries.first?.sequence, 0)
        XCTAssertEqual(journal.entries.first?.elapsedSeconds, 0)
        let encoded = try XCTUnwrap(String(data: journal.exportJSON(), encoding: .utf8))
        XCTAssertFalse(encoded.contains("-100"))
        XCTAssertEqual(PlaybackDiagnosticJournal(capacity: 0).capacity, 1)
    }

    func testDefaultFullJournalExportStaysBelow256KiBWithAllNumericFields() throws {
        var journal = PlaybackDiagnosticJournal()
        let snapshot = PlaybackDiagnosticSnapshot(generation: .max, audioRequested: true,
            audioPermitted: true, audioInterrupted: true, interruptionReason: .max,
            interruptionOptions: .max, wasSuspended: true, routeChangeReason: .max,
            engineRunning: true, audioOnlySelected: true, presentation: .audioOnly, pipeline: .playing,
            positionSeconds: .greatestFiniteMagnitude, durationSeconds: .greatestFiniteMagnitude,
            playbackRate: .greatestFiniteMagnitude, retainedItems: .max, preparedPCMBytes: .max,
            underrunFrames: .max, outputRoute: .other, sampleRate: .greatestFiniteMagnitude,
            ioBufferSeconds: .greatestFiniteMagnitude, outputLatencySeconds: .greatestFiniteMagnitude,
            pipActive: true, pipPossible: true, pipSuspended: true)
        for index in 0..<journal.capacity {
            journal.record(.audioInterruptionBegan, snapshot: snapshot,
                           error: .init(family: .audioSession, code: .min), uptime: Double(index))
        }
        XCTAssertEqual(journal.entries.count, 256)
        XCTAssertLessThan(try journal.exportJSON().count, 256 * 1_024)
    }

    private func containsOnlyNumbersAndContainers(_ value: Any) throws -> Bool {
        if value is NSNumber || value is NSNull { return true }
        if let dictionary = value as? [String: Any] {
            return try dictionary.values.allSatisfy { try containsOnlyNumbersAndContainers($0) }
        }
        if let array = value as? [Any] {
            return try array.allSatisfy { try containsOnlyNumbersAndContainers($0) }
        }
        return false
    }
}
