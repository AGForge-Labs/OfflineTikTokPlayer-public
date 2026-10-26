import Foundation

public enum PlaybackWarmupOrder {
    public static func ids(current: String?, previous: String?, upcoming: [String]) -> [String] {
        var seen = Set<String>()
        return ([current].compactMap { $0 } + upcoming + [previous].compactMap { $0 })
            .filter { seen.insert($0).inserted }
    }
}
