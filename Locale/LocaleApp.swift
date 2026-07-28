import SwiftUI

@main
struct LocaleApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(state)
        } label: {
            Text(state.menuBarCode)
        }
        .menuBarExtraStyle(.window)
    }
}
