import AVFoundation
import XCTest

final class PlayerShellTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor
    func testColdLaunchClearsSelectionAndBackgroundReturnKeepsIt() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let id = UUID().uuidString
        let title = "Session test " + id
        app.launchEnvironment["SESSION_TEST_MOVIE_ID"] = id
        let movie = try await sessionMovie(title: title)
        app.launchEnvironment["SESSION_TEST_MOVIE_DATA"] = movie.base64EncodedString()
        app.launch()
        // Opening Player explicitly selects video even if a prior run used Audio only.
        app.buttons["tab.player"].tap()
        app.buttons["tab.downloads"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15))
        saved.tap()
        let slider = app.sliders["Playback position"]
        let elapsed = app.staticTexts["playback.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        let initialSeconds = try XCTUnwrap(playbackSeconds(elapsed.label))
        let minimumPlayingSeconds = max(13, initialSeconds + 2)
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let seconds = self.playbackSeconds(elapsed.label) else { return false }
            return seconds >= minimumPlayingSeconds
        }, object: nil)
        await fulfillment(of: [advancing], timeout: 18)
        let playingSeconds = try XCTUnwrap(playbackSeconds(elapsed.label))
        XCTAssertGreaterThanOrEqual(playingSeconds, minimumPlayingSeconds, "The imported movie must actually play before testing its session.")
        app.buttons["tab.library"].tap()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        app.buttons["Open current video"].tap()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        let pausedSeconds = try XCTUnwrap(playbackSeconds(elapsed.label))
        XCTAssertGreaterThanOrEqual(pausedSeconds, playingSeconds)
        XCTAssertLessThan(pausedSeconds, 30, "The app must pause mid-clip before going Home.")
        let pausedThumb = slider.normalizedSliderPosition

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        // A running playhead would advance by at least two displayed seconds here.
        try await Task.sleep(for: .seconds(2))
        app.activate()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[title].exists)
        let returnedSeconds = try XCTUnwrap(playbackSeconds(elapsed.label))
        print("SESSION_PLAYHEAD first=\(initialSeconds) playing=\(playingSeconds) paused=\(pausedSeconds) foreground=\(returnedSeconds)")
        XCTAssertEqual(returnedSeconds, pausedSeconds, "The same clip must stay paused at the same elapsed time across Home.")
        XCTAssertEqual(slider.normalizedSliderPosition, pausedThumb, accuracy: 0.01,
                       "Returning to a paused clip must preserve its playhead within the slider's resolution.")

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchEnvironment.removeValue(forKey: "SESSION_TEST_MOVIE_ID")
        app.launchEnvironment.removeValue(forKey: "SESSION_TEST_MOVIE_DATA")
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Open current video"].exists)
        app.buttons["tab.player"].tap()
        XCTAssertTrue(app.buttons["Open Library"].waitForExistence(timeout: 10), "A new process must have no selected clip.")
        app.buttons["tab.downloads"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "The offline copy must outlive the playback session.")
    }

    private func playbackSeconds(_ label: String) -> Int? {
        let parts = label.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              minutes >= 0, (0..<60).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }

    @MainActor
    private func sessionMovie(title: String) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // The importer deduplicates file hashes. Give each test's asset its own metadata.
        let identity = AVMutableMetadataItem()
        identity.identifier = .commonIdentifierTitle
        identity.value = title as NSString
        writer.metadata = [identity]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let frame = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) { memset(base, 0x80, CVPixelBufferGetDataSize(frame)) }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let deadline = Date().addingTimeInterval(5)
        for index in 0..<120 {
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 4)))
        }
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return try Data(contentsOf: url)
    }

    #endif

    func testPersonalPlaylistPersistsAndActivityHasSeparateDestinations() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["tab.library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        let newPlaylist = app.buttons["New playlist"]
        if !newPlaylist.isHittable { app.swipeUp() }
        XCTAssertTrue(newPlaylist.isHittable)
        newPlaylist.tap()
        let name = app.textFields["Playlist name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let title = "Test mix \(UUID().uuidString.prefix(6))"
        name.typeText(title)
        app.buttons["Create playlist"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        app.buttons["tab.library"].tap()
        for destination in ["History", "Liked", title] {
            let row = app.staticTexts[destination]
            if !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.isHittable, "Missing Library row \(destination)")
            row.tap()
            let nav = app.navigationBars[destination]
            XCTAssertTrue(nav.waitForExistence(timeout: 5))
            nav.buttons["Library"].tap()
        }
    }

    func testLibraryAndPlaybackSettingsAreReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["tab.library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        // The native borderless List button exposes its rendered label; wrappers
        // can carry a different accessibility identifier from that actual button.
        let audioOnly = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Audio only'")).firstMatch
        XCTAssertTrue(audioOnly.waitForExistence(timeout: 5))
        if audioOnly.label == "Audio only, On" {
            audioOnly.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Audio only, Off'"), object: audioOnly)], timeout: 5), .completed)
        }
        audioOnly.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Audio only, On'"), object: audioOnly)], timeout: 5), .completed)
        let audioProof = XCTAttachment(screenshot: app.screenshot())
        audioProof.name = "Library Audio only switch"; audioProof.lifetime = .keepAlways
        add(audioProof)
        app.buttons["tab.player"].tap()
        app.buttons["tab.library"].tap()
        XCTAssertEqual(audioOnly.label, "Audio only, Off", "Opening Player explicitly restores video")
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.switches["Wi-Fi only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Automatic Picture in Picture"].exists)
        app.buttons["Done"].tap()

        // The underlying tab exists while the sheet is dismissing, but cannot be tapped yet.
        let settingsDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Settings"])
        XCTAssertEqual(XCTWaiter.wait(for: [settingsDismissed], timeout: 10), .completed,
                       "Settings must dismiss before navigating to Downloads")
        let downloadsTab = app.buttons["tab.downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10))
        // Require the real action and its destination. The failed run's movie
        // shows Settings already gone while a separate KVC predicate timed out.
        downloadsTab.tap()
        let reachedDownloads = app.navigationBars["Downloads"].waitForExistence(timeout: 10)
        if !reachedDownloads {
            print("DownloadsNavigationFailure " + app.debugDescription)
            let failure = XCTAttachment(screenshot: app.screenshot())
            failure.name = "After actual Downloads tap"; failure.lifetime = .keepAlways
            add(failure)
        }
        XCTAssertTrue(reachedDownloads, "A real Downloads tap must open its screen after Settings closes")
        XCTAssertTrue(app.buttons["Shuffle downloaded videos"].waitForExistence(timeout: 10))
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Native downloads screen"; proof.lifetime = .keepAlways
        add(proof)
    }
}
