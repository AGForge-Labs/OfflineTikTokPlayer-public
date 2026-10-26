import Foundation

public enum PlaybackWarmupOrder {
    public static func ids(current: String?, previous: String?, upcoming: [String]) -> [String] {
        var seen = Set<String>()
        return (Array(upcoming.prefix(1)) + [current, previous].compactMap { $0 } + Array(upcoming.dropFirst()))
            .filter { seen.insert($0).inserted }
    }
}
