import Foundation

public enum RecognitionMode: String, Codable, CaseIterable, Sendable {
    case accurate, fast
}

public struct RecognitionOptions: Sendable {
    public var mode: RecognitionMode
    public var language: String?
    public var keepLineBreaks: Bool

    public init(mode: RecognitionMode = .accurate, language: String? = nil, keepLineBreaks: Bool = true) {
        self.mode = mode
        self.language = language
        self.keepLineBreaks = keepLineBreaks
    }
}

public struct RecognitionResult: Equatable, Sendable {
    public let text: String
    public let kind: CaptureKind

    public init(text: String, kind: CaptureKind) {
        self.text = text
        self.kind = kind
    }
}
