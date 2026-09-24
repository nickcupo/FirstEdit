// Renders screens to PNG with fixture data, so the whole app can be looked at
// without a library or an engine (DESIGN.md §4.3).
//
//   swift run SnapshotHarness --list
//   swift run SnapshotHarness --scene shell --size 1100x780 --out shell.png
//   swift run SnapshotHarness --scene shell --appearance dark --out shell-dark.png
//   swift run SnapshotHarness --out snapshots/     every scene, light and dark,
//                                                  at 1100×780, 1512×945, 900×620
//   --library <scratch lib>   draw real pictures from a scratch library's cull/
//   --fixtures <dir>          another fixture folder
import AppKit
import PipelineKit

@MainActor
func runHarness() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }
    let list = args.contains("--list")
    let sceneName = value("--scene")
    let sizeText = value("--size")
    let out = value("--out")
    let appearanceText = value("--appearance")
    let library = value("--library").map { URL(fileURLWithPath: $0) }
    let fixturesDir = value("--fixtures").map { URL(fileURLWithPath: $0) } ?? defaultFixtures()

    NSSetUncaughtExceptionHandler { e in
        FileHandle.standardError.write(Data("UNCAUGHT \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.prefix(14).joined(separator: "\n"))\n".utf8))
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    // A snapshot is asked for at a size. A window that remembers where it was
    // last put restores that instead, and the whole set came out at whichever
    // size rendered last.
    WindowFrameMemory.remembers = false

    let fixtures = Fixtures(directory: fixturesDir, library: library)
    let scenes = Harness.allScenes()
    if list || (sceneName == nil && out == nil) {
        for s in scenes { print("\(s.name)  \(Int(s.size.width))×\(Int(s.size.height))") }
        return 0
    }
    guard let out else { print("--out is required"); return 2 }

    // With no --appearance, follow the Mac. A snapshot rendered light while his
    // Mac is dark is a picture of an app he does not have, and the whole point
    // of these is to look at what he would see.
    let systemAppearance: Harness.Appearance = AppearanceController.effective == .dark ? .dark : .light
    let appearances: [Harness.Appearance] = appearanceText.flatMap { Harness.Appearance(rawValue: $0) }.map { [$0] }
        ?? (sceneName == nil ? Harness.Appearance.allCases : [systemAppearance])
    let size: CGSize? = sizeText.flatMap(parseSize)

    do {
        if let sceneName {
            guard let scene = scenes.first(where: { $0.name == sceneName }) else {
                throw Harness.HarnessError.noSuchScene(sceneName, scenes.map(\.name))
            }
            let url = URL(fileURLWithPath: out)
            if url.pathExtension.lowercased() == "png" {
                try Harness.render(scene, size: size ?? scene.size, appearance: appearances[0],
                                   fixtures: fixtures, to: url)
                print("wrote \(url.path)")
            } else {
                for a in appearances {
                    for s in size.map({ [$0] }) ?? Harness.standardSizes {
                        let file = url.appendingPathComponent("\(scene.name)-\(a.rawValue)-\(Int(s.width))x\(Int(s.height)).png")
                        try Harness.render(scene, size: s, appearance: a, fixtures: fixtures, to: file)
                        print("wrote \(file.path)")
                    }
                }
            }
        } else {
            // Every scene, each in a process of its own.
            //
            // Rendering the whole set in one process died around the
            // thirty-fifth scene: AppKit raised "the window has been marked as
            // needing another Layout Window pass, but it has already had more
            // Layout Window passes than there are views in the window" inside
            // a CATransaction flush, from a window that renders perfectly on
            // its own. Closing the window, draining the pool and fixing the
            // one bad collection-view layout all helped and none of them was
            // enough. A picture of the app is worth more than one process, and
            // a scene that cannot poison the next one is also a scene nobody
            // has to render twice to believe.
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var failed: [String] = []
            for scene in scenes {
                for a in appearances {
                    for s in size.map({ [$0] }) ?? Harness.standardSizes {
                        let file = dir.appendingPathComponent("\(scene.name)-\(a.rawValue)-\(Int(s.width))x\(Int(s.height)).png")
                        if renderInChild(scene: scene.name, size: s, appearance: a,
                                         fixtures: fixturesDir, library: library, to: file) {
                            print("wrote \(file.path)")
                        } else {
                            failed.append(scene.name)
                            print("FAILED \(scene.name) at \(Int(s.width))x\(Int(s.height)) \(a.rawValue)")
                        }
                    }
                }
            }
            if !failed.isEmpty {
                print("SnapshotHarness: \(failed.count) scene(s) did not render: \(Set(failed).sorted().joined(separator: ", "))")
                return 1
            }
        }
    } catch {
        print("SnapshotHarness: \(error)")
        return 1
    }
    return 0
}

/// One scene, in a child of this process, with exactly the arguments that
/// render it on its own.
func renderInChild(scene: String, size: CGSize, appearance: Harness.Appearance,
                   fixtures: URL, library: URL?, to file: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var args = ["--scene", scene,
                "--size", "\(Int(size.width))x\(Int(size.height))",
                "--appearance", appearance.rawValue,
                "--fixtures", fixtures.path,
                "--out", file.path]
    if let library { args += ["--library", library.path] }
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: file.path)
}

func parseSize(_ s: String) -> CGSize? {
    let parts = s.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" }).compactMap { Double($0) }
    guard parts.count == 2 else { return nil }
    return CGSize(width: parts[0], height: parts[1])
}

/// `Tests/PipelineKitTests/Fixtures`, found from this file's own place in the
/// package, so `swift run` from anywhere finds it.
func defaultFixtures() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // SnapshotHarness
        .deletingLastPathComponent()      // Sources
        .deletingLastPathComponent()      // app
        .appendingPathComponent("Tests/PipelineKitTests/Fixtures", isDirectory: true)
}

exit(MainActor.assumeIsolated { runHarness() })
