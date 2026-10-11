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
    public let usedCompatibilityEngine: Bool
    public let usedFastRecovery: Bool

    public init(text: String, kind: CaptureKind, usedCompatibilityEngine: Bool = false, usedFastRecovery: Bool = false) {
        self.text = text
        self.kind = kind
        self.usedCompatibilityEngine = usedCompatibilityEngine
        self.usedFastRecovery = usedFastRecovery
    }
}
