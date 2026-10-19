import Foundation

@MainActor
public enum PlaybackPreparation {
    /// Metadata is optional preparation, not a reason to hold playback indefinitely.
    /// Unlike a task group, this can finish even if the loader ignores cancellation.
    public static func value<Value>(within budget: Duration,
                                    operation: @escaping @MainActor () async -> Value?) async -> Value? {
        let race = PreparationRace<Value>()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { race.start($0, budget: budget, operation: operation) }
        } onCancel: {
            Task { @MainActor in race.finish(nil) }
        }
    }
}

@MainActor
private final class PreparationRace<Value> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var finished = false

    func start(_ continuation: CheckedContinuation<Value?, Never>, budget: Duration,
               operation: @escaping @MainActor () async -> Value?) {
        guard !finished else { continuation.resume(returning: nil); return }
        self.continuation = continuation
        work = Task { [weak self] in
            let value = await operation()
            guard !Task.isCancelled else { return }
            self?.finish(value)
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: budget) } catch { return }
            self?.finish(nil)
        }
    }

    func finish(_ value: Value?) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        work?.cancel(); work = nil
        deadline?.cancel(); deadline = nil
        continuation?.resume(returning: value)
    }
}
