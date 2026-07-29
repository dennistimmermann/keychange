import SwiftUI

/// The About panel, per `design-handoff/about/README.md` (design 13b): mark, name,
/// slogan, version metadata, two link rows, footer. Fixed size, no titlebar.
struct AboutView: View {

    // Edit these three in place; nothing else hardcodes them.
    private let slogan = "Switches the input source per keyboard."
    private let repoURL = URL(string: "https://github.com/dennistimmermann/keychange")!
    private let coffeeURL = URL(string: "https://buymeacoffee.com/dtimmermann")!

    private let upstreamURL = "https://github.com/ohueter/autokbisw"

    @State private var hoveredLink: URL?

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 120, height: 120)
                .padding(.top, 40)

            Text("Keychange")
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.675) // -0.025em
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.top, 22)

            Text(slogan)
                .font(.system(size: 13.5))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
                .padding(.horizontal, 36)

            metaRow
                .padding(.top, 14)

            Divider()
                .padding(.top, 22)
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                linkRow("GitHub repository", detail: repoURL.host.map { $0 + repoURL.path } ?? "", url: repoURL)
                linkRow("Keychange is free — buy me a coffee", detail: "", url: coffeeURL)
            }
            .padding(.top, 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            Spacer(minLength: 0)

            footer
        }
        .frame(width: 420, height: 427)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowChrome())
    }

    /// `Version 1.0 · Build 1 · MIT`, read from the bundle.
    private var metaRow: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return HStack(spacing: 7) {
            ForEach(Array(["Version \(version)", "Build \(build)", "MIT"].enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·").opacity(0.5)
                }
                Text(item)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    /// Whole row is the hit target; the ↗ is a glyph, not a button.
    private func linkRow(_ label: String, detail: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Spacer(minLength: 8)
                Text(detail.isEmpty ? "↗" : "\(detail) ↗")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(hoveredLink == url ? Color(nsColor: .quaternaryLabelColor).opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hoveredLink = $0 ? url : nil }
        .accessibilityLabel("\(label), opens \(url.host ?? url.absoluteString)")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Text("Inspired by [autokbisw](\(upstreamURL)) by @ohueter.")
            Text("© 2026 Dennis Timmermann")
        }
        .font(.system(size: 11))
        .lineSpacing(6.6) // 1.6 line-height at 11pt
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
        .padding(.horizontal, 32)
        .padding(.bottom, 22)
    }
}

/// About-panel window chrome: no title, transparent titlebar, and only the close
/// button live — minimise and zoom render as inert dots.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.isMovableByWindowBackground = true
        }
    }
}
