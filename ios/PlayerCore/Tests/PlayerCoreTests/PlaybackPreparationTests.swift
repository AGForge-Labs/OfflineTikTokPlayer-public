import XCTest
@testable import PlayerCore

@MainActor
final class PlaybackPreparationTests: XCTestCase {
    func testCompletedPreparationReturnsItsValue() async {
        let value = await PlaybackPreparation.value(within: .seconds(1)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testSuspendedPreparationDoesNotHoldUpPlaybackAndLateCompletionIsIgnored() async throws {
        var release: CheckedContinuation<Int?, Never>?
        let safety = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            release?.resume(returning: 42); release = nil
        }
        defer { safety.cancel() }
        let start = ContinuousClock.now
        let value = await PlaybackPreparation.value(within: .milliseconds(20)) {
            await withCheckedContinuation { release = $0 }
        }
        XCTAssertNil(value)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        let continuation = try XCTUnwrap(release)
        continuation.resume(returning: 42); release = nil
        await Task.yield()
    }

    func testCancellingPreparationDoesNotWaitForASuspendedLoader() async throws {
        var release: CheckedContinuation<Int?, Never>?
        let safety = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            release?.resume(returning: 42); release = nil
        }
        defer { safety.cancel() }
        let task = Task {
            await PlaybackPreparation.value(within: .seconds(10)) {
                await withCheckedContinuation { release = $0 }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while release == nil, ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try XCTUnwrap(release)
        task.cancel()
        let start = ContinuousClock.now
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        if release != nil { continuation.resume(returning: 42); release = nil }
        await Task.yield()
    }
}
