import SwiftUI

@main
struct KeychangeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(state)
        } label: {
            if let icon = state.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Text(state.menuBarCode)
            }
        }
        .menuBarExtraStyle(.window)

        Window("About Keychange", id: AboutWindow.id) {
            AboutView().environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum AboutWindow {
    static let id = "about"
}
