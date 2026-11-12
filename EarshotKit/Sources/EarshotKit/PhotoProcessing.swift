import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo made ready to send: small, plain JPEG with no metadata.
public struct PreparedPhoto: Sendable, Equatable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    /// A tiny JPEG (about 24 pixels on the long side) used as a blurred placeholder on
    /// the other phone while the real photo arrives.
    public let preview: Data?

    public init(jpeg: Data, width: Int, height: Int, preview: Data?) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.preview = preview
    }
}

/// Shrinking, checking and decoding photos with Apple's ImageIO. No UIKit, so it runs in
/// tests on the Mac and in `earshot-probe` too.
///
/// Everything here can take tens of milliseconds; call it from a background task.
public enum PhotoProcessing {
    public enum Failure: Error, Equatable {
        /// Not an image ImageIO can read.
        case unreadable
        /// Could not get it under `PhotoLimits.maxPreparedBytes` even at the smallest size tried.
        case tooLarge
    }

    // MARK: Preparing a photo to send

    /// Turns any photo (HEIC, JPEG, PNG… straight from the photo library) into what Earshot sends:
    ///
    /// 1. Scaled so the long side is at most 1,280 pixels, turned upright (the camera's
    ///    "rotate this" flag is applied to the pixels, then dropped).
    /// 2. Redrawn into a plain sRGB picture, which also flattens transparency onto white.
    /// 3. Saved as JPEG, starting at quality 0.72 and stepping down (then shrinking to
    ///    1,024, 800, 640 pixels) until it is at most ~150 KB.
    /// 4. Cleaned: every metadata block is removed from the file (location, camera, dates,
    ///    comments, colour profile). See `stripMetadata`.
    public static func prepare(_ source: PhotoSource) throws -> PreparedPhoto {
        guard let imageSource = makeSource(source), CGImageSourceGetCount(imageSource) > 0 else {
            throw Failure.unreadable
        }
        var smallest: (data: Data, image: CGImage)?
        for longSide in [PhotoLimits.maxLongSide, 1024, 800, 640] {
            guard let scaled = thumbnail(imageSource, maxPixelSize: longSide), let flat = redrawn(scaled) else {
                throw Failure.unreadable
            }
            for quality in [0.72, 0.6, 0.5, 0.42] {
                guard let jpeg = encodeJPEG(flat, quality: quality) else { throw Failure.unreadable }
                if smallest == nil || jpeg.count < smallest!.data.count { smallest = (jpeg, flat) }
                if jpeg.count <= PhotoLimits.targetBytes {
                    return PreparedPhoto(jpeg: jpeg, width: flat.width, height: flat.height, preview: makePreview(flat))
                }
            }
        }
        guard let smallest, smallest.data.count <= PhotoLimits.maxPreparedBytes else { throw Failure.tooLarge }
        return PreparedPhoto(jpeg: smallest.data, width: smallest.image.width, height: smallest.image.height,
                             preview: makePreview(smallest.image))
    }

    /// The tiny blurred-placeholder JPEG for an already prepared photo.
    public static func makePreview(from source: PhotoSource) -> Data? {
        decode(source, maxPixelSize: PhotoLimits.previewLongSide * 2).flatMap(makePreview)
    }

    private static func makePreview(_ image: CGImage) -> Data? {
        let long = max(image.width, image.height)
        let scale = Double(PhotoLimits.previewLongSide) / Double(max(long, 1))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let small = redrawn(image, width: width, height: height),
              let jpeg = encodeJPEG(small, quality: 0.5), jpeg.count <= PhotoLimits.maxPreviewBytes else { return nil }
        return jpeg
    }

    // MARK: Checking a received photo

