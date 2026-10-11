import Carbon.HIToolbox
import Combine
import Foundation

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    public static let defaultCapture = KeyboardShortcut(keyCode: 19, modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧2")
}

@MainActor
public final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private static let prefix = "OpenGlyph."

    @Published public var mode: RecognitionMode { didSet { persist(mode.rawValue, "mode") } }
    @Published public var language: String { didSet { persist(language, "language") } }
    @Published public var keepLineBreaks: Bool { didSet { persist(keepLineBreaks, "keepLineBreaks") } }
    @Published public var autoOpenQRLinks: Bool { didSet { persist(autoOpenQRLinks, "autoOpenQRLinks") } }
    @Published public var saveHistory: Bool { didSet { persist(saveHistory, "saveHistory") } }
    @Published public var launchAtLogin: Bool { didSet { persist(launchAtLogin, "launchAtLogin") } }
    @Published public var shortcut: KeyboardShortcut {
        didSet { if let encoded = try? JSONEncoder().encode(shortcut) { persist(encoded, "shortcut") } }
    }
    @Published public var onboardingCompleted: Bool { didSet { persist(onboardingCompleted, "onboardingCompleted") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func object(_ key: String) -> Any? { defaults.object(forKey: Self.prefix + key) }
        mode = (object("mode") as? String).flatMap(RecognitionMode.init(rawValue:)) ?? .accurate
        language = object("language") as? String ?? "auto"
        keepLineBreaks = object("keepLineBreaks") as? Bool ?? true
        autoOpenQRLinks = object("autoOpenQRLinks") as? Bool ?? false
        saveHistory = object("saveHistory") as? Bool ?? true
        launchAtLogin = object("launchAtLogin") as? Bool ?? false
        shortcut = (object("shortcut") as? Data).flatMap { try? JSONDecoder().decode(KeyboardShortcut.self, from: $0) } ?? .defaultCapture
        onboardingCompleted = object("onboardingCompleted") as? Bool ?? false
    }

    public var recognitionOptions: RecognitionOptions {
        RecognitionOptions(mode: mode, language: language == "auto" ? nil : language, keepLineBreaks: keepLineBreaks)
    }

    private func persist(_ value: Any, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
    }
}
