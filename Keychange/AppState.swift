import SwiftUI
import IOKit.hid
import Carbon
import ServiceManagement

// MARK: - Models

struct Keyboard: Identifiable, Equatable {
    let id: String // "\(name)-\(vendorID)-\(productID)"
    let name: String
    let vendorID: Int
    let productID: Int
}

struct InputSource: Identifiable, Equatable {
    let id: String // kTISPropertyInputSourceID
    let name: String // localized name
}

// MARK: - App state / engine

/// Everything the app does: watch HID keyboards, remember which input source belongs
/// to which device, and switch the system input source when the active device changes.
/// Mirrors autokbisw's IOKeyEventMonitor, minus the CLI.
@MainActor
final class AppState: ObservableObject {

    // Live state
    @Published var devices: [Keyboard] = []
    @Published var activeDeviceID: String? = nil
    @Published var inputSources: [InputSource] = []
    @Published var hasPermission: Bool = false
    @Published var menuBarCode: String = "—"
    /// The Keychange mark with the current source's code; nil → show menuBarCode text.
    @Published var menuBarIcon: NSImage? = nil

    /// deviceID -> inputSourceID. A missing key means "Default": never switch for that device.
    @Published var mapping: [String: String] = [:] {
        didSet { defaults.set(mapping, forKey: Key.mapping) }
    }

