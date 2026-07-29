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

    /// One reveal, covering the settings, hidden devices and the device IDs. Holding ⌥
    /// while opening the panel starts in it — like the system's own applets (Wi-Fi,
    /// Battery) — and the cog toggles it once the panel is open.
    @State private var revealed = false

    /// Which devices were hidden when this open began. Hiding one leaves it on screen
    /// until the next open — a row must not vanish under the picker you just used.
    @State private var hiddenSnapshot: Set<String> = []

    @State private var cogHovered = false

    /// The picker's tag for "Hidden". Not a source ID (those are reverse-DNS).
    private static let hiddenTag = "hidden"

    /// ⌥ shows everything, which is the way back for a device hidden by mistake.
    private var visibleDevices: [Keyboard] {
        revealed ? state.devices : state.devices.filter { !hiddenSnapshot.contains($0.id) }
    }

    /// Empty state doubles as the "no permission" state: in both cases there is
    /// nothing to list, and the call to action is the same.
    private var showsEmptyState: Bool {
        !state.hasPermission || state.devices.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if state.autoDisabled {
                infoBox("Disabled — the input source was changed outside Keychange. Click to re-enable.") {
                    state.isEnabled = true
                }
            }

            if showsEmptyState {
                emptyState
            } else if state.tapFailed {
                accessibilityPrompt
            } else {
                deviceList
            }

            if revealed {
                Divider()
                    .padding(.vertical, 5)
                    .padding(.horizontal, 9)

                settingsSection
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
        revealed = NSEvent.modifierFlags.contains(.option)
        hiddenSnapshot = Set(state.settings.filter(\.value.hidden).keys)
        state.refreshDevices()
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

    /// Notice under the header. With an action the whole box is clickable.
    private func infoBox(_ text: String, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
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
        return HStack(spacing: 0) {
            // Leading rail. Always present so names stay aligned; only coloured when active.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 3)
                .padding(.trailing, 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: isHidden ? .secondaryLabelColor : .labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if revealed {
                    Text("VID \(hex4(device.vendorID))   PID \(hex4(device.productID))")
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
            .fixedSize()
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

    /// `0x05AC`-style, uppercase, zero padded to four digits.
    private func hex4(_ value: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
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
            promptBody("Keychange needs Accessibility access to correct the first character you type after switching keyboards.",
                       action: "Allow Accessibility…", state.openAccessibilitySettings)
        }
    }

    // MARK: - Settings

    /// Bare glyph in the header, left of the master switch. Clicking it is the same
    /// reveal ⌥-opening the panel gives, just reachable without closing it first.
    private var cogButton: some View {
        Button {
            revealed.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: cogHovered ? .labelColor : .secondaryLabelColor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { cogHovered = $0 }
        .accessibilityLabel(revealed ? "Hide settings" : "Show settings")
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            settingsToggle("Intercept keystrokes", isOn: $state.instantSwitching,
                           hint: "Fixes the first character, which otherwise still uses the previous layout. To do that Keychange must intercept every key press you make, system-wide, before the app you are typing in receives it — it rewrites the character, and briefly withholds the key press when switching to an input method like Korean. Requires Accessibility access. Leave this off unless the wrong first character bothers you.")
            settingsToggle("Auto-disable on external switch", isOn: $state.autoDisableOnExternalSwitch,
                           hint: "When you change the input source yourself — via the Input menu or a keyboard shortcut — Keychange turns itself off instead of switching back while you type. Turn the master switch on again to resume automatic switching.")
            settingsToggle("Launch at login", isOn: $state.launchAtLogin)
            settingsToggle("Check for updates automatically", isOn: $state.automaticallyChecksForUpdates)

            // "Check for Updates…" lives in the About panel, next to the version it acts on.
            settingsButton("About Keychange") {
                // LSUIElement: without activating, the panel opens behind everything.
                NSApp.activate()
                openWindow(id: AboutWindow.id)
            }
            settingsButton("Quit", action: state.quit)
        }
    }

    private func settingsButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `hint` adds an ⓘ marking the row as hoverable — the tooltip itself covers the whole row.
    private func settingsToggle(_ title: String, isOn: Binding<Bool>, hint: String? = nil) -> some View {
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
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .help(hint ?? "")
    }
}
