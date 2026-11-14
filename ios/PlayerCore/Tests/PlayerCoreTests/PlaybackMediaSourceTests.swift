import XCTest
@testable import PlayerCore

final class PlaybackMediaSourceTests: XCTestCase {
    private func asset(_ digit: String, bytes: Int64 = 3) -> AssetReference {
        AssetReference(driveID: "synthetic", itemID: digit, fileName: digit + ".mp4", byteSize: bytes,
            sha256: String(repeating: digit, count: 64), contentType: "video/mp4")
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func cache(_ directory: URL, limit: Int64) throws -> PlaybackMediaCache {
        try PlaybackMediaCache(directory: directory, byteLimit: limit) { _ in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("abc".utf8).write(to: temporary)
            return temporary
        }
    }

    func testOversizedCloudVideoStreamsWithoutStartingWholeFileTransfer() async throws {
        let directory = folder(), calls = SourceCalls(), video = asset("a", bytes: 268_435_457)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackMediaCache(directory: directory) { _ in
            await calls.loaded()
            throw CatalogError.invalid("Playback must not wait for a full-file download")
        }
        await cache.setWindow([video], revision: 1)
        let remote = URL(string: "https://example.invalid/selected-original.mp4")!
        let source = try await PlaybackMediaSource.resolve(saved: nil, asset: video, cache: cache, allowRemote: true) { _ in
            await calls.resolved(); return remote
        }
        XCTAssertEqual(source, .stream(remote))
        let counts = await calls.counts
        XCTAssertEqual(counts.loads, 0); XCTAssertEqual(counts.resolves, 1)
    }

    func testProtectedWarmNeighboursCannotRejectSelectedCloudVideo() async throws {
        let directory = folder(), a = asset("a"), b = asset("b"), chosen = asset("c")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try cache(directory, limit: 6)
        await cache.setWindow([a, b, chosen], revision: 1)
        _ = await cache.prefetch(a, revision: 1); _ = await cache.prefetch(b, revision: 1)
        let refused = await cache.prefetch(chosen, revision: 1)
        XCTAssertNil(refused, "Exercise a real cache budget refusal, not a stub")
        let remote = URL(string: "https://example.invalid/selected.mp4")!
        let source = try await PlaybackMediaSource.resolve(saved: nil, asset: chosen, cache: cache, allowRemote: true) { _ in remote }
        XCTAssertEqual(source, .stream(remote))
        let keptA = await cache.file(for: a), keptB = await cache.file(for: b)
        XCTAssertNotNil(keptA); XCTAssertNotNil(keptB)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2, "Streaming must preserve the bounded cache and existing owners")
    }

    func testSavedAndVerifiedCacheArePreferredWithoutRemoteResolution() async throws {
        let directory = folder(), video = asset("a"), calls = SourceCalls()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try cache(directory, limit: 6)
        await cache.setWindow([video], revision: 1)
        let prepared = await cache.prefetch(video, revision: 1)
        let warmed = try XCTUnwrap(prepared)
        let saved = directory.appendingPathComponent("explicit-saved.mp4")
        let offline = try await PlaybackMediaSource.resolve(saved: saved, asset: video, cache: cache, allowRemote: false) { _ in
            await calls.resolved(); throw CatalogError.invalid("Saved must stay local")
        }
        let cached = try await PlaybackMediaSource.resolve(saved: nil, asset: video, cache: cache, allowRemote: false) { _ in
            await calls.resolved(); throw CatalogError.invalid("Verified cache must stay local")
        }
        XCTAssertEqual(offline, .verifiedFile(saved)); XCTAssertEqual(cached, .verifiedFile(warmed))
        let counts = await calls.counts
        XCTAssertEqual(counts.resolves, 0)
    }

    func testOfflineMissingSourceDoesNotRequestNetwork() async throws {
        let calls = SourceCalls()
        do {
            _ = try await PlaybackMediaSource.resolve(saved: nil, asset: asset("a"), cache: nil, allowRemote: false) { _ in
                await calls.resolved(); return URL(string: "https://example.invalid/forbidden.mp4")!
            }
            XCTFail("An unavailable offline selection must fail without network access")
        } catch {}
        let counts = await calls.counts
        XCTAssertEqual(counts.resolves, 0)
    }

