import SwiftUI

/// The popover content of the menu bar item.
///
/// Layout follows `design-handoff/README.md` (approved design `3c`, empty state `3b`).
/// Everything is built from stock SwiftUI controls and system semantic colors so the
/// panel inherits the popover material and works in dark mode without extra work.
@MainActor
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    /// Hold ⌥ while opening the panel to reveal the device IDs, like the system's own
    /// applets (Wi-Fi, Battery) do. Sampled once per open; the cog does not set it.
    @State private var optionHeld = false

    /// The settings section, which only the cog opens. Also brings hidden devices back,
    /// since un-hiding one is a settings job.
    @State private var settingsExpanded = false

    /// Which devices were hidden when this open began. Hiding one leaves it on screen
    /// until the next open — a row must not vanish under the picker you just used.
    @State private var hiddenSnapshot: Set<String> = []

    @State private var cogHovered = false

    /// Shown when the switch timing is *changed* to "Before key press" — not merely when it is
    /// selected, so a launch with it already on says nothing. Dismissed by clicking it, and
    /// nothing remembers that: changing to "Before key press" again brings it back.
    @State private var showInterceptNotice = false


    /// The picker's tag for "Hidden". Not a source ID (those are reverse-DNS).
    private static let hiddenTag = "hidden"

    /// Hidden devices come back whenever the panel is in a configuring mood — ⌥ or the
    /// open settings — which is the way back for a device hidden by mistake.
    private var visibleDevices: [Keyboard] {
        optionHeld || settingsExpanded
            ? state.devices
            : state.devices.filter { !hiddenSnapshot.contains($0.id) }
    }

    /// Empty state doubles as the "no permission" state: in both cases there is
    /// nothing to list, and the call to action is the same.
    private var showsEmptyState: Bool {
        !state.hasPermission || state.devices.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if state.autoDisabled == .pause {
                infoBox("Paused — the input source was changed by something other than Keychange. It resumes on its own once the input source matches your keyboard again.",
                        symbol: "pause.circle", actionLabel: "Resume now") {
                    state.isEnabled = true
                }
            } else if state.autoDisabled == .disable {
                infoBox("Disabled — the input source was changed by something other than Keychange.",
                        symbol: "power", actionLabel: "Re-enable", tint: .blue) {
                    state.isEnabled = true
                }
            }

            if showsEmptyState {
                emptyState
            } else {
                // Above the list rather than replacing it: switching still works, it just
                // lands after the key press until access is granted.
                if state.tapFailed { accessibilityPrompt }

                deviceList
                    // The prompts have their own generous padding and the settings
                    // rows bring theirs, so only the bare list needs this back.
                    .padding(.bottom, settingsExpanded || needsMoreSources ? 0 : 4)
            }

            if settingsExpanded || needsMoreSources {
                Divider()
                    .padding(.vertical, 5)
                    .padding(.horizontal, 9)

                if settingsExpanded {
                    settingsSection
                } else {
                    addInputSourcesButton
                }
            }
        }
        .padding(6)
        .frame(width: 344)
        // MenuBarExtra(.window) proposes the previous (larger) height after the
        // settings foldout closes; without this the device list stretches to fill it.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: sampleOpenState)
        // onAppear alone misses reopens when SwiftUI keeps the view alive, so also
        // re-sample whenever the panel becomes the key window.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            sampleOpenState()
        }
    }

    /// What the panel decides once per open: the ⌥ reveal and which rows are hidden.
    private func sampleOpenState() {
        optionHeld = NSEvent.modifierFlags.contains(.option)
        hiddenSnapshot = Set(state.settings.filter(\.value.hidden).keys)
        state.refreshDevices()
        state.refreshInputSources()
        state.retryTapIfNeeded()
    }

    /// Centered symbol + title block, used for anything the app can't do yet.
    private func prompt<Content: View>(symbol: String, title: String,
                                       @ViewBuilder body: () -> Content) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))

            body()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func promptBody(_ message: String, action title: String, _ action: @escaping () -> Void) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

        Button(title, action: action)
            .buttonStyle(.link)
            .font(.system(size: 12))
    }

    /// Notice under the header: a compact status, as opposed to `prompt`, which blocks. It
    /// borrows the prompt's vocabulary — a symbol, the action in accent colour — but not its
    /// size, since pausing happens routinely and the device list stays the point. `actionLabel`
    /// runs on as the last words of `text` instead of being its own button, because the whole
    /// box is already the click target.
    ///
    /// `tint` is what makes a notice louder than the plain grey one, and is spent sparingly so
    /// it keeps meaning something: yellow warns about a cost you are taking on, blue says
    /// switching has stopped until you do something. A state that heals itself stays grey.
    private func infoBox(_ text: String, symbol: String, actionLabel: String? = nil,
                         tint: Color? = nil, action: (() -> Void)? = nil) -> some View {
        var label = Text(text)
        if let actionLabel {
            label = label + Text(" ") + Text(actionLabel).foregroundStyle(Color.accentColor)
        }

        return Button { action?() } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    // Nudged onto the first line's cap height; the symbol's own box sits high.
                    .padding(.top, 1)

                label
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11))
            .foregroundStyle(tint == nil ? .secondary : .primary)
            .padding(8)
            .background(tint.map { AnyShapeStyle($0.opacity(0.22)) } ?? AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .padding(.horizontal, 3)
        .padding(.bottom, 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // Display name, so the Debug build reads "KEYCHANGE DEV".
            Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Keychange").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.66) // 0.06em at 11pt
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            cogButton

            Toggle("Enable Keychange", isOn: $state.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.top, 4)
        .padding(.horizontal, 9)
        .padding(.bottom, 6)
    }

    // MARK: - Device list

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleDevices) { device in
                deviceRow(device)
            }
        }
    }

    private func deviceRow(_ device: Keyboard) -> some View {
        let isActive = device.id == state.activeDeviceID
        // Live, not the snapshot: the row dims the moment you hide it, and stays dim
        // when ⌥ brings it back.
        let isHidden = state.isHidden(device.id)

        // Rows are not click targets — the active device comes from real key events.
        // Grey while switched off: the rail still says which keyboard you are typing on —
        // that keeps being tracked — but accent would claim we are acting on it.
        let rail: Color = !isActive ? .clear
            : state.isEnabled ? .accentColor : Color(nsColor: .secondaryLabelColor)

        return HStack(spacing: 0) {
            // Leading rail. Always present so names stay aligned; only coloured when active.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(rail)
                .frame(width: 3)
                .padding(.trailing, 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: isHidden ? .secondaryLabelColor : .labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if optionHeld {
                    // `vid:pid`, the notation every USB tool uses. Spelled out as
                    // "VID 0x… PID 0x…" it does not fit the name column beside the picker.
                    Text(String(format: "%04lX:%04lX", device.vendorID, device.productID))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Input source", selection: settingBinding(for: device)) {
                Text("Don't switch").tag(String?.none)
                Divider()
                ForEach(state.inputSources) { source in
                    Text(source.name).tag(Optional(source.id))
                }
                Divider()
                // Reads as the selected value, like "Don't switch" — not as a verb.
                Text("Hidden").tag(Optional(Self.hiddenTag))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            // Not intrinsic: a popup button is as wide as its widest *menu item*, so one long
            // source name ("U.S. with Umlauts") widens the whole column. Long names truncate.
            .frame(width: 130)
            .padding(.leading, 8)
        }
        .padding(.vertical, 6)
        .padding(.trailing, 9)
    }

    /// Reads the stored setting, writes through `AppState`. `nil` means "Don't switch".
    /// A mapping whose source is no longer enabled shows as "Don't switch" (instead of an
    /// invalid picker selection) but stays stored, so it revives when the source returns.
    private func settingBinding(for device: Keyboard) -> Binding<String?> {
        Binding(
            get: {
                if state.isHidden(device.id) { return Self.hiddenTag }
                guard let id = state.settings[device.id]?.source,
                      state.inputSources.contains(where: { $0.id == id }) else { return nil }
                return id
            },
            set: {
                if $0 == Self.hiddenTag { state.setHidden(deviceID: device.id) }
                else { state.setMapping(deviceID: device.id, sourceID: $0) }
            }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        prompt(symbol: "keyboard", title: "No keyboards detected") {
            if !state.hasPermission {
                promptBody("Keychange needs Input Monitoring access to see which keyboard you are typing on.",
                           action: "Allow Input Monitoring…", state.openInputMonitoringSettings)
            }
        }
    }

    private var accessibilityPrompt: some View {
        prompt(symbol: "hand.raised", title: "Accessibility access needed") {
            promptBody("Keychange needs Accessibility access to intercept key presses to change the layout early.",
                       action: "Allow Accessibility…", state.openAccessibilitySettings)
        }
    }

    // MARK: - Settings

    /// Bare glyph in the header, left of the master switch. Clicking it is the same
    /// reveal ⌥-opening the panel gives, just reachable without closing it first.
    private var cogButton: some View {
        Button {
            settingsExpanded.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: cogHovered ? .labelColor : .secondaryLabelColor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { cogHovered = $0 }
        .accessibilityLabel(settingsExpanded ? "Hide settings" : "Show settings")
    }

    /// With one enabled input source there is nothing to switch between, so this
    /// row stays visible even while the settings are collapsed.
    private var needsMoreSources: Bool {
        state.inputSources.count < 2
    }

    private var addInputSourcesButton: some View {
        settingsButton("Add Input Sources…", action: state.openKeyboardSettings)
    }

    /// Commands are link-style buttons, the same style the permission prompts use,
    /// so they read as clickable next to the switch rows, which don't react to hover.
    private func settingsButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .font(.system(size: 13))
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            settingsPicker("Switch layout", selection: switchTimingBinding,
                           hint: """
                                 When Keychange applies the new keyboard's input source.
                                 After key press: Keychange only watches which keyboard you are typing on and needs no further access, but the character that triggered the switch still uses the previous layout.
                                 Before key press: Keychange intercepts every key press you make, before the app you are typing in receives it — it rewrites the character, and briefly withholds the key press when switching to another input method. Needs Accessibility access.
                                 """)
            if showInterceptNotice {
                infoBox("In this mode Keychange reads and may alter every key press, except in password fields. Needs Accessibility access.",
                        symbol: "exclamationmark.triangle", tint: .yellow) {
                    showInterceptNotice = false
                }
                // infoBox insets by 3; the settings rows sit at 9.
                .padding(.horizontal, 6)
            }
            settingsPicker("On external layout change", selection: $state.externalChangeAction,
                           hint: """
                                 What Keychange does when you change the input source yourself — via the Input menu or a keyboard shortcut.
                                 Disable: turn off until you turn it back on with the master switch.
                                 Pause: turn off, then resume by itself once the input source matches the keyboard you are typing on again.
                                 Ignore: keep your choice, and leave it until you switch to another keyboard.
                                 Reset: keep your choice until the next key press, which restores the keyboard's own input source.
                                 """)
            settingsToggle("Launch at login", isOn: $state.launchAtLogin)
            settingsToggle("Check for updates automatically", isOn: $state.automaticallyChecksForUpdates)

            Divider()
                .padding(.vertical, 5)
                .padding(.horizontal, 9)

            addInputSourcesButton
            // "Check for Updates…" lives in the About panel, next to the version it acts on.
            settingsButton("About") {
                // LSUIElement: without activating, the panel opens behind everything.
                NSApp.activate()
                openWindow(id: AboutWindow.id)
            }
            settingsButton("Quit", action: state.quit)
        }
    }

    /// The shared row shell: title (plus ⓘ when there's a `hint` — the tooltip itself covers
    /// the whole row), a spacer, and the trailing control. Settings-panel pattern: the control
    /// is the control, the row itself is inert.
    private func settingsRow(_ title: String, hint: String? = nil,
                             @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .labelColor))
                if hint != nil {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .help(hint ?? "")
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>, hint: String? = nil) -> some View {
        settingsRow(title, hint: hint) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    /// Writes through to `AppState`, and raises the notice as a side effect of the change —
    /// which is what keeps it off the screen until you actually pick something.
    ///
    /// The equality guard keeps a redundant write from counting as a change: SwiftUI is free to
    /// write the current selection back, and `switchTiming`'s didSet fires on any assignment,
    /// equal or not — which would raise the notice and restart the tap for nothing.
    private var switchTimingBinding: Binding<SwitchTiming> {
        Binding(
            get: { state.switchTiming },
            set: {
                guard $0 != state.switchTiming else { return }
                showInterceptNotice = ($0 == .before)
                state.switchTiming = $0
            }
        )
    }

    /// Same row as `settingsToggle`, with a menu picker in place of the switch.
    private func settingsPicker<Option: SettingsOption>(_ title: String, selection: Binding<Option>,
                                                        hint: String? = nil) -> some View {
        settingsRow(title, hint: hint) {
            Picker(title, selection: selection) {
                ForEach(Array(Option.allCases), id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

}
