import AppKit
import UniformTypeIdentifiers

/// Makes PiDF the app that opens PDF documents.
///
/// macOS asks the user to confirm every change of default app, so this runs
/// inside the normal app (never unattended) and waits for the answer.
@MainActor
enum DefaultViewer {
    private static let askedKey = "AskedToBecomeDefault"

    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: .pdf) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// On first launch, offers once to become the default PDF viewer.
    static func offerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey), !isDefault else { return }
        defaults.set(true, forKey: askedKey)
        let alert = NSAlert()
        alert.messageText = "Open your PDFs with PiDF?"
        alert.informativeText = "PiDF can become the default app for PDF documents. macOS will ask you to confirm."
        alert.addButton(withTitle: "Use PiDF")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await makeDefault(quitWhenDone: false) }
        }
    }

    /// Asks macOS to make PiDF the default for PDFs and waits (up to two
    /// minutes) for the user to confirm. With `quitWhenDone` (the install
    /// script), PiDF quits afterwards.
    static func makeDefault(quitWhenDone: Bool) async {
        UserDefaults.standard.set(true, forKey: askedKey)
        NSApp.activate()
        if !isDefault {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf)
                let deadline = Date().addingTimeInterval(120)
                while !isDefault && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            } catch {}
        }
        let alert = NSAlert()
        alert.messageText = isDefault ? "PiDF now opens your PDFs." : "PDFs still open in another app."
        alert.informativeText = isDefault ? "" : "You can change it in Finder: Get Info › Open with › Change All."
        alert.runModal()
        if quitWhenDone { NSApp.terminate(nil) }
    }
}
