import AppKit
import Combine
import CoreGraphics
import OpenGlyphCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = AppSettings()
    let history = HistoryStore()
    let capture = CaptureCoordinator()
    let hotKey = GlobalHotKey()
    @Published var busy = false
    @Published var loginNeedsApproval = false
    @Published var errorMessage: String?
    @Published var shortcutError: String?
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var detailWindow: NSWindow?
    private var toastWindow: NSPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var activeShortcut: OpenGlyphCore.KeyboardShortcut?
    private var revertingShortcut = false
    private var loginChangeInProgress = false
    private var lastExternalApplication = NSWorkspace.shared.frontmostApplication
    private var lastSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Screen"

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "OpenGlyph")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "OpenGlyph · Copy text from your screen"
        }
        popover = NSPopover()
        popover.contentSize = NSSize(width: 390, height: 540)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(controller: self, settings: settings, history: history))
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification).sink { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            DispatchQueue.main.async { self?.lastSourceApp = app.localizedName ?? "Screen"; self?.lastExternalApplication = app }
        }.store(in: &subscriptions)
        registerShortcut()
        NotificationCenter.default.publisher(for: ShortcutButton.recordingBegan).sink { [weak self] _ in
            self?.hotKey.unregister()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: ShortcutButton.recordingEnded).sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerShortcut() }
        }.store(in: &subscriptions)
        settings.$shortcut.dropFirst().sink { [weak self] _ in
            guard !ShortcutButton.isRecordingShortcut else { return }
            DispatchQueue.main.async { self?.registerShortcut() }
        }.store(in: &subscriptions)
        reconcileLoginStatus()
        settings.$launchAtLogin.dropFirst().sink { [weak self] value in
            DispatchQueue.main.async { self?.setLoginItem(value) }
        }.store(in: &subscriptions)
        if settings.onboardingCompleted { showPopover() } else { showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) { hotKey.unregister(); capture.cancel() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    func showPopover() {
        guard let button = statusItem?.button, popover != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func dismissPopover() { popover?.performClose(nil) }

    private func installApplicationMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "OpenGlyph")
        applicationMenu.addItem(withTitle: "About OpenGlyph", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let settingsItem = applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit OpenGlyph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
    private func registerShortcut() {
        guard !ShortcutButton.isRecordingShortcut else { return }
        if revertingShortcut { revertingShortcut = false; return }
        do {
            try hotKey.register(settings.shortcut) { [weak self] in self?.startCapture() }
            activeShortcut = settings.shortcut
            shortcutError = nil
        } catch {
            shortcutError = error.localizedDescription
            if let activeShortcut, settings.shortcut != activeShortcut {
                try? hotKey.register(activeShortcut) { [weak self] in self?.startCapture() }
                revertingShortcut = true
                settings.shortcut = activeShortcut
            }
        }
    }
    func reconcileLoginStatus() {
        let status = SMAppService.mainApp.status
        loginNeedsApproval = status == .requiresApproval
        let enabled = status == .enabled || status == .requiresApproval
        if settings.launchAtLogin != enabled {
            loginChangeInProgress = true
            settings.launchAtLogin = enabled
            DispatchQueue.main.async { self.loginChangeInProgress = false }
        }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func setLoginItem(_ enabled: Bool) {
        guard !loginChangeInProgress else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        } catch {
            errorMessage = "Could not change launch at login: \(error.localizedDescription)"
            loginChangeInProgress = true
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async { self.loginChangeInProgress = false }
        }
    }

    func startCapture() {
        guard !busy, !capture.isSelecting, !ShortcutButton.isRecordingShortcut else { return }
        let source = lastSourceApp
        let fromPopover = popover?.isShown == true
        dismissPopover()
        if fromPopover { lastExternalApplication?.activate(options: []) }
        errorMessage = nil
        if !CaptureCoordinator.hasPermission {
            showOnboarding(permissionStep: true)
            return
        }
        busy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.capture.startCapture { result in
                guard let result else { self.busy = false; return }
                switch result {
                case .success(let image): self.recognizeImage(image, source: source)
                case .failure(let error): self.fail(error)
                }
            }
        }
    }
    func importClipboard() {
        guard !busy else { return }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
            recognizeFile(url)
        } else if let image = NSImage(pasteboard: pasteboard), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            busy = true; errorMessage = nil; dismissPopover(); recognizeImage(cg, source: "Clipboard")
        } else {
            errorMessage = "Copy an image or a file first. The clipboard currently has no image."
        }
    }
    func openFile() {
        guard !busy else { return }
        dismissPopover()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Read text or codes from an image or PDF."
        panel.prompt = "Read text"
        if panel.runModal() == .OK, let url = panel.url { recognizeFile(url) }
    }
    private func recognizeImage(_ image: CGImage, source: String) {
        let options = settings.recognitionOptions
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try OCRService.recognize(image: image, options: options) }.value
                finish(result, source: source)
            } catch { fail(error) }
        }
    }
    func recognizeFile(_ url: URL) {
        guard !busy else { return }
        busy = true; errorMessage = nil; dismissPopover()
        let options = settings.recognitionOptions
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try OCRService.recognize(fileURL: url, options: options) }.value
                finish(result, source: url.lastPathComponent)
            } catch { fail(error) }
        }
    }
    private func finish(_ result: RecognitionResult, source: String) {
        busy = false
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "No text or code found. Try a larger, clearer selection."
            showToast(title: "No text found", text: "Try a larger, clearer selection.", success: false)
            return
        }
        let item = CaptureItem(text: result.text, kind: result.kind, source: source)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.text, forType: .string)
        if settings.saveHistory { history.add(item) }
        showToast(title: result.kind == .qrCode ? "Code copied" : "Copied to clipboard", text: result.text, success: true)
        if result.kind == .qrCode, settings.autoOpenQRLinks, let url = item.linkURL { NSWorkspace.shared.open(url) }
    }
    private func fail(_ error: Error) {
        busy = false; errorMessage = error.localizedDescription
        showToast(title: "Couldn't read text", text: error.localizedDescription, success: false)
    }
    func copy(_ item: CaptureItem) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string)
        dismissPopover()
        showToast(title: "Copied to clipboard", text: item.text, success: true)
    }
    func openLink(_ item: CaptureItem) { if let url = item.linkURL { NSWorkspace.shared.open(url) } }
    func showDetail(_ item: CaptureItem) {
        dismissPopover()
        detailWindow?.close()
        let view = CaptureDetailView(item: item, copy: { [weak self] in self?.copy(item) })
        let window = makeWindow(title: "Capture · OpenGlyph", size: NSSize(width: 620, height: 430), root: view)
        detailWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showSettings() {
        dismissPopover()
        if let window = settingsWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = makeWindow(title: "OpenGlyph Settings", size: NSSize(width: 580, height: 650), root: SettingsView(controller: self, settings: settings))
        settingsWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showOnboarding(permissionStep: Bool = false) {
        dismissPopover()
        onboardingWindow?.close()
        let window = makeWindow(title: "Welcome to OpenGlyph", size: NSSize(width: 660, height: 580), root: OnboardingView(controller: self, settings: settings, initialStep: permissionStep ? 1 : 0))
        window.styleMask.remove(.resizable)
        onboardingWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func completeOnboarding() {
        settings.onboardingCompleted = true
        onboardingWindow?.close()
        showPopover()
    }
    func requestPermission() { _ = CaptureCoordinator.requestPermission(); CaptureCoordinator.openPermissionSettings() }
    func quit() { NSApp.terminate(nil) }

    private func makeWindow<V: View>(title: String, size: NSSize, root: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.center()
        window.contentViewController = NSHostingController(rootView: root)
        window.minSize = size
        return window
    }
    private func showToast(title: String, text: String, success: Bool) {
        toastWindow?.orderOut(nil)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let panel = NSPanel(contentRect: NSRect(x: frame.midX - 210, y: frame.minY + 48, width: 420, height: 98), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ToastView(title: title, text: text, success: success))
        toastWindow = panel; panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.toastWindow === panel { self?.toastWindow = nil }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL { recognizeFile(url); continue }
            guard url.scheme?.lowercased() == "openglyph" else { continue }
            switch url.host?.lowercased() {
            case "capture": startCapture()
            case "clipboard": importClipboard()
            case "settings": showSettings()
            case "onboarding": showOnboarding()
            case "history": showPopover()
            default: break
            }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first { recognizeFile(URL(fileURLWithPath: first)) }
        sender.reply(toOpenOrPrint: .success)
    }
}
