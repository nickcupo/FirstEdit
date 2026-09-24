import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// The first launch under the name First Edit (`FirstLaunch`), against
/// temporary folders and scratch settings suites only. Nothing here names his
/// support folder or either real settings domain: every step is handed the
/// folders and the domains it works on.
@Suite("The first launch under the new name")
struct FirstLaunchTests {

    // MARK: - scratch places

    /// A stand-in for `~/Library/Application Support`, made for one test and
    /// removed after it.
    final class Scratch {
        let base: URL
        let old: URL
        let new: URL
        let oldDomain = "firstedit.tests.firstlaunch.old.\(UUID().uuidString)"
        let newDomain = "firstedit.tests.firstlaunch.new.\(UUID().uuidString)"
        /// Only an accessor: `persistentDomain(forName:)` and
        /// `setPersistentDomain(_:forName:)` name the domain they touch.
        let defaults: UserDefaults

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("firstedit-firstlaunch-\(UUID().uuidString)", isDirectory: true)
            old = base.appendingPathComponent(FirstLaunch.Old.folder, isDirectory: true)
            new = base.appendingPathComponent(FirstLaunch.New.folder, isDirectory: true)
            defaults = UserDefaults(suiteName: newDomain)!
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }

        deinit {
            chmod(base.path, 0o755)
            try? FileManager.default.removeItem(at: base)
            defaults.removePersistentDomain(forName: oldDomain)
            defaults.removePersistentDomain(forName: newDomain)
        }

