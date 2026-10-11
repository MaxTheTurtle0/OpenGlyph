import CoreGraphics
import Foundation

/// Converts AppKit's bottom-left screen coordinates to a screenshot's top-left pixels.
public enum CaptureGeometry {
    public struct Screenshot {
        public let frame: CGRect
        public let image: CGImage

        public init(frame: CGRect, image: CGImage) {
            self.frame = frame
            self.image = image
        }
    }

    public enum ImageError: LocalizedError {
        case emptySelection, selectionTooLarge, imageCreationFailed

        public var errorDescription: String? {
            switch self {
            case .emptySelection: return "Select a larger region containing text or a QR code."
            case .selectionTooLarge: return "This capture is too large. Select a smaller region or use fewer displays."
            case .imageCreationFailed: return "The selected region could not be read. Try capturing again."
            }
        }
    }

    public static func selection(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    /// Rounds outwards so fractional Retina coordinates never omit an edge of a glyph.
    public static func pixelRect(
        for selection: CGRect,
        screenFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        guard isFinite(selection), isFinite(screenFrame),
              imageSize.width.isFinite, imageSize.height.isFinite,
              screenFrame.width > 0, screenFrame.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let clipped = selection.standardized.intersection(screenFrame)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let scaleX = imageSize.width / screenFrame.width
        let scaleY = imageSize.height / screenFrame.height
        let left = floor((clipped.minX - screenFrame.minX) * scaleX)
        let top = floor((screenFrame.maxY - clipped.maxY) * scaleY)
        let right = ceil((clipped.maxX - screenFrame.minX) * scaleX)
        let bottom = ceil((screenFrame.maxY - clipped.minY) * scaleY)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Crops frozen screenshots and combines selections that span multiple displays.
    public static func composedImage(for selection: CGRect, screenshots: [Screenshot]) throws -> CGImage {
        guard isFinite(selection) else { throw ImageError.emptySelection }
        let selection = selection.standardized
        let intersecting = screenshots.filter {
            isFinite($0.frame) && $0.frame.width > 0 && $0.frame.height > 0 &&
            !$0.frame.intersection(selection).isEmpty
        }
        guard !intersecting.isEmpty else { throw ImageError.emptySelection }
        if intersecting.count == 1, let screenshot = intersecting.first {
            guard let rect = pixelRect(
                for: selection, screenFrame: screenshot.frame,
                imageSize: CGSize(width: screenshot.image.width, height: screenshot.image.height)
            ), let cropped = screenshot.image.cropping(to: rect) else { throw ImageError.emptySelection }
            return cropped
        }
        // Preserve the sharpest display's resolution when Retina and 1x screens are selected together.
        let scale = intersecting.map { CGFloat($0.image.width) / $0.frame.width }.max() ?? 1
        let width = ceil(selection.width * scale)
        let height = ceil(selection.height * scale)
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              width * height <= 100_000_000 else { throw ImageError.selectionTooLarge }
        guard let context = CGContext(
            data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageError.imageCreationFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for screenshot in intersecting {
            let intersection = selection.intersection(screenshot.frame)
            guard let rect = pixelRect(
                for: selection, screenFrame: screenshot.frame,
                imageSize: CGSize(width: screenshot.image.width, height: screenshot.image.height)
            ), let cropped = screenshot.image.cropping(to: rect) else { throw ImageError.imageCreationFailed }
            // CGContext drawing uses bottom-left coordinates; cropping above uses top-left image pixels.
            let destination = CGRect(
                x: (intersection.minX - selection.minX) * scale,
                y: (intersection.minY - selection.minY) * scale,
                width: intersection.width * scale, height: intersection.height * scale
            )
            context.draw(cropped, in: destination)
        }
        guard let image = context.makeImage() else { throw ImageError.imageCreationFailed }
        return image
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite
    }
}
