import XCTest
import UIKit
import AVFoundation
import RealityKit
import RoomwaveArcade
@testable import Roomwave

final class ArcadeNativeTests: XCTestCase {
    @MainActor
    func testLivingDunesUseBiomeAndRespectReduceMotion() throws {
        for (route, insect, wings) in [("neon-dawn", "DuneButterfly", 2), ("prism-break", "TerraceFirefly", 0)] {
            let definition = try XCTUnwrap(SurfCatalog.featured.first { $0.id == route })
            let course = try SurfCourseCompiler.compile(definition)
            let art = try ArcadeGeometry.build(course: course)
            XCTAssertNotNil(art.root.findEntity(named: "Terrace Grass 0"))
            XCTAssertNotNil(art.root.findEntity(named: "Terrace Wildflowers 2"))
            XCTAssertLessThanOrEqual(art.pollinators.count, 18)
            let creature = try XCTUnwrap(art.pollinators.first)
            XCTAssertEqual(creature.root.name, insect)
            XCTAssertEqual(creature.wings.count, wings)
            creature.update(distance: creature.distance, time: 1, reducedMotion: false)
            XCTAssertTrue(creature.root.isEnabled)
            let moving = creature.root.position
            creature.update(distance: creature.distance, time: 3, reducedMotion: false)
            XCTAssertNotEqual(creature.root.position, moving)
            creature.update(distance: creature.distance, time: 12, reducedMotion: true)
            XCTAssertEqual(creature.root.position, creature.origin)
            let still = creature.root.transform
            creature.update(distance: creature.distance, time: 70, reducedMotion: true)
            XCTAssertEqual(creature.root.transform.translation, still.translation)
            XCTAssertEqual(creature.root.transform.scale, still.scale)
            creature.update(distance: creature.distance + 40, time: 1, reducedMotion: false)
            XCTAssertFalse(creature.root.isEnabled)
        }
        let orbital = try XCTUnwrap(SurfCatalog.featured.first { $0.id == "low-orbit" })
        let art = try ArcadeGeometry.build(course: SurfCourseCompiler.compile(orbital))
        XCTAssertTrue(art.pollinators.isEmpty)
        XCTAssertNil(art.root.findEntity(named: "Terrace Grass 0"))
    }


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
    func testRadioRotationIsBundledAndDecodes() throws {
        XCTAssertEqual(ArcadeRadioTrack.rotation.count, 2)
        for track in ArcadeRadioTrack.rotation {
            let url = try XCTUnwrap(track.url)
            XCTAssertTrue(url.isFileURL)
            let player = try AVAudioPlayer(contentsOf: url)
            XCTAssertGreaterThan(player.duration, 85)
            XCTAssertEqual(track.source.host, "opengameart.org")
        }
    }

    @MainActor
    func testMITGlyphsAreBundled() {
        XCTAssertNotNil(UIImage(named: "xsurf-character-glyph"))
        XCTAssertNotNil(UIImage(named: "xsurf-share-glyph"))
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
        XCTAssertTrue(message.contains("xsurf"))
        XCTAssertTrue(message.contains("in the beta"))
        XCTAssertEqual(items.map(\.name), ["text"])
        XCTAssertEqual(message, ArcadeSharing.xDraft(result: result))
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
        XCTAssertFalse(message.contains("PHOTO CURRENT"))
        XCTAssertFalse(message.contains("http"))
    }
}
