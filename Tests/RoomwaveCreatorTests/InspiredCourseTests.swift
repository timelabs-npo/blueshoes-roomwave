import XCTest
import RoomwaveCore
import RoomwaveArcade
@testable import RoomwaveCreator

final class InspiredCourseTests: XCTestCase {
    private func photo(vertical: Bool, capture: String = "private-local-label") throws -> ScanSample {
        let pixels: [UInt8] = (0..<64 * 64).map { index in
            let x = index % 64, y = index / 64
            return (vertical ? x < 24 : y < 24) ? 25 : 220
        }
        let analyzed = try PhotoMapAnalyzer.makeSample(luminance: pixels, width: 64, height: 64)
        return ScanSample(captureID: capture, source: .photoDerived, points: analyzed.points)
    }

    func testActualPhotoFeaturesChangeGeometryWithoutMovingEncounterSequence() throws {
        let a = try InspiredCourseFactory.make(from: photo(vertical: true))
        let b = try InspiredCourseFactory.make(from: photo(vertical: false))
        XCTAssertEqual(a.definition.source, .photoInspired)
        XCTAssertNotEqual(a.definition.samples, b.definition.samples)
        XCTAssertNotEqual(a.definition.id, b.definition.id)
        XCTAssertEqual(a.definition.encounters, b.definition.encounters)
        XCTAssertEqual(a.length, b.length)
        XCTAssertEqual(a.definition.samples.first?.center, b.definition.samples.first?.center)
    }

    func testCaptureIdentifierCannotChangeOrLeakIntoCourse() throws {
        let a = try InspiredCourseFactory.make(from: photo(vertical: true, capture: "very-private-one"))
        let b = try InspiredCourseFactory.make(from: photo(vertical: true, capture: "different-private-two"))
        XCTAssertEqual(a.definition, b.definition)
        let json = String(decoding: try JSONEncoder().encode(a.definition), as: UTF8.self)
        XCTAssertFalse(json.contains("private"))
        XCTAssertFalse(json.contains("captureID"))
    }

    func testMeshProvenanceSurvivesAndSyntheticInputIsRejected() throws {
        let input = try photo(vertical: false)
        let mesh = ScanSample(captureID: "mesh-session", source: .arkitMesh, points: input.points)
        XCTAssertEqual(try InspiredCourseFactory.make(from: mesh).definition.source, .lidarInspired)
        let synthetic = ScanSample(captureID: "demo", source: .synthetic, points: input.points)
        XCTAssertThrowsError(try InspiredCourseFactory.make(from: synthetic))
        XCTAssertThrowsError(try InspiredCourseFactory.make(from:
            ScanSample(captureID: "bad", source: .photoDerived,
                       points: [Vector3(x: .nan, y: 0, z: 0)])))
    }
}