        /// The old folder as his is laid out: models, the learned store, a
        /// queue, a log, and the extension as a link to a folder elsewhere.
        func makeOld(extensionLink: String? = nil) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: old.appendingPathComponent("models/clip"), withIntermediateDirectories: true)
            try fm.createDirectory(at: old.appendingPathComponent("learned"), withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: old.appendingPathComponent("models/clip/model.bin"))
            try Data("837 frames".utf8).write(to: old.appendingPathComponent("learned/store.json"))
            try Data("[]".utf8).write(to: old.appendingPathComponent("queue.json"))
            try Data("started\n".utf8).write(to: old.appendingPathComponent("studio.log"))
            let ext = base.appendingPathComponent("elsewhere/ext", isDirectory: true)
            try fm.createDirectory(at: ext, withIntermediateDirectories: true)
            try Data("# ext".utf8).write(to: ext.appendingPathComponent("studio_ext.py"))
            try fm.createSymbolicLink(atPath: old.appendingPathComponent("extension").path,
                                      withDestinationPath: extensionLink ?? ext.path)
        }

        func record(at date: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> SupportMove.Record {
            .init(oldBundleID: oldDomain, newBundleID: newDomain, appVersion: "0.2.0", at: date)
        }

        func setOld(_ values: [String: Any]) {
            defaults.setPersistentDomain(values, forName: oldDomain)
        }
        func setNew(_ values: [String: Any]) {
            defaults.setPersistentDomain(values, forName: newDomain)
        }
        var oldValues: [String: Any]? { defaults.persistentDomain(forName: oldDomain) }
        var newValues: [String: Any] { defaults.persistentDomain(forName: newDomain) ?? [:] }
    }

    /// Everything under a folder, relative path to contents, not following
    /// links: what "left alone" means.
    static func tree(_ url: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return out }
        for case let rel as String in walker {
            let p = url.appendingPathComponent(rel)
            if SupportMove.kind(p) == .link {
                out[rel] = Data(((try? FileManager.default.destinationOfSymbolicLink(atPath: p.path)) ?? "").utf8)
            } else if SupportMove.kind(p) == .other {
                out[rel] = (try? Data(contentsOf: p)) ?? Data()
            } else {
                out[rel] = Data("dir".utf8)
            }
        }
        return out
    }

    static func inode(_ url: URL) -> (dev: Int32, ino: UInt64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (st.st_dev, st.st_ino)
    }

    // MARK: - when it does anything at all

    @Test("a scratch support folder skips it, even with the old app open, and the old app is not even asked about")
    func scratchSkips() {
        var asked = false
        let d = FirstLaunch.decide(environment: ["PIPELINE_SUPPORT": "/scratch/support"],
                                   bundleID: FirstLaunch.New.bundleID,
                                   oldAppRunning: { asked = true; return true })
        #expect(d == .skip)
        #expect(!asked)
    }

    @Test("with the old app open it refuses, from the built app or a checkout")
    func oldAppOpenRefuses() {
        #expect(FirstLaunch.decide(environment: [:], bundleID: FirstLaunch.New.bundleID,
                                   oldAppRunning: { true }) == .refuse)
        #expect(FirstLaunch.decide(environment: [:], bundleID: nil, oldAppRunning: { true }) == .refuse)
        // An empty PIPELINE_SUPPORT names no folder, so it is not a scratch run.
        #expect(FirstLaunch.decide(environment: ["PIPELINE_SUPPORT": ""], bundleID: FirstLaunch.New.bundleID,
                                   oldAppRunning: { true }) == .refuse)
    }

    @Test("only the built app migrates: a run from a checkout moves nothing")
    func onlyTheBundle() {
        #expect(FirstLaunch.decide(environment: [:], bundleID: nil, oldAppRunning: { false }) == .skip)
        #expect(FirstLaunch.decide(environment: [:], bundleID: FirstLaunch.Old.bundleID,
                                   oldAppRunning: { false }) == .skip)
        #expect(FirstLaunch.decide(environment: [:], bundleID: FirstLaunch.New.bundleID,
                                   oldAppRunning: { false }) == .migrate)
    }

    @Test("the old app open: nothing is moved, no setting is copied, and the launch is refused before the engine")
    func refusalTouchesNothing() throws {
        let s = try Scratch()
        try s.makeOld()
        s.setOld(["general.libraryFolder": "/Users/someone/photos", "app.firstRunDone": true])
        let before = Self.tree(s.old)
        let (decision, outcome) = FirstLaunch.prepare(
            environment: [:], bundleID: FirstLaunch.New.bundleID, oldAppRunning: { true },
            oldSupport: s.old, newSupport: s.new, oldDomain: s.oldDomain, newDomain: s.newDomain,
            defaults: s.defaults, appVersion: "0.2.0")
        // `atLaunch` shows the alert and exits on `.refuse`; `AppDelegate`,
        // which starts the engine, is never made.
        #expect(decision == .refuse)
        #expect(outcome == nil)
        #expect(SupportMove.kind(s.old) == .directory)
        #expect(SupportMove.kind(s.new) == .absent)
        #expect(Self.tree(s.old) == before)
        #expect(s.newValues.isEmpty)
    }

    @Test("the alert names the old app, says nothing has moved, and its one button quits FirstEdit")
    @MainActor func alert() {
        let a = FirstLaunch.stillOpenAlert()
        #expect(a.messageText == "Photo Pipeline is still open.")
        #expect(a.informativeText == "Quit it, then open FirstEdit again. Nothing has been moved.")
        #expect(a.buttons.map(\.title) == ["Quit FirstEdit"])
    }

    // MARK: - the folder, row by row of the plan's table

    @Test("new absent, old a real folder: renamed in place, nothing copied, a link left, and the undo written down")
    func renamed() throws {
        let s = try Scratch()
        try s.makeOld()
        let before = Self.tree(s.old)
        let learnedBefore = try #require(Self.inode(s.old.appendingPathComponent("learned/store.json")))
        let folderBefore = try #require(Self.inode(s.old))

        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(out == .moved(linked: true, notFound: [], record: "MIGRATED.json"))
        #expect(out.note == nil)

        // The same folder and the same files, under the new name: a rename,
        // not a copy.
        let folderAfter = try #require(Self.inode(s.new))
        let learnedAfter = try #require(Self.inode(s.new.appendingPathComponent("learned/store.json")))
        #expect(folderAfter.dev == folderBefore.dev && folderAfter.ino == folderBefore.ino)
        #expect(learnedAfter.dev == learnedBefore.dev && learnedAfter.ino == learnedBefore.ino)
        var after = Self.tree(s.new)
        after["MIGRATED.json"] = nil
        #expect(after == before)

        // A relative link at the old name, and every old path still works.
        #expect(SupportMove.kind(s.old) == .link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.old.path) == "FirstEdit")
        #expect(FileManager.default.fileExists(atPath: s.old.appendingPathComponent("learned/store.json").path))
        #expect(FileManager.default.fileExists(atPath: s.new.appendingPathComponent("extension/studio_ext.py").path))

        let data = try Data(contentsOf: s.new.appendingPathComponent("MIGRATED.json"))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(MigrationRecord.self, from: data)
        #expect(r.from == s.old.path && r.to == s.new.path)
        #expect(r.fromBundleID == s.oldDomain && r.toBundleID == s.newDomain)
        #expect(r.appVersion == "0.2.0")
        #expect(r.at == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(r.linkLeftAtOldPlace)
        #expect(r.checked == ["models", "learned", "extension/studio_ext.py"])
        #expect(r.notFoundAfter.isEmpty)
        #expect(r.undo.count == 4)
        #expect(r.undo.last?.contains("from wherever its app was kept") == true)
        // What an undo does not put back: settings changed in between, and
        // the sidecars written under the new name.
        #expect(r.afterUndo.count == 2)
        #expect(r.afterUndo.contains { $0.contains("not copied across") })
        #expect(r.afterUndo.contains { $0.contains("first-edit sidecar") })
        // The link only: rm with no -r refuses a real folder.
        #expect(r.undo.contains { $0.hasSuffix(": rm \"\(s.old.path)\"") })
        #expect(r.undo.contains { $0.contains("mv \"\(s.new.path)\" \"\(s.old.path)\"") })

        // And the resolver agrees.
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.new)
    }

    @Test("run again after the rename: already moved, and nothing is written a second time")
    func secondLaunch() throws {
        let s = try Scratch()
        try s.makeOld()
        _ = SupportMove.run(old: s.old, new: s.new, record: s.record())
        let before = Self.tree(s.new)
        #expect(SupportMove.run(old: s.old, new: s.new, record: s.record()) == .alreadyMoved)
        #expect(Self.tree(s.new) == before)
    }

    @Test("the move fails: the old folder is used where it is, untouched, and Settings says so once")
    func renameFails() throws {
        let s = try Scratch()
        try s.makeOld()
        let before = Self.tree(s.old)
        // A parent he cannot write to: the link, the first step, is refused.
        #expect(chmod(s.base.path, 0o555) == 0)
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(chmod(s.base.path, 0o755) == 0)

        guard case .couldNotMove(let where_, let why) = out else {
            Issue.record("expected couldNotMove, got \(out)")
            return
        }
        #expect(where_ == s.old)
        #expect(!why.isEmpty)
        #expect(SupportMove.kind(s.old) == .directory)
        #expect(SupportMove.kind(s.new) == .absent)
        #expect(Self.tree(s.old) == before, "nothing is left half-done")
        #expect(!out.folderIsNew)
        #expect(out.note?.contains(s.old.abbreviatedPath) == true)
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.old)
    }

    @Test("the link cannot be made: nothing moves, and the old folder is used where it is")
    func linkFails() throws {
        let s = try Scratch()
        try s.makeOld()
        let before = Self.tree(s.old)
        let moves = SupportMove.Moves(link: { _, _ in EPERM }, swap: SupportMove.Moves.real.swap)
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record(), moves: moves)
        guard case .couldNotMove(let where_, _) = out else {
            Issue.record("expected couldNotMove, got \(out)")
            return
        }
        #expect(where_ == s.old)
        #expect(SupportMove.kind(s.old) == .directory)
        #expect(SupportMove.kind(s.new) == .absent)
        #expect(Self.tree(s.old) == before)
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.old)
    }

    @Test("a disk that cannot swap two names: the link made for the swap is taken back, and nothing else changes")
    func swapFails() throws {
        let s = try Scratch()
        try s.makeOld()
        let before = Self.tree(s.old)
        let moves = SupportMove.Moves(link: SupportMove.Moves.real.link, swap: { _, _ in ENOTSUP })
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record(), moves: moves)
        guard case .couldNotMove(let where_, let why) = out else {
            Issue.record("expected couldNotMove, got \(out)")
            return
        }
        #expect(where_ == s.old)
        #expect(why == String(cString: strerror(ENOTSUP)))
        #expect(SupportMove.kind(s.new) == .absent, "the link made a moment ago is gone again")
        #expect(SupportMove.kind(s.old) == .directory)
        #expect(Self.tree(s.old) == before)
        #expect(out.note?.contains(s.old.abbreviatedPath) == true)
    }

    @Test("something writing through the old path while the folder moves never finds it missing, and no second folder is made")
    func writerDuringMove() throws {
        let s = try Scratch()
        try s.makeOld()
        // A writer that goes through the old path by name every time, and
        // makes its folder as it writes, as the learned store does.
        let learned = s.old.appendingPathComponent("learned", isDirectory: true)
        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var written = 0, failed: [String] = [], stop = false
        }
        let tally = Tally()
        let done = DispatchSemaphore(value: 0)
        let writer = Thread {
            var n = 0
            while true {
                tally.lock.lock(); let stop = tally.stop; tally.lock.unlock()
                if stop { break }
                n += 1
                do {
                    try FileManager.default.createDirectory(at: learned, withIntermediateDirectories: true)
                    try Data("\(n)".utf8).write(to: learned.appendingPathComponent("w-\(n)"))
                    tally.lock.lock(); tally.written += 1; tally.lock.unlock()
                } catch {
                    tally.lock.lock(); tally.failed.append("\(error)"); tally.lock.unlock()
                }
            }
            done.signal()
        }
        writer.start()
        // Long enough for the writer to be busy on both sides of the move.
        usleep(20_000)
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        usleep(20_000)
        tally.lock.lock(); tally.stop = true; tally.lock.unlock()
        done.wait()

        #expect(out == .moved(linked: true, notFound: [], record: "MIGRATED.json"))
        #expect(tally.failed.isEmpty, "\(tally.failed.count) writes failed: \(tally.failed.prefix(3))")
        #expect(tally.written > 0)
        #expect(SupportMove.kind(s.old) == .link)
        #expect(SupportMove.kind(s.new) == .directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: s.new.appendingPathComponent("learned").path)
        #expect(files.filter { $0.hasPrefix("w-") }.count == tally.written, "every write is in the one folder")
    }

    @Test("a launch that stopped after making the link and before the swap: the next one finishes the move")
    func preparedLinkLeftBehind() throws {
        let s = try Scratch()
        try s.makeOld()
        let before = Self.tree(s.old)
        try FileManager.default.createSymbolicLink(atPath: s.new.path, withDestinationPath: FirstLaunch.New.folder)
        // Until then, both resolvers go on with the old folder.
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.old)
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(out == .moved(linked: true, notFound: [], record: "MIGRATED.json"))
        var after = Self.tree(s.new)
        after["MIGRATED.json"] = nil
        #expect(after == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.old.path) == FirstLaunch.New.folder)
    }

    @Test("a launch that stopped after the swap and before the record: the next one writes the record, once")
    func recordWrittenLater() throws {
        let s = try Scratch()
        try s.makeOld()
        #expect(SupportMove.Moves.real.link(FirstLaunch.New.folder, s.new) == 0)
        #expect(SupportMove.Moves.real.swap(s.old, s.new) == 0)
        #expect(!SupportMove.hasRecord(s.new))

        #expect(SupportMove.run(old: s.old, new: s.new, record: s.record()) == .alreadyMoved)
        let r = try JSONDecoder.iso.decode(MigrationRecord.self,
                                           from: Data(contentsOf: s.new.appendingPathComponent("MIGRATED.json")))
        #expect(r.what.contains("no record of the move"))
        #expect(r.linkLeftAtOldPlace)
        #expect(r.undo.contains { $0.contains("mv \"\(s.new.path)\" \"\(s.old.path)\"") })

        let once = Self.tree(s.new)
        #expect(SupportMove.run(old: s.old, new: s.new, record: s.record()) == .alreadyMoved)
        #expect(Self.tree(s.new) == once, "never a second record")
    }

    @Test("an extension link that only worked through the old name is found missing, and Settings says what")
    func extensionLinkBreaks() throws {
        let s = try Scratch()
        // Relative, through the old folder's own name.
        try s.makeOld(extensionLink: "../Photo Pipeline/own-ext")
        let own = s.old.appendingPathComponent("own-ext", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("# ext".utf8).write(to: own.appendingPathComponent("studio_ext.py"))
        // Through the link at the old name it still resolves.
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(out == .moved(linked: true, notFound: [], record: "MIGRATED.json"))

        // Without that link, nothing can: here something takes it away the
        // moment the swap has made it.
        let t = try Scratch()
        try t.makeOld(extensionLink: "../Photo Pipeline/own-ext")
        let own2 = t.old.appendingPathComponent("own-ext", isDirectory: true)
        try FileManager.default.createDirectory(at: own2, withIntermediateDirectories: true)
        try Data("# ext".utf8).write(to: own2.appendingPathComponent("studio_ext.py"))
        let moves = SupportMove.Moves(link: SupportMove.Moves.real.link, swap: { a, b in
            let err = SupportMove.Moves.real.swap(a, b)
            return err == 0 ? (unlink(a.path) == 0 ? 0 : errno) : err
        })
        let broken = SupportMove.run(old: t.old, new: t.new, record: t.record(), moves: moves)
        #expect(broken == .moved(linked: false, notFound: ["extension/studio_ext.py"], record: "MIGRATED.json"))
        #expect(broken.note?.contains("could not find the extension in it") == true)
        #expect(broken.note?.contains("MIGRATED.json") == true)
    }

    @Test("moved with no link left at the old name: Settings says a tool naming the old folder will not find it")
    func noLinkSaysSo() {
        let out = SupportMove.Outcome.moved(linked: false, notFound: [], record: "MIGRATED.json")
        #expect(out.note == "Photo Pipeline's folder is now FirstEdit's, but there is no link to it under the old "
                + "name, so a tool that still names that folder will not find it. MIGRATED.json in the support "
                + "folder says how to put it back.")
        #expect(SupportMove.Outcome.moved(linked: true, notFound: [], record: "MIGRATED.json").note == nil)
    }

    @Test("both are real folders: never merged, First Edit's is used, and Settings says where the other is")
    func bothExist() throws {
        let s = try Scratch()
        try s.makeOld()
        try FileManager.default.createDirectory(at: s.new.appendingPathComponent("learned"),
                                                withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: s.new.appendingPathComponent("learned/store.json"))
        let oldBefore = Self.tree(s.old), newBefore = Self.tree(s.new)

        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(out == .both(other: s.old))
        #expect(Self.tree(s.old) == oldBefore)
        #expect(Self.tree(s.new) == newBefore)
        #expect(out.note?.contains(s.old.abbreviatedPath) == true)
        #expect(!out.folderIsNew, "a setting naming the old folder still names a real one")
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.new)
    }

    @Test("two folders and First Edit's has no models or nothing learned: an alert names both, once")
    func twoFoldersAlertOnce() throws {
        let s = try Scratch()
        try s.makeOld()
        try FileManager.default.createDirectory(at: s.new, withIntermediateDirectories: true)
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(out == .both(other: s.old))

        let t = try #require(FirstLaunch.twoFolders(out, inUse: s.new, defaults: s.defaults))
        #expect(t.inUse == s.new && t.other == s.old)
        #expect(t.missing == ["models", "learned"])

        // Shown once for that folder: after it, only Settings says so.
        s.defaults.set(s.old.path, forKey: FirstLaunch.twoFoldersShown)
        #expect(FirstLaunch.twoFolders(out, inUse: s.new, defaults: s.defaults) == nil)
        #expect(out.note?.contains(s.old.abbreviatedPath) == true)
    }

    @Test("two folders and First Edit's has its own work: no alert, only the line in Settings")
    func twoFoldersBothWorking() throws {
        let s = try Scratch()
        try s.makeOld()
        let fm = FileManager.default
        try fm.createDirectory(at: s.new.appendingPathComponent("models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: s.new.appendingPathComponent("learned"), withIntermediateDirectories: true)
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(FirstLaunch.twoFolders(out, inUse: s.new, defaults: s.defaults) == nil)
        // Only what the other folder has counts as missing.
        try fm.removeItem(at: s.new.appendingPathComponent("learned"))
        try fm.removeItem(at: s.old.appendingPathComponent("learned"))
        #expect(FirstLaunch.twoFolders(out, inUse: s.new, defaults: s.defaults) == nil)
        // And only two folders: a move is not this.
        #expect(FirstLaunch.twoFolders(.alreadyMoved, inUse: s.new, defaults: s.defaults) == nil)
    }

    @Test("the two-folders alert names both folders and what is missing, and Continue is the default")
    @MainActor func twoFoldersAlertText() {
        let t = FirstLaunch.TwoFolders(inUse: URL(fileURLWithPath: "/S/First Edit"),
                                       other: URL(fileURLWithPath: "/S/Photo Pipeline"),
                                       missing: ["models", "learned"])
        let a = FirstLaunch.twoFoldersAlert(t)
        #expect(a.messageText == "Photo Pipeline's folder is still there.")
        #expect(a.informativeText.contains("/S/First Edit, which is missing the models and what the cull has learned."))
        #expect(a.informativeText.contains("Photo Pipeline's folder is still at /S/Photo Pipeline."))
        #expect(a.informativeText.contains("Nothing in either was moved, merged or deleted."))
        #expect(a.buttons.map(\.title) == ["Continue", "Show Both Folders"])
    }

    // MARK: - the old app, opened later

    @Test("the old app opening while First Edit runs is noticed; any other app is not; stopped, nothing is")
    @MainActor func oldAppOpenedLater() {
        let center = NotificationCenter()
        var opened = 0
        let watch = OldAppWatch(center: center, identify: { $0.userInfo?["id"] as? String }) { opened += 1 }
        watch.start()
        #expect(watch.isWatching)
        let launched = NSWorkspace.didLaunchApplicationNotification
        center.post(name: launched, object: nil, userInfo: ["id": "com.apple.finder"])
        center.post(name: launched, object: nil, userInfo: ["id": FirstLaunch.New.bundleID])
        #expect(opened == 0)
        center.post(name: launched, object: nil, userInfo: ["id": FirstLaunch.Old.bundleID])
        #expect(opened == 1)
        watch.stop()
        center.post(name: launched, object: nil, userInfo: ["id": FirstLaunch.Old.bundleID])
        #expect(opened == 1)
    }

    @Test("the alert when the old app opens later names it, and its default asks it to quit")
    @MainActor func oldOpenedAlertText() {
        let a = FirstLaunch.oldOpenedAlert()
        #expect(a.messageText == "Photo Pipeline was opened.")
        #expect(a.informativeText.contains("Quit Photo Pipeline to go on."))
        #expect(a.buttons.map(\.title) == ["Quit Photo Pipeline", "Leave It Open"])
    }

    @Test("FirstEdit --check starts no engine while the old app is open, unless it has a folder of its own")
    func headlessCheck() {
        let refused = FirstLaunch.headlessCheckRefusal(environment: [:], oldAppRunning: { true })
        #expect(refused?.hasPrefix("FAIL Photo Pipeline is open") == true)
        #expect(FirstLaunch.headlessCheckRefusal(environment: [:], oldAppRunning: { false }) == nil)
        #expect(FirstLaunch.headlessCheckRefusal(environment: ["PIPELINE_SUPPORT": "/scratch/support"],
                                                 oldAppRunning: { true }) == nil)
    }

    @Test("neither folder: a new Mac, nothing made here, and First Edit's is the one the engine will make")
    func fresh() throws {
        let s = try Scratch()
        #expect(SupportMove.run(old: s.old, new: s.new, record: s.record()) == .fresh)
        #expect(SupportMove.kind(s.new) == .absent && SupportMove.kind(s.old) == .absent)
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.new)
    }

    @Test("First Edit's name made by hand as a link to the old folder: one folder, left as it is")
    func handMadeLink() throws {
        let s = try Scratch()
        try s.makeOld()
        try FileManager.default.createSymbolicLink(atPath: s.new.path, withDestinationPath: "Photo Pipeline")
        #expect(SupportMove.run(old: s.old, new: s.new, record: s.record()) == .sameFolder)
        #expect(SupportMove.kind(s.old) == .directory)
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.new)
    }

    @Test("the old name a link he made to another disk: left alone, and used through the link")
    func oldIsALink() throws {
        let s = try Scratch()
        let away = s.base.appendingPathComponent("Other Disk/Photo Pipeline", isDirectory: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.old.path, withDestinationPath: away.path)
        #expect(SupportMove.run(old: s.old, new: s.new, record: s.record()) == .oldIsALink(s.old))
        #expect(SupportMove.kind(s.new) == .absent)
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.old)
    }

    @Test("a record already in the folder is never written over")
    func recordKept() throws {
        let s = try Scratch()
        try s.makeOld()
        try Data("an earlier move".utf8).write(to: s.old.appendingPathComponent("MIGRATED.json"))
        let out = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(out == .moved(linked: true, notFound: [], record: "MIGRATED 2.json"))
        #expect(try String(contentsOf: s.new.appendingPathComponent("MIGRATED.json"), encoding: .utf8)
                == "an earlier move")
    }

    @Test("PIPELINE_SUPPORT names the folder whatever is on disk")
    func environmentWins() throws {
        let s = try Scratch()
        try s.makeOld()
        #expect(AppPaths.support(environment: ["PIPELINE_SUPPORT": "/scratch/support"], applicationSupport: s.base)
                == URL(fileURLWithPath: "/scratch/support", isDirectory: true))
    }

    // MARK: - the settings

    @Test("every setting comes across, the old value wins, what it replaced is kept, and the old domain is only read")
    func importsOnce() throws {
        let s = try Scratch()
        let old: [String: Any] = [
            "general.libraryFolder": "/Users/someone/photos",
            "general.editor": "dxo",
            "app.firstRunDone": true,
            "storage.retentionDays": 30,
            "app.lastPlace": Data("shoot".utf8),
            "tip.cull.shown": true,
            "NSWindow Frame main": "10 10 1200 800 0 0 1728 1085 ",
        ]
        s.setOld(old)
        // A smoke run of the signed bundle, before the first real launch.
        s.setNew(["general.editor": "lightroom", "view.finishedExpanded": true])
        let oldBefore = try #require(s.oldValues as NSDictionary?)

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let out = DefaultsImport.run(from: s.oldDomain, into: s.newDomain, defaults: s.defaults,
                                     movedSupport: nil, now: now)
        #expect(out == .imported(keys: old.count, replaced: ["general.editor"], repointed: []))

        let v = s.newValues
        for (k, value) in old {
            #expect(DefaultsImport.same(try #require(v[k]), value), "\(k) did not come across")
        }
        #expect(v["general.editor"] as? String == "dxo")
        #expect(v["migration.replaced.general.editor"] as? String == "lightroom")
        #expect(v["view.finishedExpanded"] as? Bool == true, "what only First Edit had is kept")
        #expect(v[DefaultsImport.importedFrom] as? String == s.oldDomain)
        #expect(v[DefaultsImport.importedAt] as? Date == now)
        #expect(v[DefaultsImport.importedKeys] as? Int == old.count)

        // Read through the store the app reads with: no first-run sheet.
        let store = SettingsStore(defaults: s.defaults)
        #expect(store.firstRunDone)
        #expect(store.libraryFolder?.path == "/Users/someone/photos")

        // The old domain, exactly as it was.
        #expect(s.oldValues as NSDictionary? == oldBefore)

        // Never again, even if the old app changes something afterwards.
        s.setOld(old.merging(["general.editor": "capture"]) { $1 })
        #expect(DefaultsImport.run(from: s.oldDomain, into: s.newDomain, defaults: s.defaults,
                                   movedSupport: nil, now: now) == .alreadyImported(from: s.oldDomain))
        #expect(s.newValues["general.editor"] as? String == "dxo")
    }

    @Test("no old settings: nothing is copied and nothing is marked")
    func nothingThere() throws {
        let s = try Scratch()
        #expect(DefaultsImport.run(from: s.oldDomain, into: s.newDomain, defaults: s.defaults,
                                   movedSupport: nil, now: Date()) == .nothingThere)
        #expect(s.newValues.isEmpty)
    }

    @Test("a setting that names a place in the old folder names the same place in the new one; the library does not move")
    func repointsIntoTheMovedFolder() throws {
        let s = try Scratch()
        s.setOld([
            "advanced.extensionFolder": s.old.appendingPathComponent("extension").path,
            "general.libraryFolder": "/Users/someone/photos",
        ])
        let out = DefaultsImport.run(from: s.oldDomain, into: s.newDomain, defaults: s.defaults,
                                     movedSupport: (s.old, s.new), now: Date())
        #expect(out == .imported(keys: 2, replaced: [], repointed: ["advanced.extensionFolder"]))
        let v = s.newValues
        #expect(v["advanced.extensionFolder"] as? String == s.new.appendingPathComponent("extension").path)
        #expect(v["migration.was.advanced.extensionFolder"] as? String
                == s.old.appendingPathComponent("extension").path)
        #expect(v["general.libraryFolder"] as? String == "/Users/someone/photos")
    }

    @Test("the old folder still in use: a setting that names it is copied as it is")
    func noRepointWithoutAMove() throws {
        let s = try Scratch()
        let ext = s.old.appendingPathComponent("extension").path
        s.setOld(["advanced.extensionFolder": ext])
        _ = DefaultsImport.run(from: s.oldDomain, into: s.newDomain, defaults: s.defaults,
                               movedSupport: nil, now: Date())
        #expect(s.newValues["advanced.extensionFolder"] as? String == ext)
        #expect(s.newValues["migration.was.advanced.extensionFolder"] == nil)
    }

    @Test("only a path at or under the old folder is repointed")
    func repointRule() {
        let o = URL(fileURLWithPath: "/S/Photo Pipeline"), n = URL(fileURLWithPath: "/S/First Edit")
        #expect(DefaultsImport.repoint("/S/Photo Pipeline", from: o, to: n) == "/S/First Edit")
        #expect(DefaultsImport.repoint("/S/Photo Pipeline/", from: o, to: n) == "/S/First Edit")
        #expect(DefaultsImport.repoint("/S/Photo Pipeline/extension", from: o, to: n) == "/S/First Edit/extension")
        #expect(DefaultsImport.repoint("/S/Photo Pipeline Archive", from: o, to: n) == nil)
        #expect(DefaultsImport.repoint("/Users/someone/photos", from: o, to: n) == nil)
        #expect(DefaultsImport.repoint(true, from: o, to: n) == nil)
        #expect(DefaultsImport.repoint("Photo Pipeline/extension", from: o, to: n) == nil)
    }

    @Test("a setting written through /private names the moved folder too, and so does one written without it")
    func repointThroughPrivate() throws {
        let s = try Scratch()
        try s.makeOld()
        let moved = SupportMove.run(old: s.old, new: s.new, record: s.record())
        #expect(moved.folderIsNew)
        // The scratch folder as the system spells it, and without /private.
        let real = try #require(SupportMove.realPath(s.base))
        #expect(real.hasPrefix("/private/"))
        let plain = String(real.dropFirst("/private".count))
        let newExt = try #require(SupportMove.realPath(s.new.appendingPathComponent("extension")))
        for (folder, setting) in [(real, plain), (plain, real), (real, real), (plain, plain)] {
            let o = URL(fileURLWithPath: folder).appendingPathComponent(FirstLaunch.Old.folder, isDirectory: true)
            let n = URL(fileURLWithPath: folder).appendingPathComponent(FirstLaunch.New.folder, isDirectory: true)
            let value = setting + "/" + FirstLaunch.Old.folder + "/extension"
            let got = try #require(DefaultsImport.repoint(value, from: o, to: n), "\(folder) against \(setting)")
            #expect(got.hasSuffix("/" + FirstLaunch.New.folder + "/extension"))
            #expect(SupportMove.realPath(URL(fileURLWithPath: got)) == newExt)
        }
    }

    // MARK: - the whole first launch

    @Test("the built app's first launch: folder renamed, settings across, the extension setting in the new folder")
    func wholeLaunch() throws {
        let s = try Scratch()
        try s.makeOld()
        s.setOld(["app.firstRunDone": true,
                  "advanced.extensionFolder": s.old.appendingPathComponent("extension").path])
        let oldSettings = try #require(s.oldValues as NSDictionary?)
        let (decision, outcome) = FirstLaunch.prepare(
            environment: [:], bundleID: FirstLaunch.New.bundleID, oldAppRunning: { false },
            oldSupport: s.old, newSupport: s.new, oldDomain: s.oldDomain, newDomain: s.newDomain,
            defaults: s.defaults, appVersion: "0.2.0")
        #expect(decision == .migrate)
        let o = try #require(outcome)
        #expect(o.folder == .moved(linked: true, notFound: [], record: "MIGRATED.json"))
        #expect(o.defaults == .imported(keys: 2, replaced: [], repointed: ["advanced.extensionFolder"]))
        let store = SettingsStore(defaults: s.defaults)
        #expect(store.extensionFolder?.path == s.new.appendingPathComponent("extension").path)
        #expect(FileManager.default.fileExists(atPath: store.extensionFolder!.appendingPathComponent("studio_ext.py").path))
        #expect(s.oldValues as NSDictionary? == oldSettings)
        #expect(AppPaths.support(environment: [:], applicationSupport: s.base) == s.new)

        // The next launch: nothing more to do.
        let (_, again) = FirstLaunch.prepare(
            environment: [:], bundleID: FirstLaunch.New.bundleID, oldAppRunning: { false },
            oldSupport: s.old, newSupport: s.new, oldDomain: s.oldDomain, newDomain: s.newDomain,
            defaults: s.defaults, appVersion: "0.2.0")
        #expect(again?.folder == .alreadyMoved)
        #expect(again?.defaults == .alreadyImported(from: s.oldDomain))
        #expect(again?.folder.note == nil)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
