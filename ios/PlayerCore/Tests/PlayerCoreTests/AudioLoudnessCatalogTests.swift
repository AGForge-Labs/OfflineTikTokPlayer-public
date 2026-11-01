import XCTest
@testable import PlayerCore

final class AudioLoudnessCatalogTests: XCTestCase {
    func testMeasuredLoudnessSurvivesDecodeEncodeWithoutChangingTheAsset() throws {
        let data = try measuredCatalog()
        let catalog = try LibraryCatalog.decode(data)
        let encoded = try JSONEncoder().encode(catalog)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try XCTUnwrap(object["media"] as? [[String: Any]])
        let measurement = try XCTUnwrap(rows[0]["audioLoudness"] as? [String: Any])
        XCTAssertEqual(measurement["version"] as? Int, 1)
        XCTAssertEqual(measurement["integratedLUFS"] as? Double, -26.27)
        XCTAssertEqual(measurement["truePeakDBTP"] as? Double, -11.36)
        XCTAssertEqual(measurement["assetSHA256"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(catalog.media[0].asset?.sha256, String(repeating: "a", count: 64))
    }

    func testInvalidLoudnessCannotEnterTheLibrary() throws {
        for replacement in [["version": 2], ["integratedLUFS": -150], ["truePeakDBTP": 999], ["assetSHA256": "bad"]] as [[String: Any]] {
            XCTAssertThrowsError(try LibraryCatalog.decode(measuredCatalog(replacing: replacement)))
        }
    }

    func testGainRequiresTheMeasuredAssetAndDoesNotAmplifySilence() throws {
        let catalog = try LibraryCatalog.decode(measuredCatalog())
        var item = catalog.media[0]
        XCTAssertEqual(try XCTUnwrap(item.normalizationGainDB), 16.27, accuracy: 0.0001)
        item.asset = catalog.media[1].asset
        XCTAssertNil(item.normalizationGainDB, "Replacing media invalidates old loudness credit")
        let silence = try AudioLoudness(assetSHA256: String(repeating: "a", count: 64), integratedLUFS: -65, truePeakDBTP: -65)
        XCTAssertNil(silence.normalizationGainDB(for: catalog.media[0].asset))
    }

    func testExtremeButValidLevelsKeepGainWithinTheSpeakerBudget() throws {
        let asset = try LibraryCatalog.decode(measuredCatalog()).media[0].asset
        let quiet = try AudioLoudness(assetSHA256: String(repeating: "a", count: 64), integratedLUFS: -50, truePeakDBTP: -40)
        let loud = try AudioLoudness(assetSHA256: String(repeating: "a", count: 64), integratedLUFS: 5, truePeakDBTP: 6)
        XCTAssertEqual(quiet.normalizationGainDB(for: asset), 24)
        XCTAssertEqual(loud.normalizationGainDB(for: asset), -12)
    }

    func testSpeakerTargetMatchesLouderMusicInsteadOfTurningOrdinaryMusicDown() throws {
        let asset = try LibraryCatalog.decode(measuredCatalog()).media[0].asset
        for (level, gain) in [(-20.0, 10.0), (-14, 4), (-10, 0), (-8.74, -1.26)] {
            let measurement = try AudioLoudness(assetSHA256: String(repeating: "a", count: 64),
                integratedLUFS: level, truePeakDBTP: -0.5)
            XCTAssertEqual(try XCTUnwrap(measurement.normalizationGainDB(for: asset)), gain, accuracy: 0.0001)
        }
    }

    private func measuredCatalog(replacing fields: [String: Any] = [:]) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(CatalogTests.fixture.utf8)) as? [String: Any])
        var rows = try XCTUnwrap(root["media"] as? [[String: Any]])
        var measured: [String: Any] = ["version": 1, "assetSHA256": String(repeating: "a", count: 64),
                                      "integratedLUFS": -26.27, "truePeakDBTP": -11.36]
        for (key, value) in fields { measured[key] = value }
        rows[0]["audioLoudness"] = measured
        root["media"] = rows
        return try JSONSerialization.data(withJSONObject: root)
    }
}
