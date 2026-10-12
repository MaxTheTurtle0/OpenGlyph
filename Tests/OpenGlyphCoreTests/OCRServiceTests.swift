import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
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

    private func draw(_ text: String, on context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat = 48,
                      fontName: String = "Helvetica-Bold") {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

    private func textImage(lines: [String] = ["LOCAL TEXT CAPTURE", "SECOND LINE 42"],
                           fontName: String = "Helvetica-Bold") throws -> CGImage {
        let context = try bitmap()
        for (index, text) in lines.enumerated() {
            draw(text, on: context, x: 80, y: 350 - CGFloat(index) * 100, fontName: fontName)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ image: CGImage, to url: URL, type: CFString, properties: [CFString: Any] = [:]) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func exportFixture(_ image: CGImage, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["OPENGLYPH_OCR_FIXTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(image, to: directory.appendingPathComponent(name + ".png"), type: UTType.png.identifier as CFString)
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
        let result = try OCRService.recognize(image: textImage(lines: ["https://example.com"], fontName: "Helvetica"), options: RecognitionOptions(language: "en-US"))
        XCTAssertEqual(result.text, "https://example.com")
        XCTAssertEqual(result.kind, .link)
    }

    func testBoldURLPunctuationMisreadDoesNotBecomeAnOpenableLink() throws {
        let result = try OCRService.recognize(image: textImage(lines: ["https://example.com"]),
                                              options: RecognitionOptions(language: "en-US"))
        if result.usedFastRecovery && result.text != "https://example.com" {
            // Fast Vision currently reads the bold colon as a J on the Air.
            // Preserve that output; never invent punctuation to make a link.
            XCTAssertEqual(result.kind, .text)
            XCTAssertNil(CaptureItem(text: result.text, kind: result.kind, source: "Test").linkURL)
        } else {
            XCTAssertEqual(result.text, "https://example.com")
            XCTAssertEqual(result.kind, .link)
        }
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

    private func screenCrop(text: String, fontSize: CGFloat, width: Int, height: Int,
                            bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
                            bitsPerComponent: Int = 8, colorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.displayP3)) throws -> CGImage {
        let bytesPerPixel = bitsPerComponent == 16 ? 8 : 4
        let context = try XCTUnwrap(CGContext(data: nil, width: 1_601, height: 1_001,
                                            bitsPerComponent: bitsPerComponent, bytesPerRow: 1_664 * bytesPerPixel,
                                            space: try XCTUnwrap(colorSpace), bitmapInfo: bitmapInfo))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_601, height: 1_001))
        draw(text, on: context, x: 103, y: 501, size: fontSize)
        let screenshot = try XCTUnwrap(context.makeImage())
        // Odd origins and an inherited full-screen stride match Retina crops.
        return try XCTUnwrap(screenshot.cropping(to: CGRect(x: 101, y: 1_001 - 501 - height + 3, width: width, height: height)))
    }

    func testRecognizesRepeatedTightBGRAScreenCrops() throws {
        for _ in 0..<3 {
            let word = try screenCrop(text: "HELLO", fontSize: 20, width: 83, height: 25)
            try exportFixture(word, name: "tight-word")
            XCTAssertEqual(try OCRService.recognize(image: word).text, "HELLO")
            let line = try screenCrop(text: "LOCAL CAPTURE LINE", fontSize: 28, width: 337, height: 35)
            try exportFixture(line, name: "tight-line")
            XCTAssertEqual(try OCRService.recognize(image: line, options: RecognitionOptions(language: "en-US")).text, "LOCAL CAPTURE LINE")
        }
    }

    func testTinyEmptyCropsReturnNoContent() throws {
        for (width, height) in [(1, 1), (1, 31), (31, 1), (3, 31), (31, 3), (11, 11)] {
            for gray in [CGFloat(0), 0.5, 1] {
                let context = try bitmap(width: width, height: height)
                context.setFillColor(CGColor(gray: gray, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let image = try XCTUnwrap(context.makeImage())
                XCTAssertThrowsError(try OCRService.recognize(image: image)) {
                    XCTAssertEqual($0 as? OCRServiceError, .noContent, "\(width) × \(height), gray \(gray)")
                }
            }
        }
    }

    func testRecognizesHalfFloatHDRScreenCrop() throws {
        let image = try screenCrop(text: "HDR CAPTURE", fontSize: 28, width: 241, height: 35,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue,
                                   bitsPerComponent: 16, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        try exportFixture(image, name: "hdr-crop")
        XCTAssertEqual(try OCRService.recognize(image: image).text, "HDR CAPTURE")
    }

    func testRecognizesTransparentPixelsOverWhite() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 100, bitsPerComponent: 8,
                                            bytesPerRow: 2_000, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw("TRANSPARENT TEXT", on: context, x: 15, y: 40, size: 32)
        let image = try XCTUnwrap(context.makeImage())
        try exportFixture(image, name: "transparent-text")
        XCTAssertEqual(try OCRService.recognize(image: image).text, "TRANSPARENT TEXT")
    }

    func testComputeFailureRecoversWithAccurateCompatibilityEngine() throws {
        var attemptedRevisions: [Int] = []
        let image = try textImage(lines: ["COMPATIBLE TEXT"])
        let result = try OCRService.recognizeText(in: image, options: RecognitionOptions(language: "en-US")) { image, request in
            attemptedRevisions.append(request.revision)
            XCTAssertEqual(request.recognitionLevel, .accurate)
            XCTAssertEqual(request.recognitionLanguages, ["en-US"])
            XCTAssertFalse(request.automaticallyDetectsLanguage)
            if request.revision > 2 {
                throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
            }
        }
        XCTAssertEqual(attemptedRevisions, [VNRecognizeTextRequest.defaultRevision, 2])
        XCTAssertTrue(result.usedCompatibilityEngine)
        XCTAssertFalse(result.usedFastRecovery)
        XCTAssertEqual(result.request.revision, 2)
    }

    func testAutomaticModeCompatibilityRecoveryIsMarkedAndUsesSupportedLanguages() throws {
        let image = try textImage(lines: ["AUTOMATIC RECOVERY"])
        let result = try OCRService.recognizeText(in: image, options: RecognitionOptions()) { image, request in
            if request.recognitionLevel == .accurate && request.revision > 2 {
                XCTAssertTrue(request.automaticallyDetectsLanguage)
                throw NSError(domain: VNErrorDomain, code: VNErrorCode.internalError.rawValue)
            }
            XCTAssertFalse(request.automaticallyDetectsLanguage)
            let supported = try request.supportedRecognitionLanguages()
            XCTAssertFalse(request.recognitionLanguages.isEmpty)
            XCTAssertTrue(request.recognitionLanguages.allSatisfy { supported.contains($0) })
            try VNImageRequestHandler(cgImage: image).perform([request])
        }
        XCTAssertTrue(result.usedCompatibilityEngine)
        XCTAssertEqual(result.request.results?.compactMap { $0.topCandidates(1).first?.string }, ["AUTOMATIC RECOVERY"])
    }

    func testAccurateComputeFailuresRecoverWithRealFastRecognition() throws {
        var levels: [VNRequestTextRecognitionLevel] = []
        let result = try OCRService.recognizeText(in: textImage(lines: ["FAST BACKUP TEXT"]),
                                                  options: RecognitionOptions(language: "en-US")) { image, request in
            levels.append(request.recognitionLevel)
            XCTAssertEqual(request.recognitionLanguages, ["en-US"])
            if request.recognitionLevel == .accurate {
                throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
            }
            try VNImageRequestHandler(cgImage: image).perform([request])
        }
        XCTAssertEqual(levels, [.accurate, .accurate, .fast])
        XCTAssertTrue(result.usedCompatibilityEngine)
        XCTAssertTrue(result.usedFastRecovery)
        XCTAssertEqual(result.request.results?.compactMap { $0.topCandidates(1).first?.string }, ["FAST BACKUP TEXT"])
    }

    func testCompatibilityDoesNotReplaceUnsupportedExplicitLanguage() throws {
        var calls = 0
        XCTAssertThrowsError(try OCRService.recognizeText(in: textImage(), options: RecognitionOptions(language: "ja-JP")) { _, _ in
            calls += 1
            throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
        }) {
            XCTAssertEqual(($0 as NSError).domain, "TextRecognition.CRImageReaderError")
        }
        XCTAssertEqual(calls, 1)
    }

    func testCancellationAndNoContentDoNotTriggerCompatibilityEngine() throws {
        for failure in [OCRServiceError.noContent as Error, NSError(domain: VNErrorDomain, code: VNErrorCode.requestCancelled.rawValue)] {
            var calls = 0
            XCTAssertThrowsError(try OCRService.recognizeText(in: textImage(), options: RecognitionOptions()) { _, _ in
                calls += 1
                throw failure
            }) {
                XCTAssertEqual(($0 as NSError).domain, (failure as NSError).domain)
                XCTAssertEqual(($0 as NSError).code, (failure as NSError).code)
            }
            XCTAssertEqual(calls, 1)
        }
    }

    func testCompatibilityFailureIsNotRetriedIndefinitely() throws {
        var revisions: [Int] = []
        XCTAssertThrowsError(try OCRService.recognizeText(in: textImage(), options: RecognitionOptions(language: "en-US")) { _, request in
            revisions.append(request.revision)
            throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
        })
        XCTAssertEqual(revisions, [VNRecognizeTextRequest.defaultRevision, 2, VNRecognizeTextRequest.defaultRevision])
    }

    func testRequestedFastModeComputeFailureIsNotRetried() throws {
        var calls = 0
        XCTAssertThrowsError(try OCRService.recognizeText(in: textImage(), options: RecognitionOptions(mode: .fast)) { _, _ in
            calls += 1
            throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
        })
        XCTAssertEqual(calls, 1)
    }

    func testRepeatedRecoveriesSkipAccurateUntilCooldownExpires() throws {
        var now: TimeInterval = 0
        let policy = OCRRecoveryPolicy(clock: { now })
        let image = try textImage(lines: ["COOLDOWN RECOVERY"])
        func recognize() throws -> [VNRequestTextRecognitionLevel] {
            var levels: [VNRequestTextRecognitionLevel] = []
            let result = try OCRService.recognizeText(in: image, options: RecognitionOptions(language: "en-US"), policy: policy) { image, request in
                levels.append(request.recognitionLevel)
                XCTAssertEqual(request.recognitionLanguages, ["en-US"])
                if request.recognitionLevel == .accurate { throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1) }
                try VNImageRequestHandler(cgImage: image).perform([request])
            }
            XCTAssertTrue(result.usedCompatibilityEngine)
            XCTAssertTrue(result.usedFastRecovery)
            XCTAssertEqual(result.request.results?.compactMap { $0.topCandidates(1).first?.string }, ["COOLDOWN RECOVERY"])
            return levels
        }
        XCTAssertEqual(try recognize(), [.accurate, .accurate, .fast])
        XCTAssertEqual(try recognize(), [.accurate, .accurate, .fast])
        now = 30
        XCTAssertEqual(try recognize(), [.fast])
        now = 60
        XCTAssertEqual(try recognize(), [.accurate, .accurate, .fast])
    }

    func testAccurateSuccessClearsRecoveredFailureStreak() throws {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        let options = RecognitionOptions(language: "en-US")
        let key = OCRRecoveryPolicy.Configuration(language: options.language, revision: VNRecognizeTextRequest.defaultRevision)
        policy.recordRecoveredComputeFailure(for: key)
        let result = try OCRService.recognizeText(in: textImage(), options: options, policy: policy) { _, request in
            XCTAssertEqual(request.recognitionLevel, .accurate)
        }
        XCTAssertFalse(result.usedFastRecovery)
        XCTAssertEqual(policy.configurationCount, 0)
        policy.recordRecoveredComputeFailure(for: key)
        XCTAssertFalse(policy.shouldUseFast(for: key))
    }

    func testEmptyFastResultNeverActivatesCooldown() throws {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        let image = try textImage()
        for _ in 0..<3 {
            var levels: [VNRequestTextRecognitionLevel] = []
            let result = try OCRService.recognizeText(in: image, options: RecognitionOptions(language: "en-US"), policy: policy) { _, request in
                levels.append(request.recognitionLevel)
                if request.recognitionLevel == .accurate { throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1) }
            }
            XCTAssertEqual(levels, [.accurate, .accurate, .fast])
            XCTAssertNil(result.request.results)
            XCTAssertEqual(policy.configurationCount, 0)
        }
    }

    func testEmptyFastResultDuringCooldownRestoresAccurateProbe() throws {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        let options = RecognitionOptions(language: "en-US")
        let key = OCRRecoveryPolicy.Configuration(language: options.language, revision: VNRecognizeTextRequest.defaultRevision)
        policy.recordRecoveredComputeFailure(for: key)
        policy.recordRecoveredComputeFailure(for: key)
        let result = try OCRService.recognizeText(in: textImage(), options: options, policy: policy) { _, request in
            XCTAssertEqual(request.recognitionLevel, .fast)
        }
        XCTAssertNil(result.request.results)
        XCTAssertFalse(policy.shouldUseFast(for: key))
    }

    func testUnrelatedErrorsAndFailedFastRecoveryBreakFailureStreak() throws {
        let options = RecognitionOptions(language: "en-US")
        let key = OCRRecoveryPolicy.Configuration(language: options.language, revision: VNRecognizeTextRequest.defaultRevision)
        let image = try textImage()
        let errors: [Error] = [OCRServiceError.noContent, NSError(domain: VNErrorDomain, code: VNErrorCode.requestCancelled.rawValue),
                               NSError(domain: "Fixture", code: 9)]
        for error in errors {
            for failFast in [false, true] {
                let policy = OCRRecoveryPolicy(clock: { 0 })
                policy.recordRecoveredComputeFailure(for: key)
                var levels: [VNRequestTextRecognitionLevel] = []
                XCTAssertThrowsError(try OCRService.recognizeText(in: image, options: options, policy: policy) { _, request in
                    levels.append(request.recognitionLevel)
                    if failFast && request.recognitionLevel == .accurate {
                        throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
                    }
                    throw error
                }) {
                    XCTAssertEqual(($0 as NSError).domain, (error as NSError).domain)
                    XCTAssertEqual(($0 as NSError).code, (error as NSError).code)
                }
                XCTAssertEqual(levels, failFast ? [.accurate, .accurate, .fast] : [.accurate])
                XCTAssertEqual(policy.configurationCount, 0)
            }
        }
    }

    func testUnavailableFastLanguageNeverActivatesCooldown() throws {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        for _ in 0..<3 {
            var calls = 0
            XCTAssertThrowsError(try OCRService.recognizeText(in: textImage(), options: RecognitionOptions(language: "ja-JP"), policy: policy) { _, request in
                calls += 1
                XCTAssertEqual(request.recognitionLanguages, ["ja-JP"])
                throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
            }) { XCTAssertEqual(($0 as NSError).domain, "TextRecognition.CRImageReaderError") }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(policy.configurationCount, 0)
        }
    }

    func testCooldownCancellationPropagatesAndRestoresAccurateProbe() throws {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        let options = RecognitionOptions(language: "en-US")
        let key = OCRRecoveryPolicy.Configuration(language: options.language, revision: VNRecognizeTextRequest.defaultRevision)
        policy.recordRecoveredComputeFailure(for: key)
        policy.recordRecoveredComputeFailure(for: key)
        var levels: [VNRequestTextRecognitionLevel] = []
        XCTAssertThrowsError(try OCRService.recognizeText(in: textImage(), options: options, policy: policy) { _, request in
            levels.append(request.recognitionLevel)
            throw NSError(domain: VNErrorDomain, code: VNErrorCode.requestCancelled.rawValue)
        }) {
            XCTAssertEqual(($0 as NSError).code, VNErrorCode.requestCancelled.rawValue)
        }
        XCTAssertEqual(levels, [.fast])
        XCTAssertFalse(policy.shouldUseFast(for: key))
        levels.removeAll()
        _ = try OCRService.recognizeText(in: textImage(), options: options, policy: policy) { _, request in
            levels.append(request.recognitionLevel)
        }
        XCTAssertEqual(levels, [.accurate])
    }

    func testFastPreferenceDoesNotUseOrMutateAccurateCooldown() throws {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        let key = OCRRecoveryPolicy.Configuration(language: "en-US", revision: VNRecognizeTextRequest.defaultRevision)
        policy.recordRecoveredComputeFailure(for: key)
        policy.recordRecoveredComputeFailure(for: key)
        let result = try OCRService.recognizeText(in: textImage(), options: RecognitionOptions(mode: .fast, language: "en-US"), policy: policy) { _, request in
            XCTAssertEqual(request.recognitionLevel, .fast)
        }
        XCTAssertFalse(result.usedCompatibilityEngine)
        XCTAssertFalse(result.usedFastRecovery)
        XCTAssertTrue(policy.shouldUseFast(for: key))
    }

    func testUnsupportedLanguageIsNotReplacedByCachedRecovery() throws {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        let key = OCRRecoveryPolicy.Configuration(language: "en-US", revision: VNRecognizeTextRequest.defaultRevision)
        policy.recordRecoveredComputeFailure(for: key)
        policy.recordRecoveredComputeFailure(for: key)
        var calls = 0
        XCTAssertThrowsError(try OCRService.recognizeText(in: textImage(), options: RecognitionOptions(language: "nonexistent-language"), policy: policy) { _, _ in
            calls += 1
        }) { XCTAssertEqual($0 as? OCRServiceError, .unsupportedLanguage("nonexistent-language")) }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(policy.shouldUseFast(for: key))
    }

    func testFailedAccurateRequestsAreReleasedBeforeNextEngineStarts() throws {
        weak var previousRequest: VNRecognizeTextRequest?
        var levels: [VNRequestTextRecognitionLevel] = []
        let result = try OCRService.recognizeText(in: textImage(lines: ["RELEASED REQUESTS"]), options: RecognitionOptions(language: "en-US")) { image, request in
            XCTAssertNil(previousRequest)
            previousRequest = request
            levels.append(request.recognitionLevel)
            if request.recognitionLevel == .accurate { throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1) }
            try VNImageRequestHandler(cgImage: image).perform([request])
        }
        XCTAssertEqual(levels, [.accurate, .accurate, .fast])
        XCTAssertNotNil(previousRequest)
        XCTAssertTrue(result.usedFastRecovery)
    }
}
