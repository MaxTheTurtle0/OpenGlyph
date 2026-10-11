import AppKit
import Combine
import OpenGlyphCore
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published private(set) var isSelecting = false

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private var completion: ((Result<CGImage, Error>?) -> Void)?
    private var captureTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation = UUID()
    private var snapshots: [DisplaySnapshot] = []
    private var windows: [CaptureWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var anchor: CGPoint?
    private var selection: CGRect?
    private var previousApplication: NSRunningApplication?

    /// A nil result means the user cancelled. The completion is called once on the main actor.
    func startCapture(completion: @escaping (Result<CGImage, Error>?) -> Void) {
        guard !isSelecting else {
            completion(.failure(CaptureError.alreadySelecting))
            return
        }
        guard Self.hasPermission else {
            completion(.failure(CaptureError.permissionRequired))
            return
        }
        self.completion = completion
        previousApplication = NSWorkspace.shared.frontmostApplication
        isSelecting = true
        let token = UUID()
        generation = token
        installObservers()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                var frozen: [DisplaySnapshot] = []
                var totalPixels = 0
                for screen in NSScreen.screens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                        throw CaptureError.displayUnavailable
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let scale = max(CGFloat(filter.pointPixelScale), screen.backingScaleFactor)
                    let width = Int(ceil(CGFloat(display.width) * scale))
                    let height = Int(ceil(CGFloat(display.height) * scale))
                    guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
                        throw CaptureError.selectionTooLarge
                    }
                    totalPixels += width * height
                    guard totalPixels <= 100_000_000 else { throw CaptureError.selectionTooLarge }
                    let configuration = SCStreamConfiguration()
                    configuration.width = width
                    configuration.height = height
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    try Task.checkCancellation()
                    guard self.generation == token, self.isSelecting else { return }
                    frozen.append(DisplaySnapshot(screen: screen, frame: screen.frame, image: image))
                }
                guard !frozen.isEmpty else { throw CaptureError.displayUnavailable }
                guard self.generation == token, self.isSelecting else { return }
                self.timeoutTask?.cancel()
                self.timeoutTask = nil
                self.snapshots = frozen
                self.presentOverlay()
            } catch is CancellationError {
                guard self.generation == token, self.isSelecting else { return }
                self.finish(nil)
            } catch {
                guard self.generation == token, self.isSelecting else { return }
                self.finish(.failure(error))
            }
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.generation == token, self.isSelecting else { return }
            self.finish(.failure(CaptureError.timedOut))
        }
    }

    func cancel() {
        guard isSelecting else { return }
        finish(nil)
    }

    private func presentOverlay() {
        // Every display is frozen before even the first overlay window becomes visible.
        for snapshot in snapshots {
            let window = CaptureWindow(
                contentRect: snapshot.frame, styleMask: .borderless,
                backing: .buffered, defer: false, screen: snapshot.screen
            )
            // setFrame always uses global AppKit coordinates, including displays left of the primary.
            window.setFrame(snapshot.frame, display: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.acceptsMouseMovedEvents = true
            window.sharingType = .none
            let view = CaptureOverlayView(snapshot: snapshot)
            view.coordinator = self
            window.contentView = view
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        let pointer = NSEvent.mouseLocation
        let target = windows.first(where: { $0.frame.contains(pointer) }) ?? windows.first
        target?.makeKey()
        NSCursor.crosshair.set()
    }

    fileprivate func beginSelection(at point: CGPoint) {
        anchor = point
        selection = nil
        redrawOverlays()
    }

    fileprivate func updateSelection(to point: CGPoint) {
        guard let anchor else { return }
        selection = CaptureGeometry.selection(from: anchor, to: point)
        redrawOverlays()
    }

    fileprivate func endSelection(at point: CGPoint) {
        updateSelection(to: point)
        guard let selection, selection.width >= 4, selection.height >= 4 else {
            // A click or accidental tiny drag leaves selection mode ready for another drag.
            anchor = nil
            self.selection = nil
            redrawOverlays()
            return
        }
        do { finish(.success(try croppedImage(for: selection))) }
        catch { finish(.failure(error)) }
    }

    private func redrawOverlays() {
        for window in windows {
            guard let view = window.contentView as? CaptureOverlayView else { continue }
            view.selection = selection
            view.needsDisplay = true
        }
    }

    private func croppedImage(for selection: CGRect) throws -> CGImage {
        try CaptureGeometry.composedImage(
            for: selection,
            screenshots: snapshots.map { CaptureGeometry.Screenshot(frame: $0.frame, image: $0.image) }
        )
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSelecting else { return }
                self.finish(.failure(CaptureError.displayConfigurationChanged))
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.windows.isEmpty else { return }
                self.cancel()
            }
        })
    }

    private func finish(_ result: Result<CGImage, Error>?) {
        guard isSelecting else { return }
        generation = UUID()
        captureTask?.cancel()
        captureTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        snapshots.removeAll()
        anchor = nil
        selection = nil
        NSCursor.arrow.set()
        let callback = completion
        completion = nil
        isSelecting = false
        if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication?.activate(options: [])
        }
        previousApplication = nil
        callback?(result)
    }
}

