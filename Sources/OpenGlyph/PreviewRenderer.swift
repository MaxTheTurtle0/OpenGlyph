import AppKit
import OpenGlyphCore
import SwiftUI

@MainActor
enum PreviewRenderer {
    private static var renderScheme: ColorScheme = .light
    static func render(to directory: URL, dark: Bool = false) throws {
        renderScheme = dark ? .dark : .light
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let controller = AppController()
        let suite = "app.openglyph.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let history = HistoryStore(directory: directory.appendingPathComponent("temporary-history"))
        history.add(CaptureItem(text: "Ship the release on Friday.\nFreeze the branch Thursday at noon.", kind: .text, source: "Preview"))
        history.add(CaptureItem(text: "https://github.com/MaxTheTurtle0/OpenGlyph", kind: .link, source: "Safari"))
        history.add(CaptureItem(text: "https://example.com/join", kind: .qrCode, source: "Screen"))
        try snapshot(MenuView(controller: controller, settings: settings, history: history), size: NSSize(width: 390, height: 540), file: directory.appendingPathComponent("menu.png"))
        try snapshot(SettingsView(controller: controller, settings: settings), size: NSSize(width: 580, height: 650), file: directory.appendingPathComponent("settings.png"))
        for step in 0..<3 {
            try snapshot(OnboardingView(controller: controller, settings: settings, initialStep: step), size: NSSize(width: 660, height: 580), file: directory.appendingPathComponent("onboarding-\(step).png"))
        }
        try snapshot(CaptureDetailView(item: history.items[0], copy: {}), size: NSSize(width: 620, height: 430), file: directory.appendingPathComponent("detail.png"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("temporary-history"))
    }
    private static func snapshot<V: View>(_ root: V, size: NSSize, file: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, renderScheme))
        window.setContentSize(size)
        window.appearance = NSAppearance(named: renderScheme == .dark ? .darkAqua : .aqua)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let view = window.contentView else { throw CocoaError(.fileWriteUnknown) }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: file)
        window.orderOut(nil)
        window.close()
        print(file.path)
    }
}
