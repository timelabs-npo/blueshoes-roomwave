import Foundation
import Testing
@testable import RoomwaveCore

private func photoPixels(width: Int = 32, height: Int = 32,
                         _ pixel: (Int, Int) -> UInt8) -> [UInt8] {
    var values: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width { values.append(pixel(x, y)) }
    }
    return values
}

@Test func photoRejectsInvalidDimensionsBeforeMultiplication() {
    for invalid in [Int.min, -1, 0, 7, 129, Int.max] {
        #expect(throws: RoomwaveError.self) {
            try PhotoMapAnalyzer.makeSample(luminance: [], width: invalid, height: 8)
        }
        #expect(throws: RoomwaveError.self) {
            try PhotoMapAnalyzer.makeSample(luminance: [], width: 8, height: invalid)
        }
    }
    for count in [0, 63, 65, 16_385] {
        #expect(throws: RoomwaveError.self) {
            try PhotoMapAnalyzer.makeSample(luminance: Array(repeating: 128, count: count), width: 8, height: 8)
        }
    }
}

@Test func photoRejectsInvalidSaliencyValuesAndLengths() {
    let pixels = photoPixels(width: 8, height: 8) { x, _ in x < 4 ? 24 : 232 }
    for count in [0, 63, 65] {
        #expect(throws: RoomwaveError.self) {
            try PhotoMapAnalyzer.makeSample(luminance: pixels, width: 8, height: 8,
                                            saliency: Array(repeating: 0.5, count: count))
        }
    }
    for bad in [Float.nan, .infinity, -.infinity, -0.001, 1.001] {
        var saliency = [Float](repeating: 0.5, count: 64)
        saliency[27] = bad
        #expect(throws: RoomwaveError.self) {
            try PhotoMapAnalyzer.makeSample(luminance: pixels, width: 8, height: 8, saliency: saliency)
        }
    }
}

@Test func photoFeaturelessAndLowContrastImagesHaveExplicitErrors() {
    let expected = RoomwaveError.invalidScan(
        "Photo is featureless or too low contrast; choose a picture with stronger visible structure"
    )
    for level in [UInt8(0), 128, 255] {
        #expect(throws: expected) {
            try PhotoMapAnalyzer.makeSample(luminance: Array(repeating: level, count: 1024), width: 32, height: 32)
        }
    }
    let nearlyFlat = photoPixels { x, _ in x % 2 == 0 ? 128 : 129 }
    #expect(throws: expected) {
        try PhotoMapAnalyzer.makeSample(luminance: nearlyFlat, width: 32, height: 32)
    }
    // Saliency cannot substitute for missing image structure.
    #expect(throws: expected) {
        try PhotoMapAnalyzer.makeSample(luminance: Array(repeating: 100, count: 1024), width: 32, height: 32,
                                        saliency: (0..<1024).map { Float($0 % 32) / 31 })
    }
    // An isolated hot pixel in an otherwise flat maximum-size image is insufficient.
    var hotPixel = [UInt8](repeating: 0, count: 128 * 128)
    hotPixel[1234] = 255
    #expect(throws: expected) {
        try PhotoMapAnalyzer.makeSample(luminance: hotPixel, width: 128, height: 128)
    }
}

@Test func photoSamePixelsAndAttentionProduceExactlyTheSameSample() throws {
    let pixels = photoPixels { x, y in UInt8((x * 5 + y * 3) % 256) }
    let saliency = (0..<1024).map { Float($0 % 32) / 31 }
    let first = try PhotoMapAnalyzer.makeSample(luminance: pixels, width: 32, height: 32, saliency: saliency)
    let second = try PhotoMapAnalyzer.makeSample(luminance: pixels, width: 32, height: 32, saliency: saliency)
    #expect(first == second)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(first) == encoder.encode(second))
    #expect(first.source == .photoDerived)
    #expect(!first.points.isEmpty)
}

