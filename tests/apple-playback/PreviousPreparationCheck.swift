import Foundation
import AVFoundation

/// A fast Apple-framework check of the production buffer, before simulator boot.
@main
struct PreviousPreparationCheck {
    @MainActor
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let first = AVPlayerItem(url: url), second = AVPlayerItem(url: url)
        let buffer = PlaybackBuffer()
        defer { buffer.player.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: first, mediaID: "a")
        let deadline = Date().addingTimeInterval(5)
        while first.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard first.status == .readyToPlay else { throw failure("Synthetic local item did not become ready") }
        let positioned = await buffer.player.seek(to: CMTime(seconds: 0.4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        guard positioned else { throw failure("Could not position the synthetic previous item") }
        buffer.stage(.init(mediaID: "b", item: second, isLocal: true))
        guard buffer.advance(to: "b") != nil else { throw failure("Could not stage the next item") }
        try await Task.sleep(for: .milliseconds(500))
        let preparedPosition = first.currentTime().seconds
        guard let previous = buffer.advance(to: "a"), !previous.needsRewind,
              abs(preparedPosition) < 0.005, buffer.player.rate == 0 else {
            throw failure("Previous did not rewind silently during preparation: position=\(preparedPosition)")
        }
        print("Apple framework previous preparation: sourceOffset=0.4, preparedOffset=\(preparedPosition), rewindReadyBeforeHandoff=true, retainedItems=\(buffer.retainedItemCount)")
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "PreviousPreparationCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
