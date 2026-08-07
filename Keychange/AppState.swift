import SwiftUI
import IOKit.hid
import Carbon
import ServiceManagement
import Sparkle

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

    /// One instance, reachable from the app delegate — which is what has to open the
    /// settings window on a relaunch, and cannot see a `@StateObject`.
    static let shared = AppState()

    // Live state
    @Published var devices: [Keyboard] = []
    @Published var activeDeviceID: String? = nil
    /// True once the active device's change has been consumed by the switching path, so a
    /// mapping is applied once per device change, not once per key press. Meaningless while
    /// `activeDeviceID` is nil — reset and unplug re-arm by clearing that.
    private var mappingApplied = false
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
            updateTap()
            if isEnabled {
                // Cleared after refreshMenuBarCode so the re-enable animation still sees the
                // flag and fades the mark out.
                autoDisabled = nil
                // Correct the layout the moment switching comes back on, rather than leaving
                // whatever we were switched off over until the next key press. The keyboard
                // stays selected through all of this: it is still the one being typed on, and
                // forgetting it would only cost the conflict check and Pause the one fact they
                // need. A no-op when the layout already matches, which is the common case.
                if let activeDeviceID { applySwitch(for: activeDeviceID) }
            }
        }
    }
    /// How to react when the input source is changed outside the app.
    @Published var externalChangeAction: ExternalChangeAction {
        didSet {
            guard externalChangeAction != oldValue else { return }
            defaults.set(externalChangeAction.rawValue, forKey: Key.externalChangeAction)
            forgetActiveDevice()
        }
    }
    /// When the switch lands relative to the triggering key press — see `SwitchTiming`.
    @Published var switchTiming: SwitchTiming {
        didSet {
            guard switchTiming != oldValue else { return }
            defaults.set(switchTiming.rawValue, forKey: Key.switchTiming)
            updateTap()
            forgetActiveDevice()
        }
    }
    /// Set when "Before key press" is selected but the tap could not be created — i.e. we
    /// don't have Accessibility access.
    @Published private(set) var tapFailed = false
    /// Whether the status item is installed at all. Off means Keychange runs with nothing
    /// on screen; the settings window takes over as its only surface.
    @Published var showsMenuBarItem: Bool {
        didSet {
            guard showsMenuBarItem != oldValue else { return }
            defaults.set(showsMenuBarItem, forKey: Key.showsMenuBarItem)
            // Whichever way this is flipped, it is flipped from inside one of the two
            // settings surfaces — and the other one is about to become the right one.
            // Neither swap happens on its own, so both are done here, and both are
            // deferred, because the toggle that triggered them is in the surface going
            // away.
            DispatchQueue.main.async { [self] in
                if showsMenuBarItem {
                    // The panel is the settings now; the window would be a second copy.
                    settingsWindow?.close()
                } else {
                    // Removing the status item does not take its open panel with it —
                    // that is left floating with nothing to belong to.
                    dismissMenuBarPanel()
                    showSettings()
                }
            }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            // try? on purpose: a failed (un)register is not worth a UI error path.
            if launchAtLogin { try? SMAppService.mainApp.register() }
            else { try? SMAppService.mainApp.unregister() }
            // Setting this by hand answers the offer's question, so the box goes away rather than
            // sitting there asking about a switch you just used. Safe in `init`, which assigns the
            // stored property directly and so never runs this.
            //
            // Only if it took, though. `try?` above swallows a failed `register()` — a still
            // translocated first run, or an MDM policy — and the offer is asked exactly once, so
            // latching it on a registration that silently did nothing would hide the very thing it
            // exists to prevent. The test is the same `== .enabled` that opened the offer, so the
            // two cannot disagree: any status that would not have suppressed the offer does not
            // close it either, and a `.requiresApproval` result rightly asks again next launch.
            if SMAppService.mainApp.status == .enabled { closeLaunchAtLoginOffer() }
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

    /// Whether to offer starting at login. Keychange lives in the menu bar, so a user who never
    /// turns this on gets their per-keyboard layouts silently back to nothing after a restart,
    /// with little on screen to explain why — a worse surprise than being asked once.
    ///
    /// Asked once and then never again, whichever way it is answered. Never asked at all if the
    /// login item is already registered, so reinstalls and upgrades stay quiet.
    @Published private(set) var offersLaunchAtLogin = false

    private enum Key {
        static let settings = "deviceSettings"
        static let isEnabled = "isEnabled"
        static let externalChangeAction = "externalChangeAction"
        static let autoDisabled = "autoDisabled"
        static let switchTiming = "switchTiming"
        static let showsMenuBarItem = "showsMenuBarItem"
        static let didOfferLaunchAtLogin = "didOfferLaunchAtLogin"
    }

    /// Taken for the whole life of the process and never ended. Without it, an app showing nothing
    /// at all — menu bar item off, window closed — is a candidate for App Nap, which throttles the
    /// main run loop. That is the run loop the HID manager and the event tap are both scheduled on,
    /// so key presses simply stop arriving and switching dies until something is put back on
    /// screen. `AllowingIdleSystemSleep` because watching for keystrokes is no reason to keep a Mac
    /// awake.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Watching which keyboard you are typing on")

    private let defaults = UserDefaults.standard
    private var manager: IOHIDManager?
    private var iconAnimation: Task<Void, Never>?
    /// The last source observed at all, so a notification that changed nothing is ignored —
    /// input methods fire them on focus changes, long after the switch they belong to.
    private var lastKnownSourceID: String?
    /// The current input source, kept in sync by `select` and the change observer, so
    /// the tap's per-keystroke check never has to ask TIS.
    private var cachedSourceID: String?
    /// Registry entry ID -> device id, for identifying the sender of a tapped event.
    private var senderIDs: [UInt64: String] = [:]
    private let tap = KeyEventTap()
    /// Which "on external layout change" action turned the app off — `.disable` or `.pause`,
    /// nil when the app is not auto-off. Drives the popover info box, and the pause mark for
    /// `.pause` only. Cleared when the user re-enables. Persisted so a relaunch keeps the reason.
    @Published private(set) var autoDisabled: ExternalChangeAction? {
        didSet { defaults.set(autoDisabled?.rawValue, forKey: Key.autoDisabled) }
    }
    /// Whether the status item currently shows the disabled mark (drives the toggle animation).
    private var iconShowsDisabled = false
    /// The Accessibility prompt only appears once; after that the notice goes to Settings.
    private var didPromptForAccessibility = false
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    private init() {
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
        externalChangeAction = ExternalChangeAction(rawValue: defaults.string(forKey: Key.externalChangeAction) ?? "") ?? .ignore
        autoDisabled = ExternalChangeAction(rawValue: defaults.string(forKey: Key.autoDisabled) ?? "")
        switchTiming = SwitchTiming(rawValue: defaults.string(forKey: Key.switchTiming) ?? "") ?? .after
        // Via a local, not by reading `launchAtLogin` back: touching a property with observers
        // needs `self` fully initialized, and not every stored property is set yet.
        let alreadyRegistered = SMAppService.mainApp.status == .enabled
        launchAtLogin = alreadyRegistered
        offersLaunchAtLogin = !defaults.bool(forKey: Key.didOfferLaunchAtLogin) && !alreadyRegistered
        showsMenuBarItem = defaults.object(forKey: Key.showsMenuBarItem) as? Bool ?? true

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

    // MARK: - Windows
    //
    // One `ContentView`, two containers. With the menu bar item on, its panel is the whole
    // UI (see `KeychangeApp`) — no separate window, no duplicate menu. This window is the
    // other container: what you get with the item turned off, and the fallback for a
    // relaunch, since a `MenuBarExtra` panel cannot be opened programmatically.
    //
    // Plain AppKit rather than a SwiftUI `Window` scene, because those are restored at
    // login — exactly when a headless app should show nothing — and `openWindow` is
    // unreachable from the delegate that handles a relaunch.

    /// **Never opens while the menu bar item is on.** The item is the app's presence and its
    /// panel is the settings; a window alongside it is a second copy of the same thing. Every
    /// caller goes through here, so the rule holds however the request arrives.
    func showSettings() {
        guard !showsMenuBarItem else { return }
        show(&settingsWindow, title: "Keychange") { ContentView(inWindow: true) }
    }

    func showAbout() {
        show(&aboutWindow, title: "About Keychange") { AboutView() }
    }

    /// SwiftUI hands out no reference to the `MenuBarExtra` panel, so it has to be found.
    /// No private class names needed: it is the visible window we did not make ourselves,
    /// floating above the normal window level the way a menu bar panel does.
    private func dismissMenuBarPanel() {
        for window in NSApp.windows
        where window !== settingsWindow && window !== aboutWindow
            && window.isVisible && window.level != .normal {
            window.orderOut(nil)
        }
    }

    private func show<Content: View>(_ window: inout NSWindow?, title: String,
                                     @ViewBuilder content: () -> Content) {
        // LSUIElement: without activating, the window opens behind everything.
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Built around a hosting *controller*, not a bare NSHostingView: that is what
        // sizes the window to the SwiftUI content. Handed a contentRect instead, the
        // window keeps whatever size it was given — and .zero means an invisible window.
        let new = NSWindow(contentViewController: NSHostingController(
            rootView: content().environmentObject(self)))
        // Set after the initialiser, which hands out a resizable, miniaturizable window:
        // dropping both makes those two buttons the inert dots a panel should have.
        new.styleMask = [.titled, .closable, .fullSizeContentView]
        new.title = title
        new.titlebarAppearsTransparent = true
        new.titleVisibility = .hidden
        new.isMovableByWindowBackground = true
        // Closing a window that owns itself would deallocate it under our reference.
        new.isReleasedWhenClosed = false
        new.center()
        new.makeKeyAndOrderFront(nil)
        window = new
    }

    // MARK: - Public API

    /// A binding that drops a write of the value already there.
    ///
    /// SwiftUI hands the current value back during its own update passes, and `@Published`
    /// announces a change on every assignment, equal or not — so a plain binding lets
    /// SwiftUI invalidate the very view that just wrote it. `MenuBarExtra(isInserted:)`
    /// does exactly that on every main-menu rebuild, which spins the main thread solid.
    /// A guard in the `didSet` is too late: `objectWillChange` has already fired by then.
    func binding<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] },
                set: { if self[keyPath: keyPath] != $0 { self[keyPath: keyPath] = $0 } })
    }

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

    /// The offer closes in `launchAtLogin`'s `didSet`, which fires on any set — including this one.
    func acceptLaunchAtLogin() { launchAtLogin = true }

    func declineLaunchAtLogin() { closeLaunchAtLoginOffer() }

    private func closeLaunchAtLoginOffer() {
        defaults.set(true, forKey: Key.didOfferLaunchAtLogin)
        offersLaunchAtLogin = false
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

    /// User-initiated, like `openInputMonitoringSettings`, and for the same reason: the prompt
    /// is what registers the app in the Accessibility list (apps that never ask don't appear
    /// there). It won't show a second time once dismissed, so from then on go to Settings,
    /// where the checkbox is.
    ///
    /// ponytail: the flag is in-memory while the system's suppression of that prompt outlives
    /// the launch, so the first click after a relaunch (still untrusted) does nothing visible
    /// and the second opens Settings. Persist the flag if that ever matters.
    func openAccessibilitySettings() {
        if !didPromptForAccessibility, !AXIsProcessTrusted() {
            didPromptForAccessibility = true
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return
        }
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

    /// The tap only runs while "Before key press" is selected and we may switch at all.
    /// `isEnabled` is part of that on purpose: off has to mean the key presses stop passing
    /// through us, not merely that we hand them back untouched. Pause still lifts itself
    /// without the tap — `handle` takes over the device tracking whenever it isn't running.
    private func updateTap() {
        guard isEnabled, switchTiming == .before, hasPermission else {
            tap.stop()
            tapFailed = false
            return
        }
        // An active tap needs Accessibility on top of Input Monitoring, but picking an option
        // must not throw a system dialog at you: `tapCreate` simply fails without it, which is
        // what `tapFailed` reports. The popover's notice is then where access gets asked for.
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
        // A device that's gone must not keep the accent rail lit. Clearing this also means
        // replugging it counts as a change again, so it re-applies its mapping.
        if let active = activeDeviceID, !devices.contains(where: { $0.id == active }) {
            activeDeviceID = nil
        }
    }

    /// Both key-press callbacks land here, in no guaranteed order. Keeps `activeDeviceID`
    /// current on every press; when `switching` — this path is the one that will act —
    /// consumes the device change and returns the source to switch to, nil for nothing to do.
    /// The non-switching path can only ever clear the flag, never claim it, which is what
    /// stops one callback from swallowing the other's device change.
    private func keyPressed(on id: String, switching: Bool) -> String? {
        if activeDeviceID != id {
            activeDeviceID = id
            mappingApplied = false
        }
        guard switching, !mappingApplied else { return nil }
        mappingApplied = true
        resumeIfMatched(id)
        guard isEnabled, let wanted = settings[id]?.source, wanted != cachedSourceID else { return nil }
        return wanted
    }

    private func handle(_ value: IOHIDValue) {
        let id = Self.keyboard(for: IOHIDElementGetDevice(IOHIDValueGetElement(value))).id
        // The tap switches instead when it can, from inside the keystroke, so the first
        // character is already in the new layout. Secure input starves the tap of events, so
        // take the whole job back then.
        if let wanted = keyPressed(on: id, switching: !tap.isRunning || IsSecureEventInputEnabled()) {
            select(wanted)
        }
    }

    /// Switches to the device's mapped source if it isn't already active.
    /// Shared by the HID path and the event tap.
    private func applySwitch(for deviceID: String) {
        guard isEnabled, let wanted = settings[deviceID]?.source, wanted != cachedSourceID else { return }
        select(wanted)
    }

    /// Drops the keyboard being typed on, so the next press counts as a device change again and
    /// re-applies its mapping under whatever the settings now say. `mappingApplied` re-arms by
    /// construction, since any next press differs from nil. The rail going out is what shows it.
    private func forgetActiveDevice() {
        activeDeviceID = nil
    }

    /// A pause lifts itself: as soon as the current source is the one the keyboard being
    /// typed on maps to, switching resumes. Called from every path that can make the two
    /// meet — the source changing (observer) and the typing device changing (above).
    private func resumeIfMatched(_ deviceID: String?) {
        guard autoDisabled == .pause, let deviceID,
              let wanted = settings[deviceID]?.source, wanted == cachedSourceID else { return }
        isEnabled = true // didSet clears autoDisabled
    }

    /// Called from inside the key press, so it must stay cheap: a dictionary lookup and a
    /// string compare, touching TIS only when a switch actually happens.
    private func decideTapKeyDown(senderID: UInt64?) -> KeyDecision {
        guard let id = senderID.flatMap({ senderIDs[$0] }) ?? activeDeviceID,
              let wanted = keyPressed(on: id, switching: true),
              let source = Self.inputSource(id: wanted) else { return .pass }
        select(wanted)
        // A plain layout can be applied to this very key press by re-translating it. An input
        // method composes from key codes when the event is delivered, so the press has to wait
        // until the switch has actually taken effect.
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
            let mark = autoDisabled
            if hadIcon {
                let code = menuBarCode
                animateIcon { MenuBarMark.enableFrame(t: $0, code: code, autoDisabled: mark) }
            } else {
                menuBarIcon = MenuBarMark.disabled(autoDisabled: mark)
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
            let mark = autoDisabled
            animateIcon { MenuBarMark.enableFrame(t: 1 - $0, code: newCode, autoDisabled: mark) }
        } else if hadIcon, oldCode != newCode, oldCode != "—" {
            animateIcon { MenuBarMark.swapFrame(t: $0, from: oldCode, to: newCode) }
        } else {
            menuBarIcon = MenuBarMark.badge(newCode)
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

    /// Also catches input source changes the user makes by hand (or via the system UI).
    /// `.deliverImmediately` is why this uses the selector API. The block-based
    /// `addObserver(forName:object:queue:)` registers with the default coalescing behaviour, and
    /// AppKit suspends distributed notifications while an app is in the background — which, for a
    /// menu bar app, is always. Switches Keychange makes itself still arrived, so the mark tracked
    /// those and silently ignored every layout change made anywhere else.
    private func observeInputSourceChanges() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func inputSourceDidChange() {
        // Fires for every source change, our own included; the conflict test below is what
        // separates them, and `externalChangeAction` decides what a conflict means.
        cachedSourceID = currentSourceID
        // The switch has landed — deliver anything the tap withheld for it.
        tap.releaseHeldEvents()
        if let current = cachedSourceID, current != lastKnownSourceID {
            lastKnownSourceID = current
            // Three cases. No active keyboard (nothing typed yet, or just re-enabled):
            // nothing vouches for the new layout, so treat it as a conflict. A keyboard
            // set to "Don't switch": its layout was never ours to defend, so it never
            // conflicts. Otherwise it comes down to whether the new source is the one
            // that keyboard is mapped to — landing on the layout we would have picked
            // anyway is nothing to step aside for, which is also why our own switches
            // need no "did we do it?" bookkeeping to be ignored here.
            let device = activeDeviceID
            let target = device.flatMap { settings[$0]?.source }
            if device == nil || (target != nil && target != current) {
                switch externalChangeAction {
                case .ignore:
                    break
                case .reset:
                    // "Mapping wins": the keyboard's own source comes back on the next press.
                    forgetActiveDevice()
                case .disable, .pause:
                    // Nothing is forgotten: the keyboard stays selected so pause knows
                    // what to match against, and so re-enabling can apply its mapping
                    // straight away.
                    if isEnabled {
                        autoDisabled = externalChangeAction
                        isEnabled = false
                    }
                }
            }
            // Outside the conflict check on purpose: a pause ends when the source comes
            // back to the keyboard's target, which is exactly the case that check skips.
            resumeIfMatched(activeDeviceID)
        }
        refreshInputSources()
        refreshMenuBarCode()
    }

    private static func property(_ source: TISInputSource, _ key: CFString!) -> Any? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