@Test func photoStructuredPicturesWithEqualHistogramsProduceDistinctReliefAndLayout() throws {
    // Same dimensions, bounds and brightness histogram, different actual content.
    let vertical = photoPixels { x, _ in x < 16 ? 24 : 232 }
    let horizontal = photoPixels { _, y in y < 16 ? 24 : 232 }
    #expect(vertical.sorted() == horizontal.sorted())
    let a = try PhotoMapAnalyzer.makeSample(luminance: vertical, width: 32, height: 32)
    let b = try PhotoMapAnalyzer.makeSample(luminance: horizontal, width: 32, height: 32)
    #expect(a.points.count == b.points.count)
    let meanHeightDifference = zip(a.points, b.points).reduce(0.0) { $0 + abs($1.0.y - $1.1.y) }
        / Double(a.points.count)
    #expect(meanHeightDifference > 0.2) // Material spatial difference, not just inequality.
    #expect(zip(a.points, b.points).contains { $0.0.x != $0.1.x || $0.0.z != $0.1.z })
    #expect(try ScanNormalizer.normalize(a).points != ScanNormalizer.normalize(b).points)
}

@Test func photoEdgesAffectReliefEvenWhenCellAverageBrightnessMatches() throws {
    // Each 2x2 output cell has the same mean brightness in both pictures.
    // Feature extraction before aggregation must retain their different edges.
    let fine = photoPixels(width: 128, height: 128) { x, y in (x + y) % 2 == 0 ? 0 : 255 }
    let stripes = photoPixels(width: 128, height: 128) { x, _ in x % 2 == 0 ? 0 : 255 }
    let a = try PhotoMapAnalyzer.makeSample(luminance: fine, width: 128, height: 128)
    let b = try PhotoMapAnalyzer.makeSample(luminance: stripes, width: 128, height: 128)
    let difference = zip(a.points, b.points).reduce(0.0) { $0 + abs($1.0.y - $1.1.y) } / Double(a.points.count)
    #expect(difference > 0.02)
}

@Test func photoOptionalAttentionMateriallyChangesGeometryAndFallbackIsDeterministic() throws {
    let pixels = photoPixels(width: 128, height: 128) { x, _ in x < 64 ? 24 : 232 }
    let zero = [Float](repeating: 0, count: pixels.count)
    let attention = (0..<pixels.count).map { Float($0 % 2) }
    let fallback = try PhotoMapAnalyzer.makeSample(luminance: pixels, width: 128, height: 128)
    #expect(fallback == (try PhotoMapAnalyzer.makeSample(luminance: pixels, width: 128, height: 128, saliency: zero)))
    let emphasized = try PhotoMapAnalyzer.makeSample(luminance: pixels, width: 128, height: 128, saliency: attention)
    let difference = zip(fallback.points, emphasized.points).reduce(0.0) { $0 + abs($1.0.y - $1.1.y) }
        / Double(fallback.points.count)
    #expect(difference > 0.25)
    #expect(zip(fallback.points, emphasized.points).contains { $0.0.x != $0.1.x })
}

@Test func photoBoundsProvenanceAndNormalizationAtAllDimensionLimits() throws {
    for (width, height) in [(8, 8), (8, 128), (128, 8), (128, 128), (63, 77)] {
        let pixels = photoPixels(width: width, height: height) { x, y in (x + y) % 3 == 0 ? 0 : 255 }
        let sample = try PhotoMapAnalyzer.makeSample(luminance: pixels, width: width, height: height,
                                                    saliency: Array(repeating: 1, count: pixels.count))
        #expect(sample.source == .photoDerived)
        #expect(sample.points.count == min(width, 64) * min(height, 64))
        #expect(sample.points.count <= 4096)
        #expect(sample.points.allSatisfy { p in
            p.x.isFinite && p.y.isFinite && p.z.isFinite
                && abs(p.x) <= 1 && abs(p.z) <= 1 && p.y >= 0 && p.y <= 1.6
        })
        let normalized = try ScanNormalizer.normalize(sample)
        #expect(normalized.source == .photoDerived)
        let encoded = String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self)
        #expect(!encoded.contains("captureID"))
        #expect(!encoded.contains("photo-derived-local-v1"))
    }
}
