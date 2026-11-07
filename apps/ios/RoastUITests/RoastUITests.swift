import XCTest

final class RoastUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSavedVideoDetailHasReadableStatusAndOneShareAction() throws {
        let app = XCUIApplication()
        app.launch()
        try openSavedVideoFixture(in: app, id: "A63947CD-0FBF-4B17-B8FD-8D8DA1CBB014")
        XCTAssertTrue(app.staticTexts["savedVideoTitle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["savedVideoStatus"].label.contains("Saved to Photos"))
        XCTAssertTrue(app.buttons["shareSavedVideoButton"].isEnabled)
        XCTAssertFalse(app.buttons["saveTakeToPhotosButton"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Saved video with readable title and Photos status"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["shareSavedVideoButton"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 8), "Share opens the native sheet without sending the video.")
    }

    @MainActor func testSavedVideoWithoutPhotosCopyOffersSave() throws {
        let app = XCUIApplication()
        app.launch()
        try openSavedVideoFixture(in: app, id: "983B871F-C2A9-4A99-90DC-17E7291E11B5")
        XCTAssertTrue(app.descendants(matching: .any)["savedVideoStatus"].label.contains("Saved in My videos"))
        XCTAssertTrue(app.buttons["saveTakeToPhotosButton"].isEnabled)
        XCTAssertTrue(app.buttons["shareSavedVideoButton"].isEnabled)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Saved video with optional Photos save"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["closeSavedVideoButton"].tap()
        XCTAssertTrue(app.tabBars.buttons["My videos"].waitForExistence(timeout: 5))
    }

    @MainActor func testSavedVideoDetailSupportsLargeText() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        try openSavedVideoFixture(in: app, id: "A63947CD-0FBF-4B17-B8FD-8D8DA1CBB014")
        let close = app.buttons["closeSavedVideoButton"]
        XCTAssertGreaterThanOrEqual(close.frame.minY, 0, "Large text must not push the header out of the screen.")
        let share = app.buttons["shareSavedVideoButton"]
        for _ in 0..<4 where !share.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(share.isHittable)
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(share.frame.minX, 0)
        XCTAssertLessThanOrEqual(share.frame.maxX, app.frame.maxX)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Saved video with largest accessibility text"
        proof.lifetime = .keepAlways
        add(proof)
    }

    @MainActor private func openSavedVideoFixture(in app: XCUIApplication, id: String) throws {
        app.tabBars.buttons["My videos"].tap()
        let video = app.buttons["recentSaved-\(id)"]
        guard video.waitForExistence(timeout: 6) else {
            throw XCTSkip("Seed the synthetic saved-video fixtures to check the detail screen.")
        }
        for _ in 0..<4 where !video.isHittable { app.scrollViews.firstMatch.swipeUp() }
        video.tap()
        XCTAssertTrue(app.buttons["closeSavedVideoButton"].waitForExistence(timeout: 6))
    }

    @MainActor func testAccountIsOptionalAndAccessibleFromSettings() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["videoLinkField"].waitForExistence(timeout: 8))
        app.buttons["Settings"].tap()
        let account = app.buttons["accountSettingsButton"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["accountAppleSignInButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["accountGoogleSignInButton"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "RecordPOV optional Apple and Google account"
        proof.lifetime = .keepAlways
        add(proof)
        app.navigationBars["Account"].buttons["Settings"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["videoLinkField"].waitForExistence(timeout: 5))
    }

    @MainActor func testCreateAndScreenRecordingHaveSeparateTabs() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["videoLinkField"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["RecordPOV"].exists)
        XCTAssertTrue(app.buttons["openStudioButton"].exists)
        XCTAssertFalse(app.buttons["screenTakeButton"].exists)
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "RecordPOV create"; home.lifetime = .keepAlways; add(home)
        app.tabBars.buttons["Screen"].tap()
        XCTAssertTrue(app.navigationBars["Screen recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "RecordPOV screen recording"; screen.lifetime = .keepAlways; add(screen)
        app.tabBars.buttons["My videos"].tap()
        XCTAssertTrue(app.staticTexts["My videos"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.textFields["videoLinkField"].waitForExistence(timeout: 5))
    }

    @MainActor func testUnfinishedTakeCanBeReopenedWithoutLosingItsDraft() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["My videos"].tap()
        let row = app.buttons["recentDraft-CB4001FA-5E5D-43B7-843A-CA4779B8C0F0"]
        guard row.waitForExistence(timeout: 5) else {
            throw XCTSkip("Seed the synthetic unfinished draft to check recovery navigation.")
        }
        row.tap()
        XCTAssertTrue(app.staticTexts["Edit video"].waitForExistence(timeout: 5))
        app.buttons["Audio"].tap()
        XCTAssertTrue(app.sliders["My voice volume"].exists)
        app.buttons["Close editor"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["saveEditedVideoButton"].waitForExistence(timeout: 5))
    }

    @MainActor func testSyntheticEditorExposesIndependentAudioCutsAndOptionalCaptions() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ROAST_EDITOR_PREVIEW"] = "1"
        app.launch()
        guard app.staticTexts["Edit video"].waitForExistence(timeout: 6) else {
            throw XCTSkip("Seed the synthetic Caches/EditorTest fixtures to check the editor UI.")
        }
        XCTAssertTrue(app.descendants(matching: .any)["editorThumbnailTimeline"].exists)
        app.buttons["Audio"].tap()
        XCTAssertTrue(app.sliders["My voice volume"].exists)
        XCTAssertTrue(app.sliders["Original video volume"].exists)
        let cleanup = app.switches["cleanVoiceToggle"]
        XCTAssertTrue(cleanup.exists)
        let initialCleanup = cleanup.value as? String
        cleanup.tap()
        XCTAssertNotEqual(cleanup.value as? String, initialCleanup)
        cleanup.tap()
        XCTAssertEqual(cleanup.value as? String, initialCleanup)
        XCTAssertTrue(app.buttons["Add music"].exists)
        let audio = XCTAttachment(screenshot: app.screenshot())
        audio.name = "Editor independent audio controls"; audio.lifetime = .keepAlways; add(audio)
        app.buttons["Trim"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["timelineTrimStart"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["timelineTrimEnd"].exists)
        XCTAssertFalse(app.buttons["Mark cut start"].exists)
        XCTAssertFalse(app.buttons["Remove to playhead"].exists)
        XCTAssertTrue(app.buttons["resetTrimButton"].exists)
        let trim = XCTAttachment(screenshot: app.screenshot())
        trim.name = "Editor trim and cuts"; trim.lifetime = .keepAlways; add(trim)
        app.buttons["Captions"].tap()
        XCTAssertTrue(app.buttons["Generate captions"].exists)
        XCTAssertTrue(app.staticTexts["Only your voice is captioned, on this device. A language download may be needed."].exists)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["saveEditedVideoButton"])
        waitForExpectations(timeout: 8)
        let captions = XCTAttachment(screenshot: app.screenshot())
        captions.name = "Editor optional microphone captions"; captions.lifetime = .keepAlways; add(captions)
    }

    @MainActor func testTrimHandlesSeekPreviewAndKeepSaveAvailable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ROAST_EDITOR_PREVIEW"] = "1"
        app.launch()
        guard app.staticTexts["Edit video"].waitForExistence(timeout: 6) else {
            throw XCTSkip("Seed the synthetic Caches/EditorTest fixtures to check live trimming.")
        }
        app.buttons["Trim"].tap()
        app.buttons["resetTrimButton"].tap()
        let start = app.descendants(matching: .any)["timelineTrimStart"]
        let end = app.descendants(matching: .any)["timelineTrimEnd"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        let originalEnd = end.value as? String
        let endPoint = end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        endPoint.press(forDuration: 0.1, thenDragTo: endPoint.withOffset(CGVector(dx: -75, dy: 0)))
        XCTAssertNotEqual(end.value as? String, originalEnd)
        let endPreview = app.staticTexts["trimPreviewTime"].label
        XCTAssertNotEqual(endPreview, "0:00.0")
        XCTAssertFalse(app.descendants(matching: .any)["editorErrorMessage"].exists)
        let originalStart = start.value as? String
        let startPoint = start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        startPoint.press(forDuration: 0.1, thenDragTo: startPoint.withOffset(CGVector(dx: 50, dy: 0)))
        XCTAssertNotEqual(start.value as? String, originalStart)
        XCTAssertNotEqual(app.staticTexts["trimPreviewTime"].label, endPreview)
        let save = app.buttons["saveEditedVideoButton"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.descendants(matching: .any)["editorErrorMessage"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Live thumbnail trim after moving both handles"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testStudioIsReachableWithoutCameraSetup() throws {
        let app = XCUIApplication()
        app.launch()
        let imported = try openSyntheticStudio(in: app)
        XCTAssertTrue(app.buttons["recordTakeButton"].waitForExistence(timeout: 8))
        for style in ["circle", "square", "cutout", "rounded"] {
            XCTAssertFalse(app.buttons["pipStyle_\(style)"].exists)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Small camera studio and native controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.buttons["addMyCameraButton"].exists)
        XCTAssertTrue(app.buttons["enableCameraButton"].exists)
        XCTAssertTrue(app.buttons["recordingDelayMenu"].exists)
        XCTAssertLessThanOrEqual(app.buttons["recordTakeButton"].frame.width, 70)
        XCTAssertLessThanOrEqual(app.buttons["closeStudioButton"].frame.height, 48)
        XCTAssertTrue(app.buttons["studioLayoutMenu"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["studioErrorMessage"].exists)
        app.buttons["closeStudioButton"].tap()
        XCTAssertTrue(imported.waitForExistence(timeout: 5))
    }

    @MainActor func testLayoutsCanBeChosenBeforeRecordingWithoutTurningOnCamera() throws {
        let app = XCUIApplication()
        app.launch()
        _ = try openSyntheticStudio(in: app)
        let menu = app.buttons["studioLayoutMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        for layout in ["Split", "You on Stage", "Small camera"] {
            menu.tap()
            app.buttons[layout].tap()
            XCTAssertEqual(menu.value as? String, layout)
            XCTAssertTrue(app.buttons["addMyCameraButton"].exists)
            XCTAssertFalse(app.buttons["pipStyle_cutout"].exists)
        }
    }

    @MainActor private func openSyntheticStudio(in app: XCUIApplication) throws -> XCUIElement {
        let imported = app.buttons["recentImported-61732B21-8BE5-4B17-B58F-C232FD423526"]
        guard imported.waitForExistence(timeout: 8) else {
            throw XCTSkip("Seed the synthetic Studio clip in ImportedVideos to check Studio navigation.")
        }
        if !imported.isHittable { app.scrollViews.firstMatch.swipeUp() }
        imported.tap()
        return imported
    }

    @MainActor func testRecordingDelayCanBeTurnedOffAndPersists() throws {
        let app = XCUIApplication()
        app.launch()
        let example = app.buttons["tryStudioButton"]
        XCTAssertTrue(example.waitForExistence(timeout: 8))
        if !example.isHittable { app.scrollViews.firstMatch.swipeUp() }
        example.tap()
        let delay = app.buttons["recordingDelayMenu"]
        XCTAssertTrue(delay.waitForExistence(timeout: 5))
        delay.tap()
        app.buttons["Off"].tap()
        XCTAssertEqual(delay.value as? String, "Off")
        app.terminate()
        app.launch()
        let reopenedExample = app.buttons["tryStudioButton"]
        XCTAssertTrue(reopenedExample.waitForExistence(timeout: 8))
        if !reopenedExample.isHittable { app.scrollViews.firstMatch.swipeUp() }
        reopenedExample.tap()
        let restoredDelay = app.buttons["recordingDelayMenu"]
        XCTAssertTrue(restoredDelay.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredDelay.value as? String, "Off")
        restoredDelay.tap()
        app.buttons["3 seconds"].tap()
        XCTAssertEqual(restoredDelay.value as? String, "3 seconds")
    }

    @MainActor func testInvalidLinkShowsErrorAndPreservesInput() throws {
        let app = XCUIApplication()
        app.launch()
        let input = app.textFields["videoLinkField"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText("https://example.com/video")
        homeLinkAction(in: app).tap()
        XCTAssertEqual(input.value as? String, "https://example.com/video")
        XCTAssertTrue(app.staticTexts["Paste an Instagram, YouTube, TikTok, or X video link."].exists)
    }

    @MainActor func testPublicLinkImportsToStudioWhenServiceIsRunning() async throws {
        try await assertPublicLinkImportsToStudio(ProcessInfo.processInfo.environment["ROAST_TEST_VIDEO_URL"]
            ?? "https://www.instagram.com/reel/DfR0-RNR-Y8/")
    }

    @MainActor func testYouTubeLinkImportsToStudioWhenServiceIsRunning() async throws {
        try await assertPublicLinkImportsToStudio("https://www.youtube.com/watch?v=jNQXAC9IVRw")
    }

    @MainActor func testOriginalYouTubeLinkImportsToStudioWhenServiceIsRunning() async throws {
        try await assertPublicLinkImportsToStudio("https://youtu.be/bkPwFqa89gE")
    }

    @MainActor func testPublicImportSurvivesBackgroundAndRemainsAvailableAfterRelaunch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let service = environment["ROAST_TEST_MEDIA_SERVICE_URL"] ?? "https://api.recordpov.app"
        let source = environment["ROAST_TEST_BACKGROUND_VIDEO_URL"] ?? "https://www.instagram.com/reel/DfR0-RNR-Y8/"
        guard let health = URL(string: "\(service)/health"),
              let (_, response) = try? await URLSession.shared.data(from: health),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("The configured media service is unavailable for the background import check.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-resolverAddress", service]
        app.launch()
        let input = app.textFields["videoLinkField"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap(); input.typeText(source)
        let download = homeLinkAction(in: app)
        download.tap()
        XCTAssertTrue(app.progressIndicators["Video download"].waitForExistence(timeout: 180),
                      "The background check requires an active byte transfer, not only link lookup. Use a longer public fixture if necessary.")
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(8))
        XCTAssertNotEqual(app.state, .runningForeground)
        app.activate()
        // "Download & open video" opens Studio by itself after returning to the app.
        let playback = app.buttons["sourcePlaybackButton"]
        XCTAssertTrue(playback.waitForExistence(timeout: 240))
        XCTAssertTrue(app.buttons["addMyCameraButton"].exists, "Completing an import must not enable the camera.")
        XCTAssertFalse(playback.label.localizedCaseInsensitiveContains("pause"), "The imported video should remain paused until requested.")
        app.buttons["closeStudioButton"].tap()
        app.tabBars.buttons["My videos"].tap()
        let importedShelf = app.buttons["Imported videos"]
        XCTAssertTrue(importedShelf.waitForExistence(timeout: 8))
        importedShelf.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recentImported-"))
        let row = rows.firstMatch
        for _ in 0..<8 where !row.exists { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<8 where !row.isHittable { app.scrollViews.firstMatch.swipeUp() }
        let identifier = row.identifier
        row.tap()
        XCTAssertTrue(playback.waitForExistence(timeout: 20))
        app.buttons["closeStudioButton"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["My videos"].tap()
        let restoredShelf = app.buttons["Imported videos"]
        XCTAssertTrue(restoredShelf.waitForExistence(timeout: 8))
        restoredShelf.tap()
        let restored = app.buttons[identifier]
        for _ in 0..<8 where !restored.exists { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(restored.waitForExistence(timeout: 8), "Closing the app must not discard the imported video.")
        for _ in 0..<8 where !restored.isHittable { app.scrollViews.firstMatch.swipeUp() }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Imported videos restored after relaunch"; proof.lifetime = .keepAlways; add(proof)
        restored.tap()
        XCTAssertTrue(playback.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["addMyCameraButton"].exists)
        app.buttons["closeStudioButton"].tap()
    }

    @MainActor private func assertPublicLinkImportsToStudio(_ source: String) async throws {
        let service = ProcessInfo.processInfo.environment["ROAST_TEST_MEDIA_SERVICE_URL"] ?? "https://api.recordpov.app"
        let health = URL(string: "\(service)/health")!
        guard let (_, response) = try? await URLSession.shared.data(from: health),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("The configured media service is unavailable for the public-link integration check.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-resolverAddress", service]
        app.launch()
        let input = app.textFields["videoLinkField"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText(source)
        homeLinkAction(in: app).tap()
        XCTAssertTrue(app.buttons["sourcePlaybackButton"].waitForExistence(timeout: source.contains("bkPwFqa89gE") ? 650 : 930))
        XCTAssertTrue(app.buttons["recordTakeButton"].exists)
        XCTAssertTrue(app.staticTexts["Video ready. Play or pause it while you record."].waitForExistence(timeout: 20))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Imported video in native studio"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["closeStudioButton"].tap()
    }

    @MainActor func testCreateSeparatesAddingMediaFromRecentThumbnails() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-resolverAddress", "https://offline.invalid"]
        app.launch()
        XCTAssertTrue(app.textFields["videoLinkField"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["openStudioButton"].label.contains("Download & open video"))
        XCTAssertTrue(app.buttons["importMediaButton"].label.contains("Upload video or photo"))
        XCTAssertFalse(app.buttons["downloadNewVideoButton"].exists)
        XCTAssertFalse(app.staticTexts["Video ready"].exists)
        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 5))
        let imported = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recentImported-")).firstMatch
        for _ in 0..<6 where !imported.exists || !imported.isHittable {
            if app.scrollViews.count > 1 { app.scrollViews.element(boundBy: 1).swipeLeft() }
        }
        XCTAssertTrue(imported.waitForExistence(timeout: 5), "Use the existing imported video fixture for the local recent-card check.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Create with link upload and Recent thumbnails"
        screenshot.lifetime = .keepAlways; add(screenshot)
        imported.tap()
        XCTAssertTrue(app.buttons["sourcePlaybackButton"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["addMyCameraButton"].exists)
        app.buttons["closeStudioButton"].tap()
    }

    @MainActor private func homeLinkAction(in app: XCUIApplication) -> XCUIElement {
        let newVideo = app.buttons["downloadNewVideoButton"]
        if newVideo.waitForExistence(timeout: 1) { return newVideo }
        return app.buttons["openStudioButton"]
    }

    @MainActor private func replaceLink(in field: XCUIElement, with value: String) {
        field.tap()
        // A tap can place the caret in the middle of a long URL. Select all
        // with the SDK's supported iOS hardware-key API before replacement.
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        XCTAssertEqual(field.value as? String, value, "Enter the intended fixture link before checking the app's actions.")
    }
}
