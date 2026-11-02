import Foundation
import Dispatch

struct CadenceSpan: Sendable {
    var start: UInt64 = 0, end: UInt64 = 0
    var milliseconds: Double { Double(end - start) / 1_000_000 }
    mutating func record(start: UInt64, end: UInt64) {
        guard end >= start, end - start > self.end - self.start else { return }
        self.start = start; self.end = end
    }
}

/// Independent scheduling probe; no UIKit, frame buffers, or main-actor work.
final class CadenceHeartbeat: @unchecked Sendable {
    private let queue = DispatchQueue(label: "synthetic.video-cadence", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let start: UInt64
    private var stamps = [UInt64](repeating: 0, count: 1024), count = 0
    private var overflow = false
    init(start: UInt64) {
        self.start = start
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.count < self.stamps.count {
                self.stamps[self.count] = DispatchTime.now().uptimeNanoseconds; self.count += 1
            } else { self.overflow = true }
        }
        timer.resume()
    }
    func stop(end: UInt64) -> (ticks: Int, maximum: CadenceSpan, overflow: Bool) {
        timer.cancel()
        return queue.sync {
            var previous = start, maximum = CadenceSpan(), ticks = 0
            for index in 0..<count where stamps[index] <= end {
                maximum.record(start: previous, end: stamps[index]); previous = stamps[index]; ticks += 1
            }
            maximum.record(start: previous, end: end)
            return (ticks, maximum, overflow)
        }
    }
    deinit { timer.cancel() }
}
