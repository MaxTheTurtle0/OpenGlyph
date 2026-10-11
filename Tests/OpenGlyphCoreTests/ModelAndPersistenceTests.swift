import Foundation
import XCTest
@testable import OpenGlyphCore

final class CaptureItemTests: XCTestCase {
    func testOnlyWebLinksCanOpen() {
        let valid = [
            "https://example.com/a?search=hello#section": "https://example.com/a?search=hello#section",
            "http://example.com": "http://example.com",
            "example.com/path": "https://example.com/path",
            "www.example.com": "https://www.example.com",
            "example.com:8080/path": "https://example.com:8080/path",
            "  https://example.com  ": "https://example.com"
        ]
        for (value, expected) in valid {
            XCTAssertEqual(CaptureItem(text: value, kind: .link, source: "Test").linkURL?.absoluteString, expected, value)
        }
        for value in ["javascript:alert(1)", "file:///etc/passwd", "mailto:user@example.com", "tel:123456",
                      "https://user:password@example.com", "two words.example", "https://example.com\nsecond line",
                      "localhost", "plain text", "https://", ".example.com", "example..com", "example.com:99999"] {
            XCTAssertNil(CaptureItem(text: value, kind: .qrCode, source: "Test").linkURL, value)
        }
    }

    func testCodablePreservesCaptureIdentityAndTimestamp() throws {
        let item = CaptureItem(text: "Example", kind: .text, source: "Finder", createdAt: Date(timeIntervalSince1970: 1234567890.125))
        XCTAssertEqual(try JSONDecoder().decode(CaptureItem.self, from: JSONEncoder().encode(item)), item)
    }
}

final class HistoryStoreTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OpenGlyphHistoryTests-\(UUID())", isDirectory: true)
    }

    @MainActor
    func testPersistsFiltersRemovesAndClears() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let text = CaptureItem(text: "Hello WORLD", kind: .text, source: "Safari")
        let link = CaptureItem(text: "example.com", kind: .link, source: "Preview")
        store.add(text)
        store.add(link)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.items, [link, text])
        XCTAssertEqual(HistoryStore(directory: directory).items, [link, text])
        XCTAssertEqual(store.filtered(query: "world", kind: nil), [text])
        XCTAssertEqual(store.filtered(query: "preview", kind: .link), [link])
        XCTAssertTrue(store.filtered(query: "world", kind: .link).isEmpty)
        store.remove(link)
        XCTAssertEqual(HistoryStore(directory: directory).items, [text])
        store.clear()
        XCTAssertTrue(HistoryStore(directory: directory).items.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testBoundsHistoryAndReplacesDuplicateIdentifier() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        var last: CaptureItem!
        for number in 0..<505 {
            last = CaptureItem(text: "Capture \(number)", kind: .text, source: "Test")
            store.add(last)
        }
        XCTAssertEqual(store.items.count, 500)
        XCTAssertEqual(store.items.first?.text, "Capture 504")
        XCTAssertEqual(store.items.last?.text, "Capture 5")
        store.add(last)
        XCTAssertEqual(store.items.count, 500)
        XCTAssertEqual(HistoryStore(directory: directory).items, store.items)
    }

    @MainActor
    func testCorruptHistoryReportsErrorWithoutCrashing() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is not JSON".utf8).write(to: directory.appendingPathComponent("history.json"))
        let store = HistoryStore(directory: directory)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("history.json")), "this is not JSON")
    }

    @MainActor
    func testFailedSaveDoesNotPretendCaptureWasPersisted() async throws {
        let blockedDirectory = directory()
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        try Data("a file occupies this directory path".utf8).write(to: blockedDirectory)
        let store = HistoryStore(directory: blockedDirectory)
        store.add(CaptureItem(text: "Unsaved text", kind: .text, source: "Test"))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testOversizedCaptureIsRejected() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        store.add(CaptureItem(text: String(repeating: "a", count: HistoryStore.maximumTextLength + 1), kind: .text, source: "Test"))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.lastError)
    }
}

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testDefaultsAndPersistence() async throws {
        let suite = "OpenGlyphSettingsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.mode, .accurate)
        XCTAssertEqual(settings.language, "auto")
        XCTAssertTrue(settings.keepLineBreaks)
        XCTAssertTrue(settings.saveHistory)
        XCTAssertFalse(settings.autoOpenQRLinks)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(settings.onboardingCompleted)
        XCTAssertEqual(settings.shortcut, .defaultCapture)
        XCTAssertNil(settings.recognitionOptions.language)

        settings.mode = .fast
        settings.language = "de-DE"
        settings.keepLineBreaks = false
        settings.autoOpenQRLinks = true
        settings.saveHistory = false
        settings.launchAtLogin = true
        settings.onboardingCompleted = true
        settings.shortcut = KeyboardShortcut(keyCode: 3, modifiers: 256, display: "⌘F")
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .fast)
        XCTAssertEqual(reloaded.language, "de-DE")
        XCTAssertFalse(reloaded.keepLineBreaks)
        XCTAssertTrue(reloaded.autoOpenQRLinks)
        XCTAssertFalse(reloaded.saveHistory)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertTrue(reloaded.onboardingCompleted)
        XCTAssertEqual(reloaded.shortcut, settings.shortcut)
        XCTAssertEqual(reloaded.recognitionOptions.language, "de-DE")
        XCTAssertFalse(reloaded.recognitionOptions.keepLineBreaks)
    }
}
