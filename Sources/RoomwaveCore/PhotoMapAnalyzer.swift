import Foundation

/// A local, deterministic height field inferred from pixels, in arbitrary game units.
/// Brightness and visual features are styling cues, never measured depth or room bounds.
public enum PhotoMapAnalyzer {
    public static func makeSample(luminance: [UInt8], width: Int, height: Int,
                                  saliency: [Float]? = nil) throws -> ScanSample {
        // Check dimensions before multiplication, including adversarial Int values.
        guard (8...128).contains(width), (8...128).contains(height) else {
            throw RoomwaveError.invalidScan("Photo analysis requires dimensions of 8...128 pixels")
        }
        let count = width * height
        guard luminance.count == count else {
            throw RoomwaveError.invalidScan("Photo luminance count must equal width times height")
        }
        if let saliency {
            guard saliency.count == count,
                  saliency.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
                throw RoomwaveError.invalidScan("Photo saliency must match the pixels and contain finite values in 0...1")
            }
        }

        let values = luminance.map { Double($0) / 255 }
        let low = values.min()!, high = values.max()!
        let mean = values.reduce(0, +) / Double(count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        guard high - low >= 12.0 / 255, variance >= pow(3.0 / 255, 2) else {
            throw RoomwaveError.invalidScan("Photo is featureless or too low contrast; choose a picture with stronger visible structure")
        }

        let tones = values.map { ($0 - low) / (high - low) }
        func tone(_ x: Int, _ y: Int) -> Double {
            tones[min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))]
        }
        var gradientsX = [Double](repeating: 0, count: count)
        var gradientsZ = gradientsX
        var edges = gradientsX
        var contrasts = gradientsX
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                // Normalized Sobel derivatives; clamped sampling at image boundaries.
                let gx = (tone(x + 1, y - 1) + 2 * tone(x + 1, y) + tone(x + 1, y + 1)
                          - tone(x - 1, y - 1) - 2 * tone(x - 1, y) - tone(x - 1, y + 1)) / 4
                let gz = (tone(x - 1, y + 1) + 2 * tone(x, y + 1) + tone(x + 1, y + 1)
                          - tone(x - 1, y - 1) - 2 * tone(x, y - 1) - tone(x + 1, y - 1)) / 4
                var neighborhood = 0.0
                for dy in -1...1 {
                    for dx in -1...1 { neighborhood += tone(x + dx, y + dy) }
                }
                gradientsX[index] = gx
                gradientsZ[index] = gz
                edges[index] = min(1, sqrt(gx * gx + gz * gz))
                contrasts[index] = abs(tones[index] - neighborhood / 9)
            }
        }

        // One representative per cell, at most 64 x 64. Aggregate every input pixel
        // rather than stride-sampling (which can erase narrow edges/checkerboards).
        let columns = min(64, width), rows = min(64, height)
        let longestSide = Double(max(width, height))
        var points: [Vector3] = []
        points.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y0 = row * height / rows, y1 = (row + 1) * height / rows
            for column in 0..<columns {
                let x0 = column * width / columns, x1 = (column + 1) * width / columns
                var weightSum = 0.0, px = 0.0, pz = 0.0, elevation = 0.0
                var gxSum = 0.0, gzSum = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * width + x
                        let attention = saliency.map { Double($0[i]) } ?? 0
                        let weight = 0.1 + contrasts[i] * 0.5 + edges[i] + attention
                        weightSum += weight
                        px += (Double(x) + 0.5) * weight
                        pz += (Double(y) + 0.5) * weight
                        gxSum += gradientsX[i] * weight
                        gzSum += gradientsZ[i] * weight
                        elevation += (0.55 * tones[i] + 0.45 * edges[i]
                                      + 0.2 * contrasts[i] + 0.4 * attention) * weight
                    }
                }
                // Features move representatives inside their own cell as well as
                // raising relief. No random seed, file name or capture metadata.
                let cx = px / weightSum + 0.2 * Double(x1 - x0) * gxSum / weightSum
                let cz = pz / weightSum + 0.2 * Double(y1 - y0) * gzSum / weightSum
                points.append(Vector3(
                    x: quantize((cx - Double(width) / 2) * 2 / longestSide),
                    y: quantize(elevation / weightSum),
                    z: quantize((cz - Double(height) / 2) * 2 / longestSide)
                ))
            }
        }
        // Stable local label, not a unique capture identity or a photo fingerprint.
        // Normalization drops this field; export must contain finalized track only.
        return ScanSample(captureID: "photo-derived-local-v1", source: .photoDerived, points: points)
    }

    private static func quantize(_ value: Double) -> Double {
        let rounded = (value * 1000).rounded(.toNearestOrAwayFromZero) / 1000
        return rounded == 0 ? 0 : rounded
    }
}