    /// Checks that received bytes are a real, sane JPEG before anything shows it.
    /// Returns its real pixel size (as it will be displayed), or nil.
    ///
    /// Nothing the sender said is trusted: the type and size are read from the file. The
    /// size is checked *before* decoding, so a small file claiming to be 50,000 × 50,000
    /// pixels (a "decompression bomb") is refused without unpacking it. The final decode
    /// is a scaled-down one, which still reads the whole file but never allocates more
    /// than a 1,280-pixel picture.
    public static func validate(_ source: PhotoSource,
                                maxSide: Int = PhotoLimits.maxDecodedSide,
                                maxPixels: Int = PhotoLimits.maxDecodedPixels) -> (width: Int, height: Int)? {
        guard endsWithEndOfImage(source), let imageSource = makeSource(source),
              CGImageSourceGetStatus(imageSource) == .statusComplete,
              CGImageSourceGetCount(imageSource) == 1,
              let type = CGImageSourceGetType(imageSource) as String?, type == UTType.jpeg.identifier,
              let size = pixelSize(imageSource, maxSide: maxSide, maxPixels: maxPixels),
              let decoded = thumbnail(imageSource, maxPixelSize: min(max(size.width, size.height), PhotoLimits.maxLongSide)),
              decoded.width > 0, decoded.height > 0 else { return nil }
        return size
    }

    /// A complete JPEG ends with the two bytes `FF D9`. ImageIO happily shows half a picture
    /// (grey below the cut), so a file cut short is caught here instead.
    private static func endsWithEndOfImage(_ source: PhotoSource) -> Bool {
        switch source {
        case .data(let data):
            return data.count >= 4 && data.suffix(2).elementsEqual([0xFF, 0xD9])
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd(), end >= 4 else { return false }
            try? handle.seek(toOffset: end - 2)
            return (try? handle.read(upToCount: 2))?.elementsEqual([0xFF, 0xD9]) == true
        }
    }

    /// Decodes a stored photo for display, scaled so its long side is at most `maxPixelSize`.
    /// Applies the same size checks as `validate`, so it is safe on any file.
    public static func decode(_ source: PhotoSource, maxPixelSize: Int) -> CGImage? {
        guard let imageSource = makeSource(source),
              pixelSize(imageSource, maxSide: PhotoLimits.maxDecodedSide, maxPixels: PhotoLimits.maxDecodedPixels) != nil
        else { return nil }
        return thumbnail(imageSource, maxPixelSize: maxPixelSize)
    }

    /// The displayed size (orientation applied), or nil if missing or beyond the limits.
    private static func pixelSize(_ source: CGImageSource, maxSide: Int, maxPixels: Int) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxSide, height <= maxSide,
              width.multipliedReportingOverflow(by: height).partialValue <= maxPixels else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    // MARK: Metadata

    /// Removes every metadata block from a JPEG file and keeps only what is needed to draw it.
    ///
    /// A JPEG is a list of blocks ("segments"). Kept: the picture data and the tables
    /// needed to decode it, plus the two tiny standard headers APP0 (JFIF) and APP14
    /// (Adobe colour flags). Removed: APP1 (EXIF and XMP: GPS position, camera model,
    /// dates, often a full-size preview), APP2 (colour profile; the picture is plain sRGB,
    /// which is what every viewer assumes without one), APP3–APP13, APP15 and comments.
    /// Returns nil if the file is not a well-formed JPEG.
    public static func stripMetadata(_ jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        out.reserveCapacity(bytes.count)
        var index = 2
        while index < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            var markerIndex = index + 1
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { markerIndex += 1 } // fill bytes
            guard markerIndex < bytes.count else { return nil }
            let marker = bytes[markerIndex]
            if marker == 0xD9 { // end of image
                out += [0xFF, 0xD9]
                return Data(out)
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { // markers with no length
                out += [0xFF, marker]
                index = markerIndex + 1
                continue
            }
            guard markerIndex + 2 < bytes.count else { return nil }
            let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
            let end = markerIndex + 1 + length
            guard length >= 2, end <= bytes.count else { return nil }
            if marker == 0xDA {
                // Start of the picture data: everything from here on is pixels (and, in
                // progressive files, more tables), never metadata. Copy it as it is.
                out += [0xFF]
                out += bytes[markerIndex...]
                return Data(out)
            }
            let isMetadata = (0xE1...0xED).contains(marker) || marker == 0xEF || marker == 0xFE
            if !isMetadata { out += [0xFF]; out += bytes[markerIndex..<end] }
            index = end
        }
        return nil
    }

