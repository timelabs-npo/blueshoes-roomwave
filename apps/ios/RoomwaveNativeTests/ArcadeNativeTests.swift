import XCTest
import RealityKit
import RoomwaveArcade
@testable import Roomwave

final class ArcadeNativeTests: XCTestCase {
    @MainActor
    func testChallengeParsingDoesNotLoadUntrustedOrMalformedRoutes() {
        let session = ArcadeSession()
        for raw in [
            "https://example.com/challenge?course=low-orbit&rules=3",
            "roomwave://challenge?course=unknown&rules=3",
            "roomwave://challenge?course=neon-dawn&rules=3&rules=2",
            "roomwave://challenge/path?course=neon-dawn&rules=3",
            "roomwave://user@challenge?course=neon-dawn&rules=3"
        ] {
            session.handle(url: URL(string: raw)!)
            XCTAssertEqual(session.selectedID, "neon-dawn")
            XCTAssertNil(session.course)
            XCTAssertNotNil(session.statusMessage)
        }
    }

    @MainActor
    func testShareCardUsesActualFactsAndAnEditableXIntent() throws {
        let result = SurfRunResult(courseID: "neon-dawn", rulesVersion: SurfRules.standard.version,
            score: 1234, seconds: 70, rings: 8, perfectLandings: 4, bestCombo: 9, completed: true, medal: .silver)
        let share = try ArcadeSharing.make(result: result, title: "NEON DAWN")
        XCTAssertEqual(share.image.size.width, 540)
        XCTAssertTrue(share.text.contains("8 rings"))
        let url = try XCTUnwrap(share.challenge)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "roomwave")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "course" })?.value, "neon-dawn")
        let intent = try XCTUnwrap(ArcadeSharing.xComposer(result: result))
        XCTAssertEqual(intent.host, "x.com")
        XCTAssertEqual(intent.path, "/intent/tweet")
        let items = try XCTUnwrap(URLComponents(url: intent, resolvingAgainstBaseURL: false)?.queryItems)
        let message = try XCTUnwrap(items.first(where: { $0.name == "text" })?.value)
        XCTAssertTrue(message.contains("1234"))
        XCTAssertTrue(message.contains(result.courseID))
        XCTAssertTrue(message.contains(result.rulesVersion))
        XCTAssertTrue(message.contains("Reply with your score"))
        XCTAssertEqual(items.first(where: { $0.name == "url" })?.value,
                       "https://github.com/timelabs-npo/blueshoes-roomwave")
    }

    @MainActor
    func testCreatedCourseCardDoesNotInventASharedRoute() throws {
        let result = SurfRunResult(courseID: "photo-abcd", rulesVersion: SurfRules.standard.version,
            score: 40, seconds: 20, rings: 1, perfectLandings: 0, bestCombo: 1, completed: false, medal: .none)
        let share = try ArcadeSharing.make(result: result, title: "PHOTO CURRENT")
        XCTAssertNil(share.challenge)
        XCTAssertTrue(share.text.contains("no shared challenge link"))
        let intent = try XCTUnwrap(ArcadeSharing.xComposer(result: result))
        let message = try XCTUnwrap(URLComponents(url: intent, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "text" })?.value)
        XCTAssertTrue(message.contains("not a replay link"))
        XCTAssertFalse(message.contains(result.courseID))
    }
}
