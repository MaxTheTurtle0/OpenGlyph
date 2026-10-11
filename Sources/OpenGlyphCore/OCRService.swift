import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum OCRServiceError: LocalizedError, Equatable {
    case noContent
    case unreadableFile
    case unsupportedFile
    case fileTooLarge
    case imageTooLarge
    case tooManyPages
    case lockedPDF
    case cannotRenderPDF
    case unsupportedLanguage(String)
    case resultTooLarge

    public var errorDescription: String? {
        switch self {
        case .noContent: return "No text or readable barcode was found. Try a larger, sharper selection."
        case .unreadableFile: return "The selected file could not be read."
        case .unsupportedFile: return "Choose a PNG, JPEG, TIFF, HEIC, or PDF file."
        case .fileTooLarge: return "The file exceeds the 100 MB limit."
        case .imageTooLarge: return "The image exceeds the 40 million pixel limit."
        case .tooManyPages: return "The PDF exceeds the 100 page limit."
        case .lockedPDF: return "This PDF is password protected. Unlock it before recognizing text."
        case .cannotRenderPDF: return "A page in this PDF could not be rendered."
        case .unsupportedLanguage(let language): return "The selected recognition mode does not support \(language)."
        case .resultTooLarge: return "The recognized text exceeds the 1 million character limit."
        }
    }
}

public enum OCRService {
    public static let maximumFileBytes = 100 * 1024 * 1024
    public static let maximumImagePixels = 40_000_000
    public static let maximumPDFPages = 100
    private static let maximumResultCharacters = 1_000_000
    private static let maximumDecodedDimension = 8_192

    public static func recognize(image: CGImage, options: RecognitionOptions = RecognitionOptions()) throws -> RecognitionResult {
        guard image.width > 0, image.height > 0,
              image.width <= maximumImagePixels / image.height else { throw OCRServiceError.imageTooLarge }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)

        // Decode codes first so printed captions do not replace a QR payload.
        let barcodes = VNDetectBarcodesRequest()
        try handler.perform([barcodes])
        let payloads = inReadingOrder(barcodes.results ?? [])
            .compactMap(\.payloadStringValue).filter { !$0.isEmpty }
        if !payloads.isEmpty {
            let text = payloads.joined(separator: options.keepLineBreaks ? "\n" : " ")
            guard text.count <= maximumResultCharacters else { throw OCRServiceError.resultTooLarge }
            return RecognitionResult(text: text, kind: .qrCode)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.mode == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        if let language = options.language, language != "auto", !language.isEmpty {
            let languages = try request.supportedRecognitionLanguages()
            guard languages.contains(language) else { throw OCRServiceError.unsupportedLanguage(language) }
            request.recognitionLanguages = [language]
        } else {
            request.automaticallyDetectsLanguage = options.mode == .accurate
            // Fast mode cannot detect language automatically; use available
            // preferred languages, with Vision's default when none match.
            if options.mode == .fast {
                let supported = try request.supportedRecognitionLanguages()
                let preferred = Locale.preferredLanguages.compactMap { preferred in
                    supported.first { $0 == preferred || $0.split(separator: "-").first == preferred.split(separator: "-").first }
                }
                var seen = Set<String>()
                if !preferred.isEmpty { request.recognitionLanguages = preferred.filter { seen.insert($0).inserted } }
            }
        }
        try handler.perform([request])
        let lines = inReadingOrder(request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: options.keepLineBreaks ? "\n" : " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OCRServiceError.noContent }
        guard text.count <= maximumResultCharacters else { throw OCRServiceError.resultTooLarge }
        return RecognitionResult(text: text, kind: CaptureItem.webURL(from: text) == nil ? .text : .link)
    }

    public static func recognize(fileURL: URL, options: RecognitionOptions = RecognitionOptions()) throws -> RecognitionResult {
        guard fileURL.isFileURL else { throw OCRServiceError.unreadableFile }
        let values: URLResourceValues
        do { values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
        catch { throw OCRServiceError.unreadableFile }
        guard values.isRegularFile == true else { throw OCRServiceError.unreadableFile }
        guard (values.fileSize ?? 0) <= maximumFileBytes else { throw OCRServiceError.fileTooLarge }

        if fileURL.pathExtension.lowercased() == "pdf" {
            return try recognizePDF(fileURL: fileURL, options: options)
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier,
               UTType.heic.identifier, "public.heif"].contains(identifier),
              CGImageSourceGetCount(source) > 0 else { throw OCRServiceError.unsupportedFile }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= maximumImagePixels / height.intValue else { throw OCRServiceError.imageTooLarge }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDecodedDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // ImageIO applies EXIF rotation and mirroring before Vision sees pixels.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw OCRServiceError.unreadableFile
        }
        return try recognize(image: image, options: options)
    }

    public static func supportedLanguages(mode: RecognitionMode) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = mode == .accurate ? .accurate : .fast
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    private static func recognizePDF(fileURL: URL, options: RecognitionOptions) throws -> RecognitionResult {
        guard let document = CGPDFDocument(fileURL as CFURL) else { throw OCRServiceError.unreadableFile }
        guard document.isUnlocked else { throw OCRServiceError.lockedPDF }
        guard document.numberOfPages <= maximumPDFPages else { throw OCRServiceError.tooManyPages }
        guard document.numberOfPages > 0 else { throw OCRServiceError.noContent }
        var pages: [RecognitionResult] = []
        var characterCount = 0
        for pageNumber in 1...document.numberOfPages {
            try autoreleasepool {
                guard let page = document.page(at: pageNumber) else { throw OCRServiceError.cannotRenderPDF }
                let image = try render(page)
                do {
                    let result = try recognize(image: image, options: options)
                    characterCount += result.text.count
                    guard characterCount <= maximumResultCharacters else { throw OCRServiceError.resultTooLarge }
                    pages.append(result)
                } catch OCRServiceError.noContent {
                    // An empty page does not discard text on the other pages.
                }
            }
        }
        guard !pages.isEmpty else { throw OCRServiceError.noContent }
        if pages.count == 1 { return pages[0] }
        let text = pages.map(\.text).joined(separator: options.keepLineBreaks ? "\n\n" : " ")
        return RecognitionResult(text: text, kind: pages.allSatisfy { $0.kind == .qrCode } ? .qrCode : .text)
    }

    private static func render(_ page: CGPDFPage) throws -> CGImage {
        let bounds = page.getBoxRect(.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw OCRServiceError.cannotRenderPDF
        }
        let rotated = ((Int(page.rotationAngle) % 180) + 180) % 180 == 90
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        // 216 dpi for ordinary pages; reduce exceptionally large pages to cap
        // each bitmap at 24 MP and 6,000 pixels on either side.
        let scale = min(3, 6_000 / max(size.width, size.height), sqrt(24_000_000 / (size.width * size.height)))
        guard scale.isFinite, scale > 0 else { throw OCRServiceError.cannotRenderPDF }
        let width = max(1, Int(floor(size.width * scale)))
        let height = max(1, Int(floor(size.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw OCRServiceError.cannotRenderPDF
        }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw OCRServiceError.cannotRenderPDF }
        return image
    }

    private static func inReadingOrder<T: VNDetectedObjectObservation>(_ observations: [T]) -> [T] {
        // Group nearby baselines before sorting columns. A fuzzy comparator
        // alone would not give Swift's sort a transitive ordering.
        let vertical = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[T]] = []
        for observation in vertical {
            if let first = rows.last?.first,
               abs(first.boundingBox.midY - observation.boundingBox.midY) <= min(first.boundingBox.height, observation.boundingBox.height) * 0.4 {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }
}
