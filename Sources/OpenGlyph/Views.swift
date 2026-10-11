import AppKit
import Carbon
import OpenGlyphCore
import SwiftUI

private let glyphBlue = Color(red: 0.16, green: 0.31, blue: 0.88)

private struct GlyphPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 17).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(glyphBlue.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct MenuView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @State private var query = ""
    @State private var filter: CaptureKind?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "text.viewfinder").font(.system(size: 22, weight: .medium)).foregroundStyle(glyphBlue)
                Text("OpenGlyph").font(.system(size: 17, weight: .semibold))
                Spacer()
                if controller.busy { ProgressView().controlSize(.small).accessibilityLabel("Reading text") }
                Button(action: controller.showSettings) { Image(systemName: "gearshape").font(.system(size: 15)) }.buttonStyle(.plain).help("Settings")
                Menu {
                    Button("Welcome & permissions", action: { controller.showOnboarding() })
                    Button("View source on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/MaxTheTurtle0/OpenGlyph")!) }
                    Divider()
                    Button("Quit OpenGlyph", action: controller.quit).keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }.menuStyle(.borderlessButton).frame(width: 22)
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
            Button(action: controller.startCapture) {
                HStack(spacing: 11) {
                    Image(systemName: "viewfinder").font(.system(size: 25, weight: .light))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.busy ? "Reading text…" : "Copy text").font(.system(size: 16, weight: .semibold))
                        Text("Drag over anything on screen").font(.system(size: 11)).opacity(0.82)
                    }
                    Spacer(minLength: 4)
                    Text(settings.shortcut.display).font(.system(size: 13, weight: .medium, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 6).background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                }.foregroundStyle(.white).padding(15).background(glyphBlue.gradient, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(controller.busy).padding(.horizontal, 14)
            HStack(spacing: 9) {
                actionButton("From clipboard", symbol: "clipboard", action: controller.importClipboard)
                actionButton("Open image or PDF", symbol: "photo", action: controller.openFile)
            }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
            if let message = controller.errorMessage ?? controller.shortcutError ?? history.lastError {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { controller.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 14).padding(.bottom, 10)
            } else if let notice = controller.recognitionNotice {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle").foregroundStyle(glyphBlue)
                    Text(notice).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { controller.recognitionNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(glyphBlue.opacity(0.07), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 14).padding(.bottom, 10)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history…", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(9).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 14)
            HStack(spacing: 4) {
                filterButton("All", kind: nil)
                filterButton("Text", kind: .text)
                filterButton("Links", kind: .link)
                filterButton("Codes", kind: .qrCode)
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            let items = history.filtered(query: query, kind: filter)
            if items.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: history.items.isEmpty ? "text.viewfinder" : "magnifyingglass").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(history.items.isEmpty ? "Your captures will appear here" : "No matching captures").font(.system(size: 13, weight: .medium))
                    Text(history.items.isEmpty ? "Select text on screen, read a copied image,\nor open an image or PDF." : "Try another search or filter.").font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if !settings.saveHistory { Text("History is turned off in Settings.").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            CaptureRow(item: item, controller: controller, history: history)
                            Divider().padding(.leading, 14)
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Image(systemName: "lock.shield").font(.system(size: 10))
                Text("On-device · Private").font(.system(size: 10))
                Spacer()
                Button("Clear history") { confirmClear = true }.buttonStyle(.plain).font(.system(size: 10)).disabled(history.items.isEmpty)
            }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
        }.frame(width: 390, height: 540).background(Color(nsColor: .windowBackgroundColor))
        .alert("Clear capture history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear history", role: .destructive) { history.clear() }
        } message: { Text("This removes all saved captures from this Mac.") }
    }
    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(controller.busy)
    }
    private func filterButton(_ title: String, kind: CaptureKind?) -> some View {
        let count = kind.map { k in history.items.filter { $0.kind == k }.count } ?? history.items.count
        return Button { filter = kind } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").font(.system(size: 9)).opacity(0.65)
            }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(filter == kind ? glyphBlue : .secondary)
                .background(filter == kind ? glyphBlue.opacity(0.1) : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct CaptureRow: View {
    let item: CaptureItem
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @State private var hovering = false
    var body: some View {
        Button { controller.copy(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.kind == .qrCode ? "qrcode" : item.kind == .link ? "link" : "text.alignleft").foregroundStyle(item.kind == .text ? Color.secondary : glyphBlue).font(.system(size: 12)).frame(width: 15).padding(.top, 2)
                    Text(item.text).font(.system(size: 12)).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    if hovering { Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    Text(item.source).lineLimit(1)
                    Text("·")
                    Text(item.createdAt, style: .relative)
                    Spacer()
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 23)
            }.padding(.horizontal, 15).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).background(hovering ? Color.primary.opacity(0.035) : .clear)
        }.buttonStyle(.plain).onHover { hovering = $0 }.help("Click to copy")
        .contextMenu {
            Button("Copy", action: { controller.copy(item) })
            Button("View full text", action: { controller.showDetail(item) })
            if item.linkURL != nil { Button("Open link", action: { controller.openLink(item) }) }
            Divider()
            Button("Delete", role: .destructive, action: { history.remove(item) })
        }
    }
}

