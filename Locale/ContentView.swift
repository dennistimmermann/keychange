import SwiftUI

/// The popover content of the menu bar item.
///
/// Layout follows `design-handoff/README.md` (approved design `3c`, empty state `3b`).
/// Everything is built from stock SwiftUI controls and system semantic colors so the
/// panel inherits the popover material and works in dark mode without extra work.
@MainActor
struct ContentView: View {
    @EnvironmentObject var state: AppState

    /// Empty state doubles as the "no permission" state: in both cases there is
    /// nothing to list, and the call to action is the same.
    private var showsEmptyState: Bool {
        !state.hasPermission || state.devices.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if showsEmptyState {
                emptyState
            } else {
                deviceList
                    // Master switch off: the list dims but stays interactive.
                    .opacity(state.isEnabled ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.2), value: state.isEnabled)
            }

            Divider()
                .padding(.vertical, 5)
                .padding(.horizontal, 9)

            settingsSection
        }
        .padding(6)
        .frame(width: 344)
        // MenuBarExtra(.window) proposes the previous (larger) height after the
        // settings foldout closes; without this the device list stretches to fill it.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("LOCALE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.66) // 0.06em at 11pt
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(state.devices.isEmpty ? "None connected" : "\(state.devices.count) connected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("Enable Locale", isOn: $state.isEnabled)
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
            ForEach(state.devices) { device in
                deviceRow(device)
            }
        }
    }

    private func deviceRow(_ device: Keyboard) -> some View {
        let isActive = device.id == state.activeDeviceID

        // Rows are not click targets — the active device comes from real key events.
        return HStack(spacing: 0) {
            // Leading rail. Always present so names stay aligned; only coloured when active.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isActive ? Color(nsColor: .systemGreen) : Color.clear)
                .frame(width: 3)
                .padding(.trailing, 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if state.showDeviceDetails {
                    Text("VID \(hex4(device.vendorID))   PID \(hex4(device.productID))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Input source", selection: mappingBinding(for: device)) {
                Text("Don't switch").tag(String?.none)
                Divider()
                ForEach(state.inputSources) { source in
                    Text(source.name).tag(Optional(source.id))
                }
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

    /// Reads the stored mapping, writes through `AppState`. `nil` means "Don't switch".
    /// A mapping whose source is no longer enabled shows as "Don't switch" (instead of an
    /// invalid picker selection) but stays stored, so it revives when the source returns.
    private func mappingBinding(for device: Keyboard) -> Binding<String?> {
        Binding(
            get: {
                guard let id = state.mapping[device.id],
                      state.inputSources.contains(where: { $0.id == id }) else { return nil }
                return id
            },
            set: { state.setMapping(deviceID: device.id, sourceID: $0) }
        )
    }

    /// `0x05AC`-style, uppercase, zero padded to four digits.
    private func hex4(_ value: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "keyboard")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No keyboards detected")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))

            if !state.hasPermission {
                Text("Locale needs Input Monitoring access to see which keyboard you are typing on.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Allow Input Monitoring…") {
                    state.openInputMonitoringSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            settingsToggle("Show device details", isOn: $state.showDeviceDetails)
            settingsToggle("Launch at login", isOn: $state.launchAtLogin)

            Button(action: state.quit) {
                Text("Quit Locale")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .labelColor))
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
    }
}
