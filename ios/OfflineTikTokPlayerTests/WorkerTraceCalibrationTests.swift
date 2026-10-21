import Foundation
import XCTest

/// Lexicographic class ordering keeps this tool calibration after playback
/// observations. A known sleeping queue is not a reproduction of starvation.
@MainActor
final class ZZZWorkerTraceCalibrationTests: XCTestCase {
    func testKnownWorkerWaitPublishesBoundedSamplerCalibration() async throws {
        let workerID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        let queue = DispatchQueue(label: "OfflineTikTokPlayer.PCMDecode." + workerID, qos: .userInitiated)
        let entered = DispatchSemaphore(value: 0)
        queue.async {
            entered.signal()
            // No busy loop, native reader, audio graph or user data is involved.
            Thread.sleep(forTimeInterval: 6.5)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var active = false
        while !active, ProcessInfo.processInfo.systemUptime < deadline {
            active = entered.wait(timeout: .now()) == .success
            if !active { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard active else { XCTFail("The bounded calibration worker did not start"); return }
        let written = SelectionNativeWorkerSample.request(purpose: 2,
            workerIdentifier: workerID, identifier: requestID)
        XCTAssertTrue(written, "Calibration must publish its bounded request")
        print("SelectionNativeWorkerCalibration requestID=\(requestID) workerID=\(workerID) written=\(written)")
        // Separate from every playback timing window; host commands cap at
        // 1s PID + 1s bundle + 4s sampling. The host-log gate requires success.
        try await Task.sleep(for: .seconds(7))
    }
}
