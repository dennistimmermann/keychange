import SwiftUI

@main
struct KeychangeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Initialising this is what starts the HID monitor, whether or not the scene below
    // is ever inserted — a headless launch deliberately shows nothing at all, and
    // launching again is what brings the settings window back.
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        // `isInserted` must go through `AppState.binding` — SwiftUI writes it back on every
        // main-menu rebuild, and a plain `$state.foo` binding spins the main thread solid.
        MenuBarExtra(isInserted: state.binding(\.showsMenuBarItem)) {
            ContentView().environmentObject(state)
        } label: {
            if let icon = state.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Text(state.menuBarCode)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Launching Keychange while it is already running is the way back in when the menu bar
    /// item is off. Launch Services turns that second launch into this, rather than a
    /// second process.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppState.shared.showSettings()
        return true
    }

    /// Closing the settings is not quitting: the whole app is what happens while nothing
    /// is on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
