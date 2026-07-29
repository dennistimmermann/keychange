import Carbon
import CoreGraphics

/// What the tap should do with a key press.
enum KeyDecision {
    /// Deliver unchanged.
    case pass
    /// Deliver, but re-translated with this keyboard layout (its `kTISPropertyUnicodeKeyLayoutData`).
    /// WindowServer bakes the typed text into the event before any tap sees it, so switching the
    /// input source alone cannot fix the character that is already in flight — we rewrite it.
    case rewrite(TISInputSource)
    /// Hold the event and re-post it once the input source has actually changed. Needed when the
    /// target is an input method (Korean, Japanese, …): those compose from key codes at delivery
    /// time, so the only way to route the press correctly is to deliver it after the switch.
    case hold
}

/// An active `CGEventTap` that lets Keychange fix the first character typed on a keyboard whose
/// input source is about to change. Active (not listen-only) because it must alter or withhold
/// events, which is also why it needs the Accessibility permission.
final class KeyEventTap {

    /// Asked for every key press, with the sending device's registry entry ID when resolvable.
    var decide: ((UInt64?) -> KeyDecision)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Presses withheld while waiting for the input source to change, in typing order.
    private var held: [CGEvent] = []
    /// Marks our own re-posted events so we pass them straight through.
    private static let repostMarker: Int64 = 0x4B43_4841_4E47 // "KCHANG"

    var isRunning: Bool { tap != nil }

    // MARK: - Lifecycle

    func start() -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyEventTap>.fromOpaque(context).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        releaseHeldEvents()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
    }

    // MARK: - The hot path

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap whose callback ran too long; just switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != Self.repostMarker
        else { return Unmanaged.passUnretained(event) }

        // Everything typed while a switch is pending waits behind it, or the characters
        // would reach the app out of order.
        if !held.isEmpty {
            hold(event)
            return nil
        }

        switch decide?(Self.senderID(of: event)) ?? .pass {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .rewrite(let source):
            Self.retranslate(event, with: source)
            return Unmanaged.passUnretained(event)
        case .hold:
            hold(event)
            return nil
        }
    }

    private func hold(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        held.append(copy)
        // Safety net: never swallow keystrokes if the switch notification never arrives.
        let generation = held.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.held.count >= generation else { return }
            self.releaseHeldEvents()
        }
    }

    /// Called once the input source actually changed: deliver what we withheld, in order.
    func releaseHeldEvents() {
        let events = held
        held = []
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.repostMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Re-translating a press with another layout

    /// Replaces the text the event carries with what `source`'s layout produces for the same
    /// physical key. No-op for sources without layout data (input methods).
    private static func retranslate(_ event: CGEvent, with source: TISInputSource) {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // CGEventFlags and UCKeyTranslate's modifier key state use different layouts.
        let flags = event.flags
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey >> 8) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey >> 8) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }
        // Command-key presses are shortcuts, not text: leave them alone.
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return }

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers,
                                  UInt32(LMGetKbdType()), 0, &deadKeyState,
                                  characters.count, &length, &characters)
        }
        // A dead key (´, ^ …) produces nothing yet; leaving the event as-is is closer to right
        // than blanking it, and the layout is switched for everything that follows.
        guard status == noErr, length > 0 else { return }
        event.keyboardSetUnicodeString(stringLength: length, unicodeString: characters)
    }

    // MARK: - Which device sent this event

    #if KEYCHANGE_PRIVATE_HID

    /// Private API, resolved at runtime so no private headers are needed and a missing symbol
    /// degrades to nil (the caller then falls back to the HID stream's last active device).
    /// Excluded from builds that must not touch private API — see KEYCHANGE_PRIVATE_HID.
    private typealias CopyIOHIDEvent = @convention(c) (CGEvent) -> Unmanaged<AnyObject>?
    private typealias GetSenderID = @convention(c) (AnyObject) -> UInt64

    private static let copyIOHIDEvent: CopyIOHIDEvent? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventCopyIOHIDEvent")
        .map { unsafeBitCast($0, to: CopyIOHIDEvent.self) }
    private static let getSenderID: GetSenderID? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventGetSenderID")
        .map { unsafeBitCast($0, to: GetSenderID.self) }

    private static func senderID(of event: CGEvent) -> UInt64? {
        guard let copyIOHIDEvent, let getSenderID,
              let hidEvent = copyIOHIDEvent(event)?.takeRetainedValue() else { return nil }
        let id = getSenderID(hidEvent)
        return id == 0 ? nil : id
    }

    #else

    private static func senderID(of event: CGEvent) -> UInt64? { nil }

    #endif
}