struct CaptureDetailView: View {
    let item: CaptureItem
    let copy: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.kind.label).font(.title2.weight(.semibold))
                    Text("\(item.source) · \(item.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy text", action: copy).buttonStyle(GlyphPrimaryButtonStyle()).keyboardShortcut("c", modifiers: .command)
            }
            ScrollView { Text(item.text).font(.system(size: 14, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }.padding(24).frame(minWidth: 620, minHeight: 430)
    }
}

struct ToastView: View {
    let title: String
    let text: String
    let success: Bool
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill").font(.system(size: 27)).foregroundStyle(success ? glyphBlue : .orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(width: 420, height: 98).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    @State private var permission = CaptureCoordinator.hasPermission
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "text.viewfinder").font(.system(size: 30)).foregroundStyle(glyphBlue)
                VStack(alignment: .leading, spacing: 3) { Text("OpenGlyph").font(.title2.weight(.semibold)); Text("Text from your screen. On your Mac.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            Form {
                Section("Capture") {
                    HStack { Text("Global shortcut"); Spacer(); ShortcutRecorder(shortcut: $settings.shortcut).frame(width: 170, height: 28) }
                    if let error = controller.shortcutError { Text(error).foregroundStyle(.red).font(.caption) }
                    Picker("Recognition", selection: $settings.mode) { Text("Accurate").tag(RecognitionMode.accurate); Text("Fast").tag(RecognitionMode.fast) }
                    Picker("Language", selection: $settings.language) {
                        Text("Detect automatically").tag("auto")
                        ForEach(OCRService.supportedLanguages(mode: settings.mode), id: \.self) { code in
                            Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                        }
                    }
                    Toggle("Keep line breaks", isOn: $settings.keepLineBreaks)
                    Toggle("Open web links from QR codes automatically", isOn: $settings.autoOpenQRLinks)
                }
                Section("History & startup") {
                    Toggle("Save capture history on this Mac", isOn: $settings.saveHistory)
                    Text("Up to 500 text captures stay on this Mac. Images are never saved. Turning history off keeps existing captures until you clear them.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    if controller.loginNeedsApproval {
                        HStack {
                            Text("Approval required in macOS Login Items.").font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Open Login Items", action: controller.openLoginSettings)
                        }
                    }
                }
                Section("Screen Recording") {
                    HStack {
                        Label(permission ? "Permission granted" : "Permission needed for screen capture", systemImage: permission ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(permission ? Color.green : .orange)
                        Spacer()
                        Button("Open System Settings", action: CaptureCoordinator.openPermissionSettings)
                    }
                    Text("OpenGlyph reads screen pixels only when you request a capture. Image, PDF, and clipboard imports work without this permission.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = controller.errorMessage { Section { Text(error).font(.caption).foregroundStyle(.red) } }
            }.formStyle(.grouped)
            HStack {
                Label("Apple Vision · Offline · MIT license", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("Source code", destination: URL(string: "https://github.com/MaxTheTurtle0/OpenGlyph")!).font(.caption)
            }.padding(18)
        }.frame(minWidth: 580, minHeight: 650).background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: settings.mode) { _, newMode in
                if settings.language != "auto" && !OCRService.supportedLanguages(mode: newMode).contains(settings.language) { settings.language = "auto" }
            }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in permission = CaptureCoordinator.hasPermission; controller.reconcileLoginStatus() }
    }
}

struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    let initialStep: Int
    @State private var step = 0
    @State private var permission = CaptureCoordinator.hasPermission
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("OpenGlyph", systemImage: "text.viewfinder").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(step + 1) of 3").font(.caption).opacity(0.8)
            }.foregroundStyle(.white).padding(.horizontal, 30).padding(.top, 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(step == 0 ? "Copy what you see." : step == 1 ? "One permission." : "Make it a habit.")
                    .font(.system(size: 40, weight: .semibold)).tracking(-1)
                Text(step == 0 ? "Paste it anywhere." : step == 1 ? "Your screen stays yours." : "Select. Copy. Paste.")
                    .font(.system(size: 34, weight: .regular, design: .serif)).italic().opacity(0.9)
            }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(30).padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 20) {
                if step == 0 {
                    Text("A video, a scanned PDF, a screenshot, a shared screen. If there is text in it, OpenGlyph can read it.").font(.system(size: 16)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 24) {
                        benefit("On-device OCR", symbol: "cpu")
                        benefit("QR & barcodes", symbol: "qrcode")
                        benefit("Free & open source", symbol: "curlybraces")
                    }.padding(.vertical, 10)
                    Text("No account, no license key, no network request. Text recognition runs with Apple Vision.").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if step == 1 {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 30)).foregroundStyle(glyphBlue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Screen Recording").font(.system(size: 16, weight: .semibold))
                            Text(permission ? "Permission granted. You're ready." : "Required to read the region you select.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: permission ? "checkmark.circle.fill" : "lock.circle").font(.system(size: 23)).foregroundStyle(permission ? Color.green : glyphBlue)
                    }.padding(18).background(glyphBlue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    Text("macOS calls this Screen Recording. OpenGlyph takes a still snapshot only when you start a capture. It never records video or sends your screen anywhere.").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !permission { Button("Grant permission in System Settings", action: controller.requestPermission).buttonStyle(GlyphPrimaryButtonStyle()) }
                    Text("You can use image, PDF, and clipboard imports right away.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack { Text("Copy text").font(.system(size: 15, weight: .medium)); Spacer(); ShortcutRecorder(shortcut: $settings.shortcut).frame(width: 170, height: 30) }
                    if let error = controller.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Try capturing this text").font(.system(size: 11, weight: .semibold)).foregroundStyle(glyphBlue)
                        Text("Good tools save a little time,\na hundred times a day.").font(.system(size: 21, design: .serif))
                        Text("OpenGlyph reads text right on your Mac.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(glyphBlue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    Text("Press \(settings.shortcut.display), drag over text, then paste with ⌘V. Escape cancels a selection.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack {
                    if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    Spacer()
                    if step == 1 && !permission { Button("Set up later") { step = 2 }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    Button(step == 2 ? "Start using OpenGlyph" : "Continue") {
                        if step == 2 { controller.completeOnboarding() } else { step += 1 }
                    }.buttonStyle(GlyphPrimaryButtonStyle()).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
        }.frame(width: 660, height: 580).background(glyphBlue.gradient)
        .onAppear { step = initialStep }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in permission = CaptureCoordinator.hasPermission }
    }
    private func benefit(_ text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(glyphBlue); Text(text).font(.system(size: 12, weight: .medium)) }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: OpenGlyphCore.KeyboardShortcut
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.onChange = { shortcut = $0 }
        button.shortcut = shortcut
        button.target = button; button.action = #selector(ShortcutButton.beginRecording)
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.shortcut = shortcut
        button.onChange = { shortcut = $0 }
        if !button.recording { button.title = shortcut.display }
    }
}

final class ShortcutButton: NSButton {
    var shortcut = OpenGlyphCore.KeyboardShortcut.defaultCapture
    var onChange: ((OpenGlyphCore.KeyboardShortcut) -> Void)?
    static let recordingBegan = Notification.Name("OpenGlyphShortcutRecordingBegan")
    static let recordingEnded = Notification.Name("OpenGlyphShortcutRecordingEnded")
    private static weak var currentRecorder: ShortcutButton?
    static var isRecordingShortcut: Bool { currentRecorder?.recording == true }
    var recording = false {
        didSet {
            guard recording != oldValue else { return }
            if recording {
                Self.currentRecorder = self
                NotificationCenter.default.post(name: Self.recordingBegan, object: self)
            } else {
                if Self.currentRecorder === self { Self.currentRecorder = nil }
                NotificationCenter.default.post(name: Self.recordingEnded, object: self)
            }
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() { recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = shortcut.display; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { title = "Use ⌘, ⌃ or ⌥ + key"; return }
        var mods: UInt32 = 0
        var display = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); display += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        guard let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return }
        display += key
        let value = OpenGlyphCore.KeyboardShortcut(keyCode: UInt32(event.keyCode), modifiers: mods, display: display)
        shortcut = value; title = display; onChange?(value); recording = false
    }
    override func resignFirstResponder() -> Bool { recording = false; title = shortcut.display; return super.resignFirstResponder() }
}
