import CoreGraphics
import Foundation
import XCTest
@testable import OpenGlyphCore

final class CaptureGeometryTests: XCTestCase {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]
    private let green: [UInt8] = [0, 255, 0, 255]
    private let yellow: [UInt8] = [255, 255, 0, 255]
    private let white: [UInt8] = [255, 255, 255, 255]

    func testScaledMacBookAirCaptureUsesFilterDimensions() {
        // "More Space" on the Air renders 2940x1912 pixels on its 2560x1664 panel.
        XCTAssertEqual(CaptureGeometry.screenshotPixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 1470, height: 956), pointPixelScale: 2
        ), CGSize(width: 2940, height: 1912))
    }

    func testCaptureUsesOwnScaleInsteadOfAppKitBackingScale() {
        XCTAssertEqual(CaptureGeometry.screenshotPixelSize(
            contentRect: CGRect(x: 1920, y: -200, width: 1920, height: 1080), pointPixelScale: 1
        ), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(CaptureGeometry.screenshotPixelSize(
            contentRect: CGRect(x: -1920, y: 0, width: 1920, height: 1080), pointPixelScale: 1.5
        ), CGSize(width: 2880, height: 1620))
    }

    func testInvalidCaptureDimensionsAreRejected() {
        XCTAssertNil(CaptureGeometry.screenshotPixelSize(contentRect: .zero, pointPixelScale: 2))
        XCTAssertNil(CaptureGeometry.screenshotPixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), pointPixelScale: .nan
        ))
        XCTAssertNil(CaptureGeometry.screenshotPixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), pointPixelScale: 2
        ))
    }

    func testRetinaCropFlipsScreenYAxis() {
        let crop = CaptureGeometry.pixelRect(
            for: CGRect(x: 100, y: 700, width: 300, height: 100),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            imageSize: CGSize(width: 2880, height: 1800)
        )
        XCTAssertEqual(crop, CGRect(x: 200, y: 200, width: 600, height: 200))
    }

    func testNegativeAndVerticalDisplayOrigins() {
        let crop = CaptureGeometry.pixelRect(
            for: CGRect(x: -1700, y: 1000, width: 200, height: 100),
            screenFrame: CGRect(x: -1920, y: 900, width: 1920, height: 1080),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(crop, CGRect(x: 220, y: 880, width: 200, height: 100))
    }

    func testSelectionAcrossScreensIsClippedPerDisplay() {
        let selection = CGRect(x: -100, y: 200, width: 400, height: 200)
        XCTAssertEqual(
            CaptureGeometry.pixelRect(
                for: selection,
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                imageSize: CGSize(width: 2880, height: 1800)
            ),
            CGRect(x: 0, y: 1000, width: 600, height: 400)
        )
    }

    func testFractionalCoordinatesRoundOutward() {
        XCTAssertEqual(
            CaptureGeometry.pixelRect(
                for: CGRect(x: 0.3, y: 20.2, width: 10.1, height: 5.3),
                screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                imageSize: CGSize(width: 200, height: 200)
            ),
            CGRect(x: 0, y: 149, width: 21, height: 11)
        )
    }

    func testOutsideEmptyAndInvalidSelectionsAreRejected() {
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        let size = CGSize(width: 200, height: 200)
        for selection in [CGRect.zero, CGRect(x: 200, y: 200, width: 10, height: 10)] {
            XCTAssertNil(CaptureGeometry.pixelRect(for: selection, screenFrame: screen, imageSize: size))
        }
        XCTAssertNil(CaptureGeometry.pixelRect(for: screen, screenFrame: .zero, imageSize: size))
        XCTAssertNil(CaptureGeometry.pixelRect(for: screen, screenFrame: screen, imageSize: .zero))
        XCTAssertNil(CaptureGeometry.pixelRect(
            for: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
            screenFrame: screen, imageSize: size
        ))
    }

    func testDragInEveryDirectionHasSameBounds() {
        let low = CGPoint(x: -30, y: 50)
        let high = CGPoint(x: 20, y: 100)
        let expected = CGRect(x: -30, y: 50, width: 50, height: 50)
        XCTAssertEqual(CaptureGeometry.selection(from: low, to: high), expected)
        XCTAssertEqual(CaptureGeometry.selection(from: high, to: low), expected)
        XCTAssertEqual(
            CaptureGeometry.selection(from: CGPoint(x: low.x, y: high.y), to: CGPoint(x: high.x, y: low.y)),
            expected
        )
    }

    func testVerticallyStackedDisplaysKeepOrderAndFragmentsUpright() throws {
        let upper = CaptureGeometry.Screenshot(
            frame: CGRect(x: 0, y: 10, width: 10, height: 10),
            image: try stripedImage(width: 10, height: 10, top: red, bottom: blue)
        )
        let lower = CaptureGeometry.Screenshot(
            frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            image: try stripedImage(width: 10, height: 10, top: green, bottom: yellow)
        )
        let image = try CaptureGeometry.composedImage(
            for: CGRect(x: 0, y: 0, width: 10, height: 20), screenshots: [upper, lower]
        )
        XCTAssertEqual(image.width, 10)
        XCTAssertEqual(image.height, 20)
        XCTAssertEqual(try pixel(image, x: 5, row: 2), red)
        XCTAssertEqual(try pixel(image, x: 5, row: 7), blue)
        XCTAssertEqual(try pixel(image, x: 5, row: 12), green)
        XCTAssertEqual(try pixel(image, x: 5, row: 17), yellow)
    }

    func testStaggeredDisplaysKeepGapsAndEachFragmentUpright() throws {
        let upperLeft = CaptureGeometry.Screenshot(
            frame: CGRect(x: -4, y: 4, width: 4, height: 4),
            image: try stripedImage(width: 4, height: 4, top: red, bottom: blue)
        )
        let lowerRight = CaptureGeometry.Screenshot(
            frame: CGRect(x: 0, y: 0, width: 4, height: 4),
            image: try stripedImage(width: 4, height: 4, top: green, bottom: yellow)
        )
        let image = try CaptureGeometry.composedImage(
            for: CGRect(x: -4, y: 0, width: 8, height: 8), screenshots: [upperLeft, lowerRight]
        )
        XCTAssertEqual(try pixel(image, x: 1, row: 1), red)
        XCTAssertEqual(try pixel(image, x: 1, row: 3), blue)
        XCTAssertEqual(try pixel(image, x: 6, row: 5), green)
        XCTAssertEqual(try pixel(image, x: 6, row: 7), yellow)
        XCTAssertEqual(try pixel(image, x: 6, row: 1), white)
        XCTAssertEqual(try pixel(image, x: 1, row: 7), white)
    }

    func testMixedRetinaDisplaysPreserveDenseResolution() throws {
        let retina = CaptureGeometry.Screenshot(
            frame: CGRect(x: 0, y: 0, width: 4, height: 4),
            image: try stripedImage(width: 8, height: 8, top: red, bottom: blue)
        )
        let standard = CaptureGeometry.Screenshot(
            frame: CGRect(x: 4, y: 0, width: 4, height: 4),
            image: try stripedImage(width: 4, height: 4, top: green, bottom: green)
        )
        let image = try CaptureGeometry.composedImage(
            for: CGRect(x: 0, y: 0, width: 8, height: 4), screenshots: [retina, standard]
        )
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 8)
        XCTAssertEqual(try pixel(image, x: 3, row: 1), red)
        XCTAssertEqual(try pixel(image, x: 3, row: 6), blue)
        XCTAssertEqual(try pixel(image, x: 12, row: 3), green)
    }

    private func stripedImage(width: Int, height: Int, top: [UInt8], bottom: [UInt8]) throws -> CGImage {
        var bytes: [UInt8] = []
        for row in 0..<height {
            for _ in 0..<width { bytes.append(contentsOf: row < height / 2 ? top : bottom) }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    /// Image data is ordered from the top row, unlike CGContext drawing coordinates.
    private func pixel(_ image: CGImage, x: Int, row: Int) throws -> [UInt8] {
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = row * image.bytesPerRow + x * 4
        return Array(bytes[offset..<(offset + 4)])
    }
}