    // MARK: Sample pictures

    /// A made-up landscape (sky, sun, hills), the same every time for the same `seed`.
    /// Used by demo mode, screenshots, tests and `earshot-probe --send-photo`; never a real photo.
    /// `metadata` lets tests add EXIF/GPS blocks to check that `prepare` removes them.
    public static func sampleJPEG(width: Int = 1600, height: Int = 1200, seed: Int = 0,
                                  quality: Double = 0.9, metadata: [CFString: Any]? = nil) -> Data {
        guard let image = sampleImage(width: width, height: height, seed: seed),
              let data = encodeJPEG(image, quality: quality, properties: metadata, strip: false) else { return Data() }
        return data
    }

    static func sampleImage(width: Int, height: Int, seed: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let palettes: [[(CGFloat, CGFloat, CGFloat)]] = [
            [(0.98, 0.78, 0.55), (0.93, 0.45, 0.32), (0.45, 0.22, 0.30)], // dusk
            [(0.72, 0.86, 0.95), (0.45, 0.66, 0.86), (0.20, 0.32, 0.52)], // morning
            [(0.99, 0.90, 0.70), (0.86, 0.62, 0.40), (0.42, 0.30, 0.22)], // desert
        ]
        let palette = palettes[abs(seed) % palettes.count]
        let colors = palette.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
        // CoreGraphics' origin is bottom-left: the sky's light end is at the bottom (the horizon).
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h * 0.35), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Sun.
        context.setFillColor(CGColor(red: 1, green: 0.93, blue: 0.75, alpha: 0.95))
        let sun = min(w, h) * 0.13
        let sunX = w * (0.25 + 0.5 * CGFloat((seed * 37) % 100) / 100)
        context.fillEllipse(in: CGRect(x: sunX - sun, y: h * 0.42, width: sun * 2, height: sun * 2))
        // Three layers of hills, darker towards the front.
        for layer in 0..<3 {
            let shade = 0.32 - CGFloat(layer) * 0.1
            context.setFillColor(CGColor(red: shade * 0.9, green: shade * 0.75 + 0.04, blue: shade * 0.7, alpha: 1))
            let base = h * (0.38 - CGFloat(layer) * 0.12)
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLine(to: CGPoint(x: 0, y: base))
            let steps = 24
            for step in 0...steps {
                let x = w * CGFloat(step) / CGFloat(steps)
                let phase = CGFloat(seed + layer * 3)
                let y = base + h * 0.05 * sin(CGFloat(step) * 0.55 + phase) + h * 0.03 * sin(CGFloat(step) * 1.7 + phase * 2)
                context.addLine(to: CGPoint(x: x, y: y))
            }
            context.addLine(to: CGPoint(x: w, y: 0))
            context.closePath()
            context.fillPath()
        }
        return context.makeImage()
    }

    // MARK: ImageIO helpers

    private static func makeSource(_ source: PhotoSource) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        switch source {
        case .data(let data): return CGImageSourceCreateWithData(data as CFData, options)
        case .file(let url): return CGImageSourceCreateWithURL(url as CFURL, options)
        }
    }

    /// Decodes at most `maxPixelSize` on the long side, upright. Never scales up.
    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Draws the picture into a plain 8-bit sRGB canvas with a white background.
    private static func redrawn(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> CGImage? {
        let width = width ?? image.width, height = height ?? image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double, properties: [CFString: Any]? = nil,
                                   strip: Bool = true) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        var options = properties ?? [:]
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return strip ? stripMetadata(output as Data) : output as Data
    }
}
