import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import RoomwaveCore
import Vision

/// Imports a still photo in memory. No file writes, uploads, metadata export or
/// metric reconstruction. The coordinator supplies PhotosPicker/UI integration.
@MainActor
enum PhotoMapImporter {
    static func sample(from data: Data) async throws -> ScanSample {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else {
            throw RoomwaveError.invalidScan("Choose a nonempty still photo no larger than 20 MiB")
        }
        try Task.checkCancellation()
        // Data and ScanSample are Sendable. ImageIO, CG objects, pixel pointers and
        // Vision requests stay inside this worker; no UIKit object crosses actors.
        let worker = Task.detached(priority: .userInitiated) {
            try decodeAndAnalyze(data)
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: {
            worker.cancel()
        })
    }

    private nonisolated static func decodeAndAnalyze(_ data: Data) throws -> ScanSample {
        try autoreleasepool {
            try Task.checkCancellation()
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw RoomwaveError.invalidScan("Photo could not be read as one complete still image")
            }
            let w = widthNumber.doubleValue, h = heightNumber.doubleValue
            guard w.isFinite, h.isFinite, w >= 8, h >= 8, w <= 16_384, h <= 16_384,
                  w.rounded(.towardZero) == w, h.rounded(.towardZero) == h,
                  w * h <= 50_000_000 else {
                throw RoomwaveError.invalidScan("Photo dimensions must be at least 8 pixels, at most 16,384 per side and 50 megapixels total")
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false
            ] as CFDictionary
            // ImageIO applies all EXIF/UIImage orientation variants, including
            // mirrored ones, before analysis. Avoid UIImage(data:) full-size decode.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  (8...128).contains(image.width), (8...128).contains(image.height) else {
                throw RoomwaveError.invalidScan("Photo could not be decoded to an upright 8...128 pixel image; choose a less extreme aspect ratio")
            }
            try Task.checkCancellation()
            let luminance = try luminancePixels(from: image)
            let saliency = attentionSaliency(from: image)
            try Task.checkCancellation()
            return try PhotoMapAnalyzer.makeSample(luminance: luminance, width: image.width,
                                                   height: image.height, saliency: saliency)
        }
    }

    private nonisolated static func luminancePixels(from image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        // Explicit sRGB RGBA8 removes source color-space/bit-depth variation.
        // Composite transparency over white; invisible RGB cannot create features.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                              | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            context.fill(rect)
            context.draw(image, in: rect)
            return true
        }
        guard rendered else { throw RoomwaveError.invalidScan("Photo pixel conversion failed") }
        return (0..<(width * height)).map { index in
            let i = index * 4
            // Rec.709 luma of display-encoded sRGB, a styling cue, not radiometry.
            return UInt8((2126 * Int(rgba[i]) + 7152 * Int(rgba[i + 1])
                          + 722 * Int(rgba[i + 2]) + 5000) / 10000)
        }
    }

    private nonisolated static func attentionSaliency(from image: CGImage) -> [Float]? {
        // Optional on-device enhancement. Unsupported formats, Vision errors or
        // invalid observations fall back to contrast/Sobel features of real pixels.
        do {
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
            guard let buffer = request.results?.first?.pixelBuffer,
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            guard (1...1024).contains(width), (1...1024).contains(height),
                  stride >= width * MemoryLayout<Float>.size,
                  let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            var values: [Float] = []
            values.reserveCapacity(image.width * image.height)
            for y in 0..<image.height {
                let sy = min(height - 1, y * height / image.height)
                let row = base.advanced(by: sy * stride)
                for x in 0..<image.width {
                    let sx = min(width - 1, x * width / image.width)
                    let value = row.loadUnaligned(fromByteOffset: sx * MemoryLayout<Float>.size, as: Float.self)
                    guard value.isFinite, value >= 0, value <= 1 else { return nil }
                    values.append(value)
                }
            }
            return values
        } catch {
            return nil
        }
    }
}