private struct DisplaySnapshot {
    let screen: NSScreen
    let frame: CGRect
    let image: CGImage
}

private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureOverlayView: NSView {
    weak var coordinator: CaptureCoordinator?
    var selection: CGRect?
    private let snapshot: DisplaySnapshot
    private let backgroundImage: NSImage
    private let accent = NSColor(red: 1, green: 0.78, blue: 0.26, alpha: 1)

    init(snapshot: DisplaySnapshot) {
        self.snapshot = snapshot
        backgroundImage = NSImage(cgImage: snapshot.image, size: snapshot.frame.size)
        super.init(frame: CGRect(origin: .zero, size: snapshot.frame.size))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        if let selection, !selection.isEmpty {
            let clipped = selection.intersection(snapshot.frame)
            if !clipped.isEmpty {
                let local = clipped.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: local).addClip()
                backgroundImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                accent.setStroke()
                let border = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1.5
                border.stroke()
                drawLabel(
                    "\(Int(selection.width)) × \(Int(selection.height))  ·  Release to capture",
                    centeredAt: CGPoint(x: local.midX, y: max(30, min(bounds.height - 32, local.maxY + 24)))
                )
            }
        } else {
            drawLabel(
                "Drag over text or a QR code  ·  Esc to cancel",
                centeredAt: CGPoint(x: bounds.midX, y: bounds.height - 78)
            )
        }
    }

    private func drawLabel(_ text: String, centeredAt point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white
        ]
        let label = NSAttributedString(string: text, attributes: attributes)
        let size = label.size()
        let bubbleWidth = min(size.width + 28, max(0, bounds.width - 24))
        let originX = max(12, min(bounds.width - bubbleWidth - 12, point.x - bubbleWidth / 2))
        let bubble = CGRect(x: originX, y: point.y - 18, width: bubbleWidth, height: 36)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 10, yRadius: 10).fill()
        label.draw(in: CGRect(x: bubble.minX + 14, y: bubble.midY - size.height / 2, width: bubbleWidth - 28, height: size.height))
    }

    override func mouseDown(with event: NSEvent) { coordinator?.beginSelection(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { coordinator?.updateSelection(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { coordinator?.endSelection(at: NSEvent.mouseLocation) }
    override func rightMouseDown(with event: NSEvent) { coordinator?.cancel() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { coordinator?.cancel() }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { coordinator?.cancel() }
}

private enum CaptureError: LocalizedError {
    case alreadySelecting, permissionRequired, displayUnavailable, displayConfigurationChanged
    case selectionTooLarge, timedOut

    var errorDescription: String? {
        switch self {
        case .alreadySelecting: return "A screen selection is already in progress. Press Esc to cancel it."
        case .permissionRequired: return "Allow OpenGlyph to record your screen in System Settings, then try again."
        case .displayUnavailable: return "A display could not be captured. Check your displays and try again."
        case .displayConfigurationChanged: return "Your display arrangement changed. Start a new capture."
        case .selectionTooLarge: return "This capture is too large. Select a smaller region or use fewer displays."
        case .timedOut: return "Screen capture did not respond. Check Screen Recording permission and try again."
        }
    }
}
