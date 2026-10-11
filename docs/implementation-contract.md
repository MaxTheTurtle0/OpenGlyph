# Implementation contract

Native macOS 14+, Swift package, language mode Swift 5. Shared source directory. Each agent owns its assigned files and must not edit another agent's files.

## Core target owned by core agent

Public types in OpenGlyphCore:
- enum CaptureKind: String, Codable, CaseIterable { case text, link, qrCode }. label: String.
- struct CaptureItem: Identifiable, Codable, Equatable. id: UUID, text: String, kind: CaptureKind, source: String, createdAt: Date. init(text:kind:source:). Optional defaults for id/date. linkURL: URL? accepts only http/https URLs, including bare domains normalized to https.
- struct RecognitionOptions: Sendable with init(mode: RecognitionMode = .accurate, language: String? = nil, keepLineBreaks: Bool = true). enum RecognitionMode: String, Codable, CaseIterable, Sendable { case accurate, fast }.
- struct RecognitionResult: text: String, kind: CaptureKind. Sendable where possible.
- enum OCRService with static func recognize(image: CGImage, options: RecognitionOptions) throws -> RecognitionResult; static func recognize(fileURL: URL, options: RecognitionOptions) throws -> RecognitionResult; static func supportedLanguages(mode: RecognitionMode) -> [String]. Synchronous, caller runs off main thread. Supports image orientation, PNG/JPEG/TIFF/HEIC, PDF all pages rendered at OCR resolution, QR/barcodes first. Reasonable resource limits and explicit errors.
- @MainActor final class HistoryStore: ObservableObject. @Published public private(set) var items: [CaptureItem]. init(directory: URL? = nil). func add(_ item: CaptureItem), remove(_ item: CaptureItem), clear(), filtered(query: String, kind: CaptureKind?) -> [CaptureItem]. Local JSON atomic writes, bounded 500 entries. Errors exposed via @Published lastError: String?. init supports isolated test directory.
- struct KeyboardShortcut: Codable, Equatable, Sendable with keyCode: UInt32, modifiers: UInt32, display: String; static let defaultCapture = key code 19, Carbon cmdKey+shiftKey, display "⌘⇧2".
- @MainActor final class AppSettings: ObservableObject. init(defaults: UserDefaults = .standard). @Published properties mode: RecognitionMode, language: String ("auto" default), keepLineBreaks: Bool (true), autoOpenQRLinks: Bool (false), saveHistory: Bool (true), launchAtLogin: Bool (false), shortcut: KeyboardShortcut (.defaultCapture), onboardingCompleted: Bool (false). Computed recognitionOptions. Persist settings on mutation.
- Useful tests in Tests/OpenGlyphCoreTests; generate image/QR/PDF fixtures locally.

## Capture target files owned by capture agent

Only Sources/OpenGlyph/CaptureCoordinator.swift, Sources/OpenGlyph/GlobalHotKey.swift, plus Tests/OpenGlyphCoreTests/CaptureGeometryTests.swift if geometry belongs in Core as CaptureGeometry.swift.
- @MainActor final class CaptureCoordinator: ObservableObject. @Published private(set) var isSelecting: Bool. static var hasPermission: Bool { get }; static func requestPermission() -> Bool; static func openPermissionSettings(); func startCapture(completion: @escaping (Result<CGImage, Error>?) -> Void); func cancel(). nil result means cancelled. Uses frozen per-display snapshots BEFORE overlay, ScreenCaptureKit, all connected displays, Retina aware crop, ESC and right click cancel, reject tiny selections. Don't persist pixels. Capture screen source app name handled by parent BEFORE activating overlay.
- @MainActor final class GlobalHotKey. init(); func register(_ shortcut: KeyboardShortcut, handler: @escaping () -> Void) throws; func unregister(). Carbon RegisterEventHotKey without Accessibility permission. Conflict errors surfaced. Handler runs main actor.

## Parent-owned app files

Main.swift, AppController.swift, views, onboarding, settings, popover history, notifications, URL routing, CLI OCR modes, resources, build/install scripts, docs/CI.
