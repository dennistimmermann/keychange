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
    /// The current input source's own icon (same asset the system Input menu uses); nil → show menuBarCode text.
    @Published var menuBarIcon: NSImage? = nil

    /// deviceID -> inputSourceID. A missing key means "Default": never switch for that device.
    @Published var mapping: [String: String] = [:] {
        didSet { defaults.set(mapping, forKey: Key.mapping) }
    }

    // Persisted settings. @Published + didSet, not @AppStorage (which misbehaves inside ObservableObject).
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }
    @Published var showDeviceDetails: Bool {
        didSet { defaults.set(showDeviceDetails, forKey: Key.showDeviceDetails) }
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
        static let showDeviceDetails = "showDeviceDetails"
    }

    private let defaults = UserDefaults.standard
    private var manager: IOHIDManager?
    /// autokbisw's `lastActiveKeyboard` debounce: only act when the typing device actually changes.
    private var lastActiveID: String?

    init() {
        mapping = defaults.dictionary(forKey: Key.mapping) as? [String: String] ?? [:]
        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        showDeviceDetails = defaults.bool(forKey: Key.showDeviceDetails)
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

    /// The system's real per-layout icons are not reachable via public API (keylayouts only
    /// expose a generic legacy IconRef, input methods point at nonexistent files), so draw
    /// our own badge: language code in an outlined rounded rect, as a template image so it
    /// adapts to menu bar light/dark like the system's own item.
    private static func badge(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let textSize = attributed.size()
        // Square, sized up just enough if the code is wider than the default side.
        let side = max(18, textSize.width.rounded(.up) + 4)
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            // Optically center on the cap height; size() includes line spacing that sits too high.
            let baseline = (rect.height - font.capHeight) / 2
            attributed.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                        y: baseline + font.descender))
            return true
        }
        image.isTemplate = true
        return image
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
