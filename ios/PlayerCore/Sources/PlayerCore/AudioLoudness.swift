import Foundation

/// A measured playback asset, never an assumption about the source song.
public struct AudioLoudness: Codable, Hashable, Sendable {
    public let version: Int
    public let assetSHA256: String
    public let integratedLUFS: Double
    public let truePeakDBTP: Double

    public init(assetSHA256: String, integratedLUFS: Double, truePeakDBTP: Double, version: Int = 1) throws {
        guard version == 1, assetSHA256.count == 64,
              assetSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              integratedLUFS.isFinite, (-70...10).contains(integratedLUFS),
              truePeakDBTP.isFinite, (-100...20).contains(truePeakDBTP) else {
            throw CatalogError.invalid("Invalid audio loudness measurement.")
        }
        self.version = version
        self.assetSHA256 = assetSHA256
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
    }

    private enum CodingKeys: String, CodingKey { case version, assetSHA256, integratedLUFS, truePeakDBTP }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(assetSHA256: fields.decode(String.self, forKey: .assetSHA256),
            integratedLUFS: fields.decode(Double.self, forKey: .integratedLUFS),
            truePeakDBTP: fields.decode(Double.self, forKey: .truePeakDBTP),
            version: fields.decode(Int.self, forKey: .version))
    }

    public func normalizationGainDB(for asset: AssetReference?) -> Double? {
        guard asset?.sha256 == assetSHA256, integratedLUFS > -60 else { return nil }
        // Match the louder archived music, then retain EQ and linked peak
        // protection. A -14 target would turn ordinary songs down on speakers.
        return min(24, max(-12, -10 - integratedLUFS))
    }
}
