import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenGlyphCore

final class OCRServiceTests: XCTestCase {
    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OpenGlyphOCRTests-\(UUID()).\(fileExtension)")
    }

    private func bitmap(width: Int = 1_200, height: Int = 500) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private func draw(_ text: String, on context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat = 48) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

    private func textImage(lines: [String] = ["LOCAL TEXT CAPTURE", "SECOND LINE 42"]) throws -> CGImage {
        let context = try bitmap()
        for (index, text) in lines.enumerated() {
            draw(text, on: context, x: 80, y: 350 - CGFloat(index) * 100)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ image: CGImage, to url: URL, type: CFString, properties: [CFString: Any] = [:]) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testRecognizesLinesAndCanFlattenThem() throws {
        let image = try textImage()
        let multiline = try OCRService.recognize(image: image, options: RecognitionOptions(language: "en-US"))
        XCTAssertEqual(multiline.text, "LOCAL TEXT CAPTURE\nSECOND LINE 42")
        XCTAssertEqual(multiline.kind, .text)
        let flat = try OCRService.recognize(image: image, options: RecognitionOptions(keepLineBreaks: false))
        XCTAssertEqual(flat.text, "LOCAL TEXT CAPTURE SECOND LINE 42")
    }

    func testFastModeAndSupportedLanguages() throws {
        XCTAssertTrue(OCRService.supportedLanguages(mode: .accurate).contains("en-US"))
        XCTAssertTrue(OCRService.supportedLanguages(mode: .fast).contains("en-US"))
        let result = try OCRService.recognize(image: textImage(lines: ["FAST LOCAL OCR"]), options: RecognitionOptions(mode: .fast, language: "en-US"))
        XCTAssertEqual(result.text, "FAST LOCAL OCR")
        XCTAssertThrowsError(try OCRService.recognize(image: textImage(), options: RecognitionOptions(language: "nonexistent-language"))) {
            XCTAssertEqual($0 as? OCRServiceError, .unsupportedLanguage("nonexistent-language"))
        }
    }

    func testRecognizesImportedPNGJPEGAndTIFF() throws {
        for (fileExtension, type) in [("png", UTType.png.identifier), ("jpeg", UTType.jpeg.identifier), ("tiff", UTType.tiff.identifier)] {
            let url = temporaryURL(extension: fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            try write(textImage(lines: ["IMAGE IMPORT 123"]), to: url, type: type as CFString)
            XCTAssertEqual(try OCRService.recognize(fileURL: url).text, "IMAGE IMPORT 123", fileExtension)
        }
    }

    func testRecognizesImportedHEIC() throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(UTType.heic.identifier) else {
            throw XCTSkip("This Mac cannot encode a HEIC fixture.")
        }
        let url = temporaryURL(extension: "heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(textImage(lines: ["HEIC IMPORT 123"]), to: url, type: UTType.heic.identifier as CFString)
        XCTAssertEqual(try OCRService.recognize(fileURL: url).text, "HEIC IMPORT 123")
    }

    func testAppliesJPEGEXIFOrientation() throws {
        let upright = try textImage(lines: ["ORIENTED IMAGE 123"])
        let rotated = try bitmap(width: upright.height, height: upright.width)
        rotated.translateBy(x: CGFloat(upright.height), y: 0)
        rotated.rotate(by: .pi / 2)
        rotated.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
        let url = temporaryURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(XCTUnwrap(rotated.makeImage()), to: url, type: UTType.jpeg.identifier as CFString,
                  properties: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1])
        XCTAssertEqual(try OCRService.recognize(fileURL: url).text, "ORIENTED IMAGE 123")
    }

    func testQRCodePayloadWinsOverPrintedCaption() throws {
        let payload = "https://example.com/openglyph"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage)
        let code = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        let context = try bitmap(width: 700, height: 700)
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: 100, y: 180, width: 500, height: 500))
        draw("PRINTED CAPTION", on: context, x: 80, y: 80, size: 36)
        let result = try OCRService.recognize(image: XCTUnwrap(context.makeImage()))
        XCTAssertEqual(result.text, payload)
        XCTAssertEqual(result.kind, .qrCode)
    }

    func testRecognizesCode128Barcode() throws {
        let payload = "OPENGLYPH-123456"
        let filter = try XCTUnwrap(CIFilter(name: "CICode128BarcodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(filter.outputImage)
        let code = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        let context = try bitmap(width: 1_200, height: 400)
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: 100, y: 100, width: 1_000, height: 200))
        let result = try OCRService.recognize(image: XCTUnwrap(context.makeImage()))
        XCTAssertEqual(result.text, payload)
        XCTAssertEqual(result.kind, .qrCode)
    }

    func testRecognizesAllPDFPagesIncludingAfterAnEmptyPage() throws {
        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for text in ["FIRST PDF PAGE", "", "THIRD PDF PAGE"] {
            context.beginPDFPage(nil)
            if !text.isEmpty { draw(text, on: context, x: 50, y: 600, size: 30) }
            context.endPDFPage()
        }
        context.closePDF()
        let result = try OCRService.recognize(fileURL: url)
        XCTAssertEqual(result.text, "FIRST PDF PAGE\n\nTHIRD PDF PAGE")
        XCTAssertEqual(result.kind, .text)
    }

    func testClassifiesRecognizedWebLink() throws {
        let result = try OCRService.recognize(image: textImage(lines: ["https://example.com"]), options: RecognitionOptions(language: "en-US"))
        XCTAssertEqual(result.text, "https://example.com")
        XCTAssertEqual(result.kind, .link)
    }

    func testEmptyImageAndUnsupportedFileHaveExplicitErrors() throws {
        XCTAssertThrowsError(try OCRService.recognize(image: XCTUnwrap(bitmap().makeImage()))) {
            XCTAssertEqual($0 as? OCRServiceError, .noContent)
        }
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try OCRService.recognize(fileURL: url)) {
            XCTAssertEqual($0 as? OCRServiceError, .unsupportedFile)
        }
        XCTAssertThrowsError(try OCRService.recognize(fileURL: URL(string: "https://example.com/image.png")!)) {
            XCTAssertEqual($0 as? OCRServiceError, .unreadableFile)
        }
    }

    func testRejectsPDFBeyondPageLimit() throws {
        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for _ in 0...OCRService.maximumPDFPages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        XCTAssertThrowsError(try OCRService.recognize(fileURL: url)) {
            XCTAssertEqual($0 as? OCRServiceError, .tooManyPages)
        }
    }

    func testRejectsFileBeyondSizeLimitBeforeDecoding() throws {
        let url = temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(OCRService.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try OCRService.recognize(fileURL: url)) {
            XCTAssertEqual($0 as? OCRServiceError, .fileTooLarge)
        }
    }

    func testPasswordProtectedPDFReportsLockedError() throws {
        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let options: [CFString: Any] = [kCGPDFContextUserPassword: "test-password", kCGPDFContextOwnerPassword: "owner-password"]
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, options as CFDictionary))
        context.beginPDFPage(nil)
        draw("LOCKED PDF", on: context, x: 50, y: 600, size: 30)
        context.endPDFPage()
        context.closePDF()
        XCTAssertThrowsError(try OCRService.recognize(fileURL: url)) {
            XCTAssertEqual($0 as? OCRServiceError, .lockedPDF)
        }
    }

    func testRendersRotatedPDFPageInDisplayedOrientation() throws {
        let original = temporaryURL(extension: "pdf")
        let rotated = temporaryURL(extension: "pdf")
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: rotated)
        }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(original as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.rotate(by: .pi / 2)
        draw("ROTATED PDF PAGE", on: context, x: 100, y: -400, size: 30)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: original))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        XCTAssertTrue(document.write(to: rotated))
        XCTAssertEqual(try OCRService.recognize(fileURL: rotated).text, "ROTATED PDF PAGE")
    }
}