    // Persisted settings. @Published + didSet, not @AppStorage (which misbehaves inside ObservableObject).
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.isEnabled)
            refreshMenuBarCode()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            // try? on purpose: a failed (un)register is not worth a UI error path.
            if launchAtLogin { try? SMAppService.mainApp.register() }
            else { try? SMAppService.mainApp.unregister() }
        }
    }

    private enum Key {
        static let mapping = "mapping"
        static let isEnabled = "isEnabled"
    }

    private let defaults = UserDefaults.standard
    private var manager: IOHIDManager?
    /// autokbisw's `lastActiveKeyboard` debounce: only act when the typing device actually changes.
    private var lastActiveID: String?

    init() {
        mapping = defaults.dictionary(forKey: Key.mapping) as? [String: String] ?? [:]
        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled

        refreshInputSources()
        refreshMenuBarCode()
        observeInputSourceChanges()
        startMonitoring()
    }

    // MARK: - Public API

    /// `sourceID == nil` means Default (never switch for this device).
    /// Persists immediately and applies right away if this is the device being typed on.
    func setMapping(deviceID: String, sourceID: String?) {
        mapping[deviceID] = sourceID
        if isEnabled, deviceID == activeDeviceID, let sourceID {
            select(sourceID)
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func openInputMonitoringSettings() {
        // User-initiated is the only place we request access — it registers the app
        // in the Input Monitoring list (apps that never request don't appear there).
        // If the user denied before, macOS won't prompt again; only then open Settings.
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent),
           IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - HID monitoring

    private func startMonitoring() {
        // Input Monitoring is a TCC prompt, not an entitlement. We never request it —
        // the empty state's "Open Privacy & Security…" link is the only path, and even
        // opening the HID manager would trigger the system prompt, so skip all HID setup
        // until granted. NOTE: a freshly granted permission only takes effect after relaunch.
        hasPermission = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        guard hasPermission else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)

        // Only real key presses, not LED/consumer reports from the same device.
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            MainActor.assumeIsolated { AppState.from(context)?.refreshDevices() }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            MainActor.assumeIsolated { AppState.from(context)?.refreshDevices() }
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            // Scheduled on the main run loop below, so this callback is already on the main thread.
            MainActor.assumeIsolated { AppState.from(context)?.handle(value) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        refreshDevices()
    }

    /// Non-isolated so it can be reached from the C callbacks.
    nonisolated private static func from(_ context: UnsafeMutableRawPointer?) -> AppState? {
        guard let context else { return nil }
        return Unmanaged<AppState>.fromOpaque(context).takeUnretainedValue()
    }

    private func refreshDevices() {
        guard let manager, let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            devices = []
            return
        }
        devices = set.map(Self.keyboard(for:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func handle(_ value: IOHIDValue) {
        let device = IOHIDElementGetDevice(IOHIDValueGetElement(value))
        let id = Self.keyboard(for: device).id
        guard id != lastActiveID else { return }
        lastActiveID = id
        activeDeviceID = id

        guard isEnabled, let wanted = mapping[id], wanted != currentSourceID else { return }
        select(wanted)
    }

    nonisolated private static func keyboard(for device: IOHIDDevice) -> Keyboard {
        func property<T>(_ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }
        let name: String = property(kIOHIDProductKey) ?? "Keyboard"
        let vendorID: Int = property(kIOHIDVendorIDKey) ?? 0
        let productID: Int = property(kIOHIDProductIDKey) ?? 0
        return Keyboard(id: "\(name)-\(vendorID)-\(productID)", name: name, vendorID: vendorID, productID: productID)
    }

    // MARK: - Text Input Sources

    private func refreshInputSources() {
        guard let all = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        inputSources = all.compactMap { source in
            guard Self.property(source, kTISPropertyInputSourceCategory) as? String == (kTISCategoryKeyboardInputSource as String),
                  Self.property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool == true,
                  Self.property(source, kTISPropertyInputSourceIsEnabled) as? Bool == true,
                  let id = Self.property(source, kTISPropertyInputSourceID) as? String,
                  let name = Self.property(source, kTISPropertyLocalizedName) as? String
            else { return nil }
            return InputSource(id: id, name: name)
        }
    }

    private var currentSourceID: String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.property(current, kTISPropertyInputSourceID) as? String
    }

    private func select(_ sourceID: String) {
        let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
        guard let matches = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = matches.first else { return }
        TISSelectInputSource(source)
    }

    private func refreshMenuBarCode() {
        guard isEnabled else {
            menuBarIcon = Self.disabledIcon()
            return
        }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            menuBarCode = "—"
            menuBarIcon = nil
            return
        }
        let languages = Self.property(current, kTISPropertyInputSourceLanguages) as? [String] ?? []
        menuBarCode = Self.badgeText(for: languages.first)
        menuBarIcon = Self.badge(menuBarCode)
    }

    private static func badgeText(for language: String?) -> String {
        language?.uppercased() ?? "—"
    }

    /// The Keychange mark at menu bar size, evolved from design-handoff/logo: front
    /// plate solid with the current code knocked out to a real hole (so template
    /// rendering survives), back plate the source switched *from* — texture only.
    private static func mark(frontGlyph: @escaping (NSRect) -> Void, alpha: CGFloat = 1,
                             outlinedBack: Bool = false) -> NSImage {
        // Two equal 4:3 plates (the system Input menu badge ratio), 80% overlap on
        // both axes. Construction spans x 1.5-12.54, y 1.4-10.08 (8.68pt tall),
        // scaled to an 18pt-tall canvas.
        let k: CGFloat = 18 / 8.68
        let image = NSImage(size: NSSize(width: (11.04 * k).rounded(), height: 18), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: -1.5 * k, y: -1.4 * k)
            ctx.scaleBy(x: k, y: k)

            // Back plate: 40% fill normally; outline = the disabled state.
            let backRect = NSRect(x: 3.34, y: 2.78, width: 9.2, height: 6.9)
            NSColor.black.withAlphaComponent(0.4).set()
            if outlinedBack {
                // Inset so the stroke stays inside the plate's footprint (and the canvas).
                let back = NSBezierPath(roundedRect: backRect.insetBy(dx: 0.65, dy: 0.65),
                                        xRadius: 2, yRadius: 2)
                back.lineWidth = 1.3
                back.stroke()
            } else {
                NSBezierPath(roundedRect: backRect, xRadius: 2, yRadius: 2).fill()
            }

            let frontRect = NSRect(x: 1.5, y: 1.4, width: 9.2, height: 6.9)
            NSColor.black.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: frontRect, xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            frontGlyph(frontRect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func badge(_ text: String) -> NSImage {
        // Handoff: 1-2 characters only; 3+ falls back to the first.
        let code = text.count > 2 ? String(text.prefix(1)) : text
        let font = NSFont.systemFont(ofSize: 4.8, weight: .bold)
        let attributed = NSAttributedString(string: code, attributes: [.font: font, .kern: -0.1])
        return mark(frontGlyph: { front in
            // Center the actual ink: font-metric math (cap height/descender) drifts
            // visibly at this size, so measure what the glyphs really cover.
            let ctx = NSGraphicsContext.current!.cgContext
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = .zero
            let ink = CTLineGetImageBounds(line, ctx)
            ctx.textPosition = CGPoint(x: front.midX - ink.midX, y: front.midY - ink.midY)
            CTLineDraw(line, ctx)
        })
    }

    /// Disabled look: keyboard symbol in place of the code (we're not switching),
    /// whole mark dimmed the way the system dims status items.
    private static func disabledIcon() -> NSImage {
        let symbol = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keychange disabled")!
            .withSymbolConfiguration(.init(pointSize: 6, weight: .bold))!
        return mark(frontGlyph: { front in
            let rect = NSRect(x: front.midX - symbol.size.width / 2,
                              y: front.midY - symbol.size.height / 2,
                              width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
        }, alpha: 0.4, outlinedBack: true)
    }

    /// Also catches input source changes the user makes by hand (or via the system UI).
    private func observeInputSourceChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshInputSources()
                self?.refreshMenuBarCode()
            }
        }
    }

    private static func property(_ source: TISInputSource, _ key: CFString!) -> Any? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
