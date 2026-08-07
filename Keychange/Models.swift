import Foundation

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

/// A setting that is "pick one of a few named options" — all the settings row needs to know.
protocol SettingsOption: Hashable, CaseIterable {
    var title: String { get }
}

/// What to do when the input source is changed outside the app (system Input menu, shortcut).
enum ExternalChangeAction: String, SettingsOption {
    /// Turn off until the user re-enables by hand.
    case disable
    /// Turn off, but keep watching and resume once the source matches the active keyboard again.
    case pause
    /// Leave it be — the external source stays until another keyboard takes over.
    case ignore
    /// Forget the active device, so the next keystroke re-applies its mapping.
    case reset

    var title: String { rawValue.capitalized }
}

/// When the switch to the new keyboard's input source lands, relative to the key press
/// that triggered it.
enum SwitchTiming: String, SettingsOption {
    /// Switch once the press has been delivered — its character still uses the old layout.
    case after
    /// Intercept the press, switch, and fix the character before the app sees it.
    /// Needs Accessibility.
    case before

    var title: String { self == .after ? "After key press" : "Before key press" }
}
