import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controllers: [DocumentWindowController] = []
    /// Launched by the install script to become the default PDF viewer.
    private let settingDefault = CommandLine.arguments.contains("--make-default")
    /// True while the app hosts the unit tests: no Open panel, no quitting.
    private let hostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        if hostingTests {
            // The tests never touch the reading positions of the real app.
            UserDefaults.standard.removePersistentDomain(forName: "PiDFTests")
            ReadingPositions.defaults = UserDefaults(suiteName: "PiDFTests") ?? .standard
        }
        UserDefaults.standard.register(defaults: [
            // Keep the menus to what PiDF actually does.
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
            "NSFullScreenMenuItemEverywhere": false,
            "NSQuitAlwaysKeepsWindows": false,
        ])
        // Native tabs: AppKit adds the tab commands to the Window menu.
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settingDefault {
            Task { await DefaultViewer.makeDefault(quitWhenDone: true) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls, nextTo: nil)
    }

    /// Launched from the Dock or Spotlight without a file: ask for one.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !settingDefault && !hostingTests
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showOpenPanel(nil)
        return true
    }

    /// PiDF runs only while a document is open, so it uses no memory otherwise.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !settingDefault && !hostingTests
    }

    /// ⌘Q, logging out: the marks go into their files first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers where !controller.saveAnnotations() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The highlights and notes couldn’t be saved in “\(controller.url.lastPathComponent)”."
            alert.informativeText = "Quitting loses them."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in controllers { controller.rememberPosition() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening

    /// Opens each PDF as a tab of `host`, or of the front window. Documents
    /// already open are brought forward instead of opened twice.
    @discardableResult
    func open(_ urls: [URL], nextTo host: NSWindow?) -> [DocumentWindowController] {
        var anchor = host ?? frontWindow
        var opened: [DocumentWindowController] = []
        for url in urls {
            let url = url.standardizedFileURL
            if let existing = controllers.first(where: { $0.url == url }) {
                existing.bringToFront()
                continue
            }
            guard let document = PDFDocument(url: url) else {
                report(url)
                continue
            }
            let controller = DocumentWindowController(url: url, document: document)
            controller.onClose = { [weak self] closed in
                self?.controllers.removeAll { $0 === closed }
            }
            controller.onDrop = { [weak self] urls, window in
                self?.open(urls, nextTo: window)
            }
            controllers.append(controller)
            controller.present(nextTo: anchor)
            anchor = controller.window
            opened.append(controller)
        }
        if !opened.isEmpty && !settingDefault && !hostingTests {
            // Ask after the first document is on screen, never in front of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { DefaultViewer.offerOnFirstLaunch() }
        }
        if controllers.isEmpty && !hostingTests && !settingDefault { NSApp.terminate(nil) }
        return opened
    }

    /// The window new documents join as tabs.
    private var frontWindow: NSWindow? {
        NSApp.orderedWindows.first { $0 is DocumentWindow && $0.isVisible }
            ?? controllers.last?.window
    }

    private func report(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(url.lastPathComponent)” can’t be opened."
        let readable = FileManager.default.isReadableFile(atPath: url.path)
        alert.informativeText = readable ? "It isn’t a PDF document, or it is damaged." : "The file can’t be read."
        NSApp.activate()
        alert.runModal()
    }

    /// File › Open, and the + button of the tab bar.
    @objc func showOpenPanel(_ sender: Any?) {
        let host = frontWindow
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            open(panel.urls, nextTo: host)
        } else if controllers.isEmpty && !hostingTests {
            NSApp.terminate(nil)
        }
    }

    /// The + button in the tab bar.
    @objc func newWindowForTab(_ sender: Any?) { showOpenPanel(sender) }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "A minimal, native PDF viewer for Apple Silicon Macs.\nFree and open source under the MIT License.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "github.com/IvanJLM/PiDF", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://github.com/IvanJLM/PiDF")!,
        ]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
