// "Open Packed Burst": what a double-click on a .roll runs. It lives inside
// FirstEdit.app (Contents/Helpers) and is the one that says it opens .roll,
// so opening a packed burst never opens FirstEdit, its engine or its windows.
// No Dock icon, no window: it hands the kept frame to Preview and quits
// (RollOpener says which picture, and never downloads one).
import AppKit
import RollPreview

@MainActor
final class Opener: NSObject, NSApplicationDelegate {
    private var pending = 0
    private var asked = false

    /// FirstEdit's own Python and burstpack.py, two folders up from here.
    private lazy var engine: (python: URL?, burstpack: URL?) = {
        let res = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let py = res.appendingPathComponent("python/bin/python3.12")
        let bp = res.appendingPathComponent("pipeline/burstpack.py")
        let fm = FileManager.default
        return (fm.isExecutableFile(atPath: py.path) ? py : nil, fm.fileExists(atPath: bp.path) ? bp : nil)
    }()

    func application(_ application: NSApplication, open urls: [URL]) {
        asked = true
        pending += 1
        let rolls = urls.filter { $0.pathExtension.lowercased() == "roll" }
        Task { @MainActor in
            var shown: [URL] = []
            for roll in rolls {
                do {
                    shown.append(try await RollOpener.openable(roll, python: engine.python,
                                                               burstpack: engine.burstpack))
                } catch {
                    NSApp.activate()
                    let a = NSAlert()
                    a.messageText = "\(roll.lastPathComponent) could not be opened"
                    a.informativeText = error.localizedDescription
                    a.runModal()
                }
            }
            if !shown.isEmpty {
                if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                    _ = try? await NSWorkspace.shared.open(shown, withApplicationAt: preview,
                                                           configuration: NSWorkspace.OpenConfiguration())
                } else {
                    shown.forEach { NSWorkspace.shared.open($0) }
                }
            }
            pending -= 1
            if pending == 0 { NSApp.terminate(nil) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started with nothing to open: there is nothing for it to do.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !self.asked && self.pending == 0 { NSApp.terminate(nil) }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let opener = Opener()
    app.delegate = opener
    app.setActivationPolicy(.accessory)
    app.run()
}
