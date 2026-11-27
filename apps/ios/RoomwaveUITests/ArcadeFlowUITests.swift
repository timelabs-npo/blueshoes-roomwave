import XCTest

/// Automated real touch flow. These tests establish input/transition/render
/// behavior, not enjoyment, physical-device frame pacing or human retention.
final class ArcadeFlowUITests: XCTestCase {
    @MainActor
    func testRealTouchRunPauseBackgroundResultRetryAndCourses() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--arcade-evidence"]
        app.launch()
        let play = app.buttons["arcade.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 60), "The game must reach its ordinary Play action")
        waitForEnabled(play)
        Thread.sleep(forTimeInterval: 2)
        attach(app, "01-home-neon-dawn")

        let next = app.buttons["arcade.next-course"]
        next.tap()
        waitForEnabled(play)
        Thread.sleep(forTimeInterval: 2)
        attach(app, "02-home-low-orbit")
        next.tap()
        waitForEnabled(play)
        Thread.sleep(forTimeInterval: 2)
        attach(app, "03-home-black-current")
        next.tap()
        waitForEnabled(play)
        XCTAssertTrue(app.staticTexts["AFTERGLOW CISTERN"].waitForExistence(timeout: 5))
        attach(app, "03b-home-afterglow-cistern")

        XCTAssertTrue(play.waitForExistence(timeout: 5), "The run must be available before any optional setup")
        play.tap()
        XCTAssertTrue(app.buttons["arcade.pause"].waitForExistence(timeout: 10))
        let touch = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.64))
        // Same touch surface and physics as ordinary gameplay. No injected bot.
        touch.press(forDuration: 0.8)
        Thread.sleep(forTimeInterval: 0.35)
        attach(app, "04-release-and-air")
        touch.press(forDuration: 0.35)
        Thread.sleep(forTimeInterval: 1.2)
        attach(app, "05-landing")

        app.buttons["arcade.pause"].tap()
        let resume = app.buttons["arcade.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        attach(app, "06-paused")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Foreground must not silently resume")
        resume.tap()
        for _ in 0..<3 {
            guard app.buttons["arcade.pause"].exists else { break }
            touch.press(forDuration: 0.6)
            Thread.sleep(forTimeInterval: 0.8)
        }
        // Idle is deliberately a different, normally poor input trace. It must
        // still reach the real crash/finish result rather than an endless state.
        let retry = app.buttons["arcade.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 165), "A real run must end with a result")
        // The native evidence probe takes its own asynchronous RealityKit frame.
        // Leave this genuine result visible through its bounded retry window.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(app.staticTexts["arcade.run-credits"].exists,
                      "A completed or failed run must expose credits without a modal")
        XCTAssertTrue(app.buttons["arcade.share-x"].exists,
                      "A real result must offer an editable X draft without publishing")
        attach(app, "07-result")
        retry.tap()
        XCTAssertTrue(app.buttons["arcade.pause"].waitForExistence(timeout: 5))
        touch.press(forDuration: 0.7)
        Thread.sleep(forTimeInterval: 0.4)
        attach(app, "08-immediate-retry")
        app.buttons["arcade.pause"].tap()
        app.buttons["arcade.home"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))

        // Capture the essential run before opening optional sheets. Keep their real-touch checks.
        let character = app.buttons["arcade.crews"]
        character.tap()
        let basalt = app.buttons["arcade.role.basalt-guard"]
        XCTAssertTrue(basalt.waitForExistence(timeout: 5))
        basalt.tap()
        XCTAssertTrue(app.staticTexts["arcade.role-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["arcade.role-title"].label, "Basalt Guard")
        app.buttons["Done"].tap()
        XCTAssertEqual(character.value as? String, "Basalt Guard")
        character.tap()
        XCTAssertTrue(basalt.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["arcade.role-title"].label, "Basalt Guard")
        app.buttons["arcade.role.dune-runners"].tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(character.value as? String, "Dune Runners")

        let settings = app.buttons["arcade.settings"]
        settings.tap()
        app.buttons["arcade.creator"].tap()
        XCTAssertTrue(app.buttons["creator.photo"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["creator.photo"].waitForNonExistence(timeout: 15))
        waitForEnabled(settings)
        settings.tap()
        app.buttons["arcade.x-currents"].tap()
        XCTAssertTrue(app.segmentedControls["x.source"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["x.ride"].exists, "No activity course may be invented before a real read")
        if app.staticTexts["x.unavailable"].exists {
            XCTAssertFalse(app.buttons["x.connect"].isEnabled, "Missing X registration must not start pretend authentication")
        }
        app.buttons["Done"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Optional X setup must not block the ordinary game")
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 60), .completed)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