    func testRemoteRetryRefreshesURLRatherThanReusingCachedFile() async throws {
        let directory = folder(), video = asset("a"), calls = SourceCalls()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try cache(directory, limit: 6)
        await cache.setWindow([video], revision: 1)
        let warmed = await cache.prefetch(video, revision: 1)
        XCTAssertNotNil(warmed)
        let renewed = URL(string: "https://example.invalid/renewed.mp4")!
        let source = try await PlaybackMediaSource.resolve(saved: nil, asset: video, cache: cache, allowRemote: true, forceRemote: true) { _ in
            await calls.resolved(); return renewed
        }
        XCTAssertEqual(source, .stream(renewed))
        let counts = await calls.counts
        XCTAssertEqual(counts.resolves, 1)
    }

    func testQualityIndexBindsVariantsToOriginalBytesAndKeepsLocalCopy() async throws {
        let archive = asset("a"), enhanced = asset("b"), changed = asset("c")
        let first = MediaRecord(id: "first", title: "First", status: .ready, asset: archive, original: archive)
        let second = MediaRecord(id: "second", title: "Second", status: .ready, asset: changed)
        let base = try LibraryCatalog(libraryID: "example", media: [first, second],
            playlists: [.init(id: "playlist", name: "Playlist", itemIDs: [first.id, second.id])])
        let variant = StreamEnhancement(sourceSHA256: archive.sha256, asset: enhanced, audioMastered: true)
        let assetJSON = try JSONEncoder().encode([first.id: variant, second.id: variant])
        let data = Data(("{\"version\":1,\"libraryId\":\"example\",\"items\":" + String(decoding: assetJSON, as: UTF8.self) + "}").utf8)
        let index = try JSONDecoder().decode(StreamQualityIndex.self, from: data)
        let catalog = try index.applying(to: base)
        let media = try XCTUnwrap(catalog.mediaByID[first.id])
        XCTAssertEqual(catalog.playlists, base.playlists)
        XCTAssertEqual(media.asset, archive)
        XCTAssertEqual(media.original, archive)
        XCTAssertEqual(media.preferredStream, enhanced)
        XCTAssertEqual(catalog.mediaByID[second.id]?.preferredStream, changed)
        let saved = URL(fileURLWithPath: "/Saved/a.mp4")
        let local = try await PlaybackMediaSource.resolve(saved: saved, media: media, cache: nil, allowRemote: false) { _ in
            XCTFail("Explicit saved copies stay available without the network")
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(local.source, .verifiedFile(saved)); XCTAssertFalse(local.mastered)
    }

    func testEnhancedStreamAndArchiveFallbackIdentifyTheActualAudioProfile() async throws {
        let archive = asset("a"), enhanced = asset("b")
        let media = MediaRecord(id: "clip", title: "Clip", status: .ready, asset: archive,
            streamEnhancement: .init(sourceSHA256: archive.sha256, asset: enhanced, audioMastered: true))
        let remote = URL(string: "https://example.invalid/video.mp4")!
        let chosen = try await PlaybackMediaSource.resolve(saved: nil, media: media, cache: nil, allowRemote: true) { reference in
            XCTAssertEqual(reference, enhanced); return remote
        }
        XCTAssertEqual(chosen.source, .stream(remote)); XCTAssertTrue(chosen.mastered); XCTAssertTrue(chosen.enhanced)
        var attempted = [AssetReference]()
        let fallback = try await PlaybackMediaSource.resolve(saved: nil, media: media, cache: nil, allowRemote: true) { reference in
            attempted.append(reference)
            if reference == enhanced { throw URLError(.resourceUnavailable) }
            return remote
        }
        XCTAssertEqual(attempted, [enhanced, archive])
        XCTAssertEqual(fallback.source, .stream(remote)); XCTAssertFalse(fallback.mastered); XCTAssertFalse(fallback.enhanced)
        try await _ = PlaybackMediaSource.resolve(saved: nil, media: media, cache: nil, allowRemote: true, useOriginal: true) { reference in
            XCTAssertEqual(reference, archive); return remote
        }
    }
}

private actor SourceCalls {
    private var loads = 0, resolves = 0
    var counts: (loads: Int, resolves: Int) { (loads, resolves) }
    func loaded() { loads += 1 }
    func resolved() { resolves += 1 }
}
