import CoreGraphics

/// An 8-bit luma plane, row-major.
struct LumaImage {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: UnsafeRawBufferPointer

    func luma(_ x: Int, _ y: Int) -> UInt8 {
        bytes[y * bytesPerRow + x]
    }
}

/// Finds the picture inside the black bars a capture card adds when the HDMI
/// signal's shape differs from its output frame (e.g. a 16:10 laptop inside 16:9).
enum LetterboxDetector {
    enum Result: Equatable {
        /// The whole frame is black, e.g. no signal yet.
        case blank
        /// Dark edges that don't look like scaler bars; cropping would cut content.
        case uncertain
        /// The picture's rectangle, normalized to the frame with a top-left origin.
        case content(CGRect)
    }

    /// Video-range black is 16; leave headroom for scaler noise.
    static let blackThreshold: UInt8 = 28

    /// Common display shapes; a measured picture this close to one snaps to it exactly.
    static let knownAspects: [Double] = [16.0 / 9, 16.0 / 10, 3.0 / 2, 4.0 / 3, 5.0 / 4, 21.0 / 9]

    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func detect(in image: LumaImage) -> Result {
        let width = image.width
        let height = image.height
        guard width >= 32, height >= 32 else { return .uncertain }

        // A bar column must be black across its full height; sampling ~90 rows and
        // ~160 columns is plenty and keeps a 1080p frame to a few hundred thousand reads.
        let rowStep = max(1, height / 90)
        let columnStep = max(1, width / 160)
        func columnIsBlack(_ x: Int) -> Bool {
            stride(from: 0, to: height, by: rowStep).allSatisfy {
                image.luma(x, $0) <= blackThreshold
            }
        }
        func rowIsBlack(_ y: Int) -> Bool {
            stride(from: 0, to: width, by: columnStep).allSatisfy {
                image.luma($0, y) <= blackThreshold
            }
        }

        guard
            let left = (0..<width).first(where: { !columnIsBlack($0) }),
            let right = (0..<width).last(where: { !columnIsBlack($0) }),
            let top = (0..<height).first(where: { !rowIsBlack($0) }),
            let bottom = (0..<height).last(where: { !rowIsBlack($0) })
        else { return .blank }

        guard
            let horizontalBars = barTotal(leading: left, trailing: width - 1 - right, length: width),
            let verticalBars = barTotal(leading: top, trailing: height - 1 - bottom, length: height)
        else { return .uncertain }

        var contentWidth = Double(width) - horizontalBars
        var contentHeight = Double(height) - verticalBars
        let hasPillars = horizontalBars > 0
        let hasLetterbox = verticalBars > 0

        // Scalers center the picture, so snap a near-standard shape to its exact size.
        if hasPillars != hasLetterbox, let aspect = nearestKnownAspect(contentWidth / contentHeight) {
            if hasPillars {
                contentWidth = min(Double(width), contentHeight * aspect)
            } else {
                contentHeight = min(Double(height), contentWidth / aspect)
            }
        }

        let rect = CGRect(
            x: (Double(width) - contentWidth) / 2 / Double(width),
            y: (Double(height) - contentHeight) / 2 / Double(height),
            width: contentWidth / Double(width),
            height: contentHeight / Double(height)
        )
        return .content(rect)
    }

    /// The picture rectangle for a known source shape centered in a capture frame.
    static func centeredRect(aspect: Double, in frame: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0, aspect > 0 else { return fullFrame }
        let frameAspect = Double(frame.width / frame.height)
        if aspect < frameAspect {
            let width = aspect / frameAspect
            return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        } else {
            let height = frameAspect / aspect
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
    }

    /// Bars shorter than ~1% are ignored; bars must match on both sides within ~1%,
    /// otherwise a dark edge of the picture itself is being mistaken for a bar.
    private static func barTotal(leading: Int, trailing: Int, length: Int) -> Double? {
        let tolerance = max(2, length / 100)
        if max(leading, trailing) <= tolerance { return 0 }
        guard abs(leading - trailing) <= tolerance else { return nil }
        return Double(leading + trailing)
    }

    private static func nearestKnownAspect(_ aspect: Double) -> Double? {
        knownAspects
            .min(by: { abs($0 - aspect) < abs($1 - aspect) })
            .flatMap { abs($0 - aspect) / $0 <= 0.02 ? $0 : nil }
    }
}

enum CaptureGeometry {
    /// The frame for a preview layer that stretches the whole captured frame to its
    /// bounds (`.resize`), placed so the picture inside `content` exactly fits
    /// (or, when `fills`, exactly covers) `bounds`. The bars fall outside and are
    /// clipped. `content` has a top-left origin; the result uses AppKit's bottom-left one.
    static func previewFrame(
        bounds: CGRect,
        frameSize: CGSize,
        content: CGRect,
        fills: Bool
    ) -> CGRect {
        guard
            frameSize.width > 0, frameSize.height > 0,
            content.width > 0, content.height > 0,
            bounds.width > 0, bounds.height > 0
        else { return bounds }
        let pictureWidth = frameSize.width * content.width
        let pictureHeight = frameSize.height * content.height
        let widthScale = bounds.width / pictureWidth
        let heightScale = bounds.height / pictureHeight
        let scale = fills ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let layerWidth = frameSize.width * scale
        let layerHeight = frameSize.height * scale
        let pictureMinX = bounds.midX - pictureWidth * scale / 2
        let pictureMinY = bounds.midY - pictureHeight * scale / 2
        return CGRect(
            x: pictureMinX - content.minX * layerWidth,
            y: pictureMinY - (1 - content.maxY) * layerHeight,
            width: layerWidth,
            height: layerHeight
        )
    }

    /// A readable name such as "16:10" for a picture shape, if it is a common one.
    static func shapeName(width: Double, height: Double) -> String? {
        guard width > 0, height > 0 else { return nil }
        let names = ["16:9", "16:10", "3:2", "4:3", "5:4", "21:9"]
        let aspect = width / height
        return zip(LetterboxDetector.knownAspects, names)
            .first(where: { abs($0.0 - aspect) / $0.0 <= 0.02 })
            .map { $0.1 }
    }
}
