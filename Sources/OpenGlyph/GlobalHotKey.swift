import Carbon
import Foundation
import OpenGlyphCore

private let openGlyphHotKeySignature: OSType = 0x4F474C59

private let openGlyphHotKeyEventHandler: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
    )
    guard status == noErr, identifier.signature == openGlyphHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
    let id = identifier.id
    Task { @MainActor [weak owner] in owner?.handlePress(id: id) }
    return noErr
}

/// A Carbon hot key needs no Accessibility or Input Monitoring permission.
@MainActor
final class GlobalHotKey {
    private static var nextIdentifier: UInt32 = 1
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registeredShortcut: KeyboardShortcut?
    private var registeredIdentifier: UInt32?
    private var handler: (() -> Void)?

    init() {}

    func register(_ shortcut: KeyboardShortcut, handler: @escaping () -> Void) throws {
        let allowed = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        guard shortcut.keyCode <= 127, shortcut.modifiers & ~allowed == 0,
              shortcut.modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            throw HotKeyError.invalidShortcut
        }
        if registeredShortcut?.keyCode == shortcut.keyCode,
           registeredShortcut?.modifiers == shortcut.modifiers, hotKey != nil {
            self.handler = handler
            registeredShortcut = shortcut
            return
        }
        try installHandlerIfNeeded()
        let id = Self.nextIdentifier
        Self.nextIdentifier = Self.nextIdentifier == .max ? 1 : Self.nextIdentifier + 1
        var newReference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: openGlyphHotKeySignature, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &newReference
        )
        guard status == noErr, let newReference else {
            throw HotKeyError.registrationFailed(status, shortcut.display)
        }
        // Keep the previous shortcut usable if registering its replacement fails.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = newReference
        registeredShortcut = shortcut
        registeredIdentifier = id
        self.handler = handler
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredShortcut = nil
        registeredIdentifier = nil
        handler = nil
    }

    fileprivate func handlePress(id: UInt32) {
        guard registeredIdentifier == id, hotKey != nil else { return }
        handler?()
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), openGlyphHotKeyEventHandler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        guard status == noErr else { throw HotKeyError.handlerFailed(status) }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

private enum HotKeyError: LocalizedError {
    case invalidShortcut
    case registrationFailed(OSStatus, String)
    case handlerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            return "Choose a shortcut that includes Command, Option, or Control."
        case let .registrationFailed(status, display):
            if status == eventHotKeyExistsErr {
                return "\(display) is already used by another application. Choose a different shortcut in Settings."
            }
            return "Could not register \(display). System error \(status)."
        case let .handlerFailed(status):
            return "Could not listen for the capture shortcut. System error \(status)."
        }
    }
}
