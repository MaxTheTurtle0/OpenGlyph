import Foundation

public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case text, link, qrCode

    public var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .qrCode: return "QR / barcode"
        }
    }
}

public struct CaptureItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let kind: CaptureKind
    public let source: String
    public let createdAt: Date

    public init(text: String, kind: CaptureKind, source: String, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.kind = kind
        self.source = source
        self.createdAt = createdAt
    }

    /// Only web links are opened by the app. Other barcode payloads stay as text.
    public var linkURL: URL? { Self.webURL(from: text) }

    public static func webURL(from text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            return nil
        }
        let explicitScheme = value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        let candidate = explicitScheme ? value : "https://" + value
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }

        // A bare string must look like a domain. This also rejects mailto:, tel:,
        // javascript:, Windows paths, and normal OCR prose without opening them.
        if !explicitScheme {
            guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        }
        guard !host.contains("\\"), !host.contains("%"), !host.contains(".."),
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return url
    }
}
