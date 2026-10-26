import Foundation

/// Tells when another app changes a file: one kernel event source per file,
/// no polling and no timers while nothing happens.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    /// Watches the folder while the file is missing (an app saving by
    /// replacing it), until the file is back.
    private var folderSource: DispatchSourceFileSystemObject?
    private var pending = false
    /// PiDF is about to write the file itself: that change is no reload.
    private var expectingOwnChange = false

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        watch()
    }

    func expectOwnChange() { expectingOwnChange = true }
    func cancelExpectedChange() { expectingOwnChange = false }

    func stop() {
        source?.cancel()
        source = nil
        folderSource?.cancel()
        folderSource = nil
    }

    private func watch() {
        stop()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            watchFolder()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, unowned source] in
            MainActor.assumeIsolated {
                let replaced = !source.data.isDisjoint(with: [.delete, .rename])
                self?.changed(rewatch: replaced)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    private func watchFolder() {
        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, FileManager.default.fileExists(atPath: self.url.path) else { return }
                self.changed(rewatch: true)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        folderSource = source
    }

    private func changed(rewatch: Bool) {
        if rewatch {
            source?.cancel()
            source = nil
        }
        guard !pending else { return }
        pending = true
        // Let the other app finish writing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                if self.source == nil { self.watch() }
                if self.expectingOwnChange {
                    self.expectingOwnChange = false
                    return
                }
                if FileManager.default.fileExists(atPath: self.url.path) { self.onChange() }
            }
        }
    }
}
