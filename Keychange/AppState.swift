import SwiftUI
import IOKit.hid
import Carbon
import ServiceManagement
import Sparkle

// MARK: - Models

struct Keyboard: Identifiable {
    let id: String // "\(name)-\(vendorID)-\(productID)"
    let name: String
    let vendorID: Int
    let productID: Int
}

struct InputSource: Identifiable {
    let id: String // kTISPropertyInputSourceID
    let name: String // localized name
}

/// What the user chose for one device. `source == nil` means "Don't switch".
/// `hidden` keeps a device out of the list — mice expose keyboard interfaces too
/// (programmable buttons, media keys) and are indistinguishable from real keyboards
/// by their HID descriptors, so the only reliable filter is the user pointing at them.
struct DeviceSetting {
    var source: String? = nil
    var hidden = false
}

/// Sparkle normally reads `SUFeedURL` from Info.plist, but the project generates its
/// plist from build settings and Xcode only passes through the keys it knows — so the
/// feed lives here instead.
///
/// ponytail: no EdDSA key, updates are validated against the Developer ID signature
/// (Sparkle accepts either). That check happens after unarchiving; an install that needs
/// elevated privileges is validated *before* unarchiving and would need `SUPublicEDKey`
/// plus a `sign_update` step in the release workflow.
private final class UpdaterConfig: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // The dev bundle is version 1.0 (build 1), so every release looks newer to
        // Sparkle and the dev build always has an update waiting — which is what makes
        // it useful for looking at the update UI. It stops at the install: the dev build
        // is signed "Apple Development" and the release "Developer ID", so the signature
        // comparison rejects it.
        "https://github.com/dennistimmermann/keychange/releases/latest/download/appcast.xml"
    }

    /// The popover has the toggle; no need for Sparkle's permission modal.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
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

    /// deviceID -> settings. A missing key means "Don't switch" for that device.
    /// Persisted as a nested dictionary — UserDefaults is plist-backed and String/Bool/
    /// Dictionary are native plist types, so this needs no encoder.
    @Published var settings: [String: DeviceSetting] = [:] {
        didSet {
            defaults.set(settings.mapValues { setting -> [String: Any] in
                var raw: [String: Any] = ["hidden": setting.hidden]
                // Assigned only when set: a nil in there is not a plist value.
                if let source = setting.source { raw["source"] = source }
                return raw
            }, forKey: Key.settings)
        }
    }

    // Persisted settings. @Published + didSet, not @AppStorage (which misbehaves inside ObservableObject).
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.isEnabled)
            refreshMenuBarCode()
            // Cleared after refreshMenuBarCode so the re-enable animation still
            // sees the flag and fades the "!" out.
            if isEnabled { autoDisabled = false }
        }
    }
    /// When on, a source change made outside the app (system Input menu, shortcut)
    /// disables switching until the user re-enables it.
    @Published var autoDisableOnExternalSwitch: Bool {
        didSet { defaults.set(autoDisableOnExternalSwitch, forKey: Key.autoDisableOnExternalSwitch) }
    }
    /// Switch from inside the key press (event tap) instead of after it, so the first
    /// character is already in the new layout.
    @Published var instantSwitching: Bool {
        didSet {
            defaults.set(instantSwitching, forKey: Key.instantSwitching)
            updateTap()
        }
    }
    /// Set when instant switching is on but the tap could not be created.
    @Published private(set) var tapFailed = false
    @Published var launchAtLogin: Bool {
        didSet {
            // try? on purpose: a failed (un)register is not worth a UI error path.
            if launchAtLogin { try? SMAppService.mainApp.register() }
            else { try? SMAppService.mainApp.unregister() }
        }
    }
    /// Sparkle. No EdDSA key (see UpdaterConfig), so the release build must stay
    /// signed and notarized.
    let updater: SPUStandardUpdaterController
    /// Held because `SPUStandardUpdaterController` only keeps a weak reference.
    private let updaterDelegate: UpdaterConfig
    /// Sparkle persists this itself under `SUEnableAutomaticChecks`, so it needs no `Key`.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private enum Key {
        static let settings = "deviceSettings"
        static let isEnabled = "isEnabled"
        static let autoDisableOnExternalSwitch = "autoDisableOnExternalSwitch"
        static let autoDisabled = "autoDisabled"
        static let instantSwitching = "instantSwitching"
    }

    /// Screenshot mode (`-mockData`): the popover shows these fake keyboards and
    /// nothing real is monitored or refreshed. Debug builds only in practice —
    /// the flag is harmless but pointless in a release.
    let mockMode = ProcessInfo.processInfo.arguments.contains("-mockData")

    private let defaults = UserDefaults.standard
    private var manager: IOHIDManager?
    /// autokbisw's `lastActiveKeyboard` debounce: only act when the typing device actually changes.
    private var lastActiveID: String?
    private var iconAnimation: Task<Void, Never>?
    /// The last source this app selected, and the last one observed at all. An
    /// external switch is a notification where the source actually CHANGED to
    /// something we didn't select — comparing against lastAppSelected alone would
    /// re-trigger on stray notifications long after the real switch (input methods
    /// fire them on focus changes), e.g. immediately after re-enabling.
    private var lastAppSelected: String?
    private var lastKnownSourceID: String?
    /// The current input source, kept in sync by `select` and the change observer, so
    /// the tap's per-keystroke check never has to ask TIS.
    private var cachedSourceID: String?
    /// Registry entry ID -> device id, for identifying the sender of a tapped event.
    private var senderIDs: [UInt64: String] = [:]
    private let tap = KeyEventTap()
    /// Set when "Auto-disable on external switch" turned the app off (drives the "!" mark
    /// and the popover info box); cleared when the user re-enables. Persisted so a
    /// relaunch keeps the reason.
    @Published private(set) var autoDisabled = false {
        didSet { defaults.set(autoDisabled, forKey: Key.autoDisabled) }
    }
    /// Whether the status item currently shows the disabled mark (drives the toggle animation).
    private var iconShowsDisabled = false

    init() {
        // Sparkle's SUEnableAutomaticChecks defaults to off, and it would otherwise ask
        // for permission with a modal on the second launch. Opt in through the
        // registration domain instead: the popover's toggle writes the user domain,
        // which wins from then on.
        UserDefaults.standard.register(defaults: ["SUEnableAutomaticChecks": true])
        let config = UpdaterConfig()
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: config,
                                                      userDriverDelegate: nil)
        updaterDelegate = config
        updater = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        let stored = defaults.dictionary(forKey: Key.settings) as? [String: [String: Any]] ?? [:]
        settings = stored.mapValues {
            DeviceSetting(source: $0["source"] as? String, hidden: $0["hidden"] as? Bool ?? false)
        }
        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        autoDisableOnExternalSwitch = defaults.bool(forKey: Key.autoDisableOnExternalSwitch)
        autoDisabled = defaults.bool(forKey: Key.autoDisabled)
        instantSwitching = defaults.bool(forKey: Key.instantSwitching)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        if mockMode {
            let german = InputSource(id: "com.apple.keylayout.German", name: "German")
            let korean = InputSource(id: "com.apple.inputmethod.Korean.2SetKorean", name: "2-Set Korean")
            let us = InputSource(id: "com.apple.keylayout.US", name: "U.S.")
            inputSources = [german, korean, us]
            let mocks: [(Keyboard, InputSource)] = [
                (Keyboard(id: "mock-internal", name: "Apple Internal Keyboard / Trackpad",
                          vendorID: 0x05AC, productID: 0x0342), german),
                (Keyboard(id: "mock-keychron", name: "Keychron K2", vendorID: 0x3434, productID: 0x0121), us),
                (Keyboard(id: "mock-mx", name: "MX Keys for Mac", vendorID: 0x046D, productID: 0xB35B), korean),
            ]
            devices = mocks.map(\.0)
            settings = Dictionary(uniqueKeysWithValues: mocks.map { ($0.id, DeviceSetting(source: $1.id)) })
            activeDeviceID = "mock-keychron"
            hasPermission = true
            isEnabled = true
            refreshMenuBarCode()
            return
        }

        refreshInputSources()
        refreshMenuBarCode()
        cachedSourceID = currentSourceID
        lastKnownSourceID = cachedSourceID
        observeInputSourceChanges()
        startMonitoring()
        tap.decide = { [weak self] senderID in
            MainActor.assumeIsolated { self?.decideTapKeyDown(senderID: senderID) ?? .pass }
        }
        updateTap()
    }

    // MARK: - Public API

    /// `sourceID == nil` means Default (never switch for this device). Also unhides.
    /// Persists immediately and applies right away if this is the device being typed on.
    func setMapping(deviceID: String, sourceID: String?) {
        settings[deviceID] = DeviceSetting(source: sourceID)
        if isEnabled, deviceID == activeDeviceID, let sourceID {
            select(sourceID)
        }
    }

    /// Takes a device out of the list. Clearing the source is what makes a hidden device
    /// inert: every switching path bails on the missing source, so no extra guard is needed.
    func setHidden(deviceID: String) {
        settings[deviceID] = DeviceSetting(hidden: true)
    }

    func isHidden(_ deviceID: String) -> Bool {
        settings[deviceID]?.hidden ?? false
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Without activating, Sparkle's panels open behind everything — same LSUIElement
    /// problem the About window has.
    func checkForUpdates() {
        NSApp.activate()
        updater.updater.checkForUpdates()
    }

    func openKeyboardSettings() {
        // There is no deep link to the "Edit Input Sources" sheet itself; this lands
        // on the Keyboard pane, where Input Sources has its Edit… button.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?InputSources")!
        NSWorkspace.shared.open(url)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Accessibility can be granted while we run, so retry the tap when the popover opens.
    func retryTapIfNeeded() {
        if tapFailed { updateTap() }
    }

    func openInputMonitoringSettings() {
        // User-initiated is the only place we request access — it registers the app
        // in the Input Monitoring list (apps that never request don't appear there).
        // Check first: IOHIDRequestAccess returns false while its prompt is still
        // pending, so requesting unconditionally would also open Settings on top.
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeUnknown:
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case kIOHIDAccessTypeDenied:
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            NSWorkspace.shared.open(url)
        default:
            break // already granted; startMonitoring picks it up on relaunch
        }
    }

    /// The tap only runs while instant switching is on and we may switch at all.
    /// An active tap needs Accessibility on top of Input Monitoring; like Input
    /// Monitoring we only ever ask for it from a user action (this setting's toggle).
    private func updateTap() {
        guard instantSwitching, hasPermission else {
            tap.stop()
            tapFailed = false
            return
        }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        tapFailed = !tap.start()
    }

    // MARK: - HID monitoring

    private func startMonitoring() {
        // Input Monitoring is a TCC prompt, not an entitlement. It is never requested
        // from here — the empty state's "Allow Input Monitoring…" link is the only path
        // (see openInputMonitoringSettings) — and even opening the HID manager would
        // trigger the system prompt, so skip all HID setup until granted.
        // NOTE: a freshly granted permission only takes effect after relaunch.
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
            // The manager still lists the departing device during this callback,
            // so re-read its set on the next runloop turn instead of right now.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppState.from(context)?.refreshDevices() }
            }
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

    /// Rebuilds the list from the devices the manager currently has. Also called when
    /// the popover opens, so a disconnect the callback missed still corrects itself.
    func refreshDevices() {
        if mockMode { return }
        guard let manager, let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            devices = []
            senderIDs = [:]
            return
        }
        // Composite devices expose several HID interfaces with the same name/VID/PID;
        // keep one entry per id.
        var seen = Set<String>()
        devices = set.map(Self.keyboard(for:))
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // A tapped event identifies its device by registry entry ID.
        senderIDs = set.reduce(into: [:]) { map, device in
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID) == KERN_SUCCESS
            else { return }
            map[entryID] = Self.keyboard(for: device).id
        }
        // A device that's gone must not keep the accent rail lit. Clearing lastActiveID
        // too means replugging it counts as a change again, so it re-applies its mapping.
        if let active = activeDeviceID, !devices.contains(where: { $0.id == active }) {
            activeDeviceID = nil
            lastActiveID = nil
        }
    }

    private func handle(_ value: IOHIDValue) {
        let device = IOHIDElementGetDevice(IOHIDValueGetElement(value))
        let id = Self.keyboard(for: device).id
        guard id != lastActiveID else { return }
        lastActiveID = id
        activeDeviceID = id
        // With the tap running it switches instead — from inside the keystroke, so the
        // first character is already in the new layout. Here we'd be a moment too late.
        // Exception: taps receive nothing while a password field holds secure input,
        // so fall back to switching here (late, as before) rather than not at all.
        if !tap.isRunning || IsSecureEventInputEnabled() { applySwitch(for: id) }
    }

    /// Switches to the device's mapped source if it isn't already active.
    /// Shared by the HID path and the event tap.
    private func applySwitch(for deviceID: String) {
        guard isEnabled, let wanted = settings[deviceID]?.source, wanted != cachedSourceID else { return }
        select(wanted)
    }

    /// Called from inside the key press, so it must stay cheap: a dictionary lookup and
    /// a string compare, touching TIS only when a switch actually happens.
    private func decideTapKeyDown(senderID: UInt64?) -> KeyDecision {
        guard let deviceID = senderID.flatMap({ senderIDs[$0] }) ?? lastActiveID else { return .pass }
        if deviceID != lastActiveID {
            lastActiveID = deviceID
            activeDeviceID = deviceID
        }
        guard isEnabled, let wanted = settings[deviceID]?.source, wanted != cachedSourceID,
              let source = Self.inputSource(id: wanted) else { return .pass }

        select(wanted)
        // A plain layout can be applied to this very key press by re-translating it.
        // An input method composes from key codes when the event is delivered, so the
        // press has to wait until the switch has actually taken effect.
        return Self.hasLayoutData(source) ? .rewrite(source) : .hold
    }

    nonisolated private static func keyboard(for device: IOHIDDevice) -> Keyboard {
        func property<T>(_ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }
        let name: String = property(kIOHIDProductKey) ?? "Keyboard"
        let vendorID: Int = property(kIOHIDVendorIDKey) ?? 0
        let productID: Int = property(kIOHIDProductIDKey) ?? 0
        return Keyboard(id: "\(name)-\(vendorID)-\(productID)", name: name, vendorID: vendorID, productID: productID)
    }

    // MARK: - Text Input Sources

    /// Also called when the popover opens: enabling a source in System Settings does
    /// not always fire a TIS notification we observe, so the list could be stale.
    func refreshInputSources() {
        if mockMode { return }
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

    private static func inputSource(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let matches = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
        return matches?.first
    }

    /// A keyboard layout carries its key table; an input method (Korean, Japanese, …) doesn't.
    private static func hasLayoutData(_ source: TISInputSource) -> Bool {
        TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil
    }

    private func select(_ sourceID: String) {
        guard let source = Self.inputSource(id: sourceID) else { return }
        lastAppSelected = sourceID
        cachedSourceID = sourceID
        TISSelectInputSource(source)
    }

    private func refreshMenuBarCode() {
        let hadIcon = menuBarIcon != nil

        guard isEnabled else {
            // Already showing (or animating toward) the disabled mark: leave it be —
            // a duplicate refresh must not snap a running fade to its end.
            if hadIcon, iconShowsDisabled { return }
            iconAnimation?.cancel()
            let showMark = autoDisabled
            if hadIcon {
                let code = menuBarCode
                animateIcon { Self.enableFrame(t: $0, code: code, autoDisabledMark: showMark) }
            } else {
                menuBarIcon = Self.disabledIcon(autoDisabledMark: showMark)
            }
            iconShowsDisabled = true
            return
        }

        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            iconAnimation?.cancel()
            menuBarCode = "—"
            menuBarIcon = nil
            iconShowsDisabled = false
            return
        }
        let languages = Self.property(current, kTISPropertyInputSourceLanguages) as? [String] ?? []
        let oldCode = menuBarCode
        let newCode = languages.first?.uppercased() ?? "—"

        // Input methods (e.g. Korean: method + input mode) fire the change
        // notification more than once per switch. menuBarCode is already the
        // target of whatever is showing or animating — a same-code refresh is a
        // no-op, so an in-flight swap keeps playing instead of snapping to its end.
        if hadIcon, !iconShowsDisabled, newCode == oldCode { return }

        iconAnimation?.cancel()
        menuBarCode = newCode

        if iconShowsDisabled, hadIcon {
            let showMark = autoDisabled
            animateIcon { Self.enableFrame(t: 1 - $0, code: newCode, autoDisabledMark: showMark) }
        } else if hadIcon, oldCode != newCode, oldCode != "—" {
            animateIcon { Self.swapFrame(t: $0, from: oldCode, to: newCode) }
        } else {
            menuBarIcon = Self.badge(newCode)
        }
        iconShowsDisabled = false
    }

    /// Flip-book a mark transition into the status item (~0.3s, ~50fps, smoothstep).
    private func animateIcon(frame: @escaping (CGFloat) -> NSImage) {
        iconAnimation = Task { [weak self] in
            let frames = 16
            for i in 1...frames {
                if Task.isCancelled { return }
                let t = CGFloat(i) / CGFloat(frames)
                self?.menuBarIcon = frame(t * t * (3 - 2 * t))
                try? await Task.sleep(nanoseconds: 300_000_000 / UInt64(frames))
            }
        }
    }

    // MARK: - Menu bar mark
    //
    // The Keychange mark, evolved from design-handoff/logo: two equal 4:3 plates
    // (the system Input menu badge ratio) at 80% overlap. The front plate carries
    // the current source's code knocked out to a real hole so template rendering
    // survives; the back plate is the source switched *from* — texture only.
    // On a source change the plates animate a swap (flip-book of NSImages, since
    // status item labels can't run SwiftUI animations).

    nonisolated private static let frontPlate = NSRect(x: 1.5, y: 1.4, width: 9.2, height: 6.9)
    nonisolated private static let backPlate = NSRect(x: 3.34, y: 2.78, width: 9.2, height: 6.9)

    /// Construction spans x 1.5-12.54, y 1.4-10.08 (8.68pt tall), scaled to 18pt tall.
    nonisolated private static func markImage(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        let k: CGFloat = 18 / 8.68
        let image = NSImage(size: NSSize(width: (11.04 * k).rounded(), height: 18), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: -1.5 * k, y: -1.4 * k)
            ctx.scaleBy(x: k, y: k)
            draw(ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws one plate: punches a slightly expanded footprint out of everything
    /// below (so a translucent plate reads as an opaque card with a 0.4pt rim gap
    /// instead of blending — without it, same-brightness plates merge into one
    /// blob), fills at `alpha`, then knocks `glyphFraction` of the code out.
    nonisolated private static func drawPlate(_ rect: NSRect, alpha: CGFloat, code: String = "",
                                              glyphFraction: CGFloat = 0, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -0.4, dy: -0.4), xRadius: 2.4, yRadius: 2.4).fill()
        ctx.restoreGState()

        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        if !code.isEmpty { knockOut(glyph(code), in: rect, fraction: glyphFraction, ctx) }
    }

    nonisolated private static func lerp(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width, height: a.height)
    }

    nonisolated private static func glyph(_ text: String) -> NSAttributedString {
        // 1-2 characters only; 3+ falls back to the first.
        let code = text.count > 2 ? String(text.prefix(1)) : text
        return NSAttributedString(string: code, attributes: [
            .font: NSFont.systemFont(ofSize: 4.8, weight: .bold),
            .kern: -0.1,
        ])
    }

    /// Punches `fraction` of the glyph out of everything drawn so far, centered on
    /// the actual ink: font-metric math (cap height/descender) drifts at this size.
    nonisolated private static func knockOut(_ text: NSAttributedString, in rect: NSRect,
                                 fraction: CGFloat, _ ctx: CGContext) {
        guard fraction > 0 else { return }
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        ctx.setAlpha(fraction)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let line = CTLineCreateWithAttributedString(text)
        ctx.textPosition = .zero
        let ink = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
        CTLineDraw(line, ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// One frame of the plate swap. t = 0: old code front. t = 1: new code front —
    /// which is also the static mark, so `badge` is just the final frame.
    /// Old plate glyph fades out by the midpoint; the new one fades in after it.
    nonisolated private static func swapFrame(t: CGFloat, from oldCode: String, to newCode: String) -> NSImage {
        markImage { ctx in
            let old = { drawPlate(lerp(frontPlate, backPlate, t), alpha: 1 - 0.6 * t,
                                  code: oldCode, glyphFraction: max(0, 1 - 2 * t), ctx) }
            let new = { drawPlate(lerp(backPlate, frontPlate, t), alpha: 0.4 + 0.6 * t,
                                  code: newCode, glyphFraction: max(0, 2 * t - 1), ctx) }
            // The plate headed to the front paints on top from the midpoint on.
            if t < 0.5 { new(); old() } else { old(); new() }
        }
    }

    /// One frame of the enable/disable transition. t = 0: enabled badge (which is
    /// also the static mark). t = 1: disabled — same geometry, front plate dimmed
    /// to 40% with the code faded out. No motion, just opacity. `autoDisabledMark` fades
    /// a "!" in as the code fades out (auto-disabled by an external switch).
    nonisolated private static func enableFrame(t: CGFloat, code: String, autoDisabledMark: Bool = false) -> NSImage {
        markImage { ctx in
            drawPlate(backPlate, alpha: 0.4, ctx)
            drawPlate(frontPlate, alpha: 1 - 0.6 * t, code: code, glyphFraction: 1 - t, ctx)
            if autoDisabledMark { knockOut(glyph("!"), in: frontPlate, fraction: t, ctx) }
        }
    }

    nonisolated private static func badge(_ text: String) -> NSImage {
        enableFrame(t: 0, code: text)
    }

    nonisolated private static func disabledIcon(autoDisabledMark: Bool) -> NSImage {
        enableFrame(t: 1, code: "", autoDisabledMark: autoDisabledMark)
    }

    /// Also catches input source changes the user makes by hand (or via the system UI).
    private func observeInputSourceChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A change we didn't make = the user switched by hand. Forget the
                // active device so the next keystroke re-applies its mapping
                // ("mapping wins") through the normal device-change path — no
                // per-keystroke source checks needed. Optionally step aside
                // entirely instead of correcting them.
                self.cachedSourceID = self.currentSourceID
                // The switch has landed — deliver anything the tap withheld for it.
                self.tap.releaseHeldEvents()
                if let current = self.cachedSourceID, current != self.lastKnownSourceID {
                    self.lastKnownSourceID = current
                    if current != self.lastAppSelected {
                        self.lastActiveID = nil
                        if self.autoDisableOnExternalSwitch, self.isEnabled {
                            self.autoDisabled = true
                            self.isEnabled = false
                        }
                    }
                }
                self.refreshInputSources()
                self.refreshMenuBarCode()
            }
        }
    }

    private static func property(_ source: TISInputSource, _ key: CFString!) -> Any? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
