import Foundation
import Testing
@testable import PipelineKit

/// §2.11 — the one folder picker, as Settings, the first run and the empty
/// sidebar all read it.
@Suite("Choosing the library folder")
@MainActor
struct LibraryFolderPickerTests {

    static func scratch() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("an empty folder starts a library, where the sidebar used to do nothing and Settings refused it")
    func anEmptyFolderIsAccepted() throws {
        let tmp = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A dotfile does not make a folder anything but empty.
        try Data().write(to: tmp.appendingPathComponent(".DS_Store"))
        #expect(LibraryFolderPicker.outcome(for: tmp) == .empty(LibraryFolder.directory(tmp.path)))
    }

    @Test("a library the engine was pointed at before any card is still an empty library")
    func anEmptyShelfIsAccepted() throws {
        let tmp = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("shoots"),
                                                withIntermediateDirectories: true)
        #expect(LibraryFolderPicker.outcome(for: tmp) == .empty(LibraryFolder.directory(tmp.path)))
        // And the empty shelf itself resolves to the folder above it, so the
        // engine is never told to make shoots/shoots.
        #expect(LibraryFolderPicker.outcome(for: tmp.appendingPathComponent("shoots"))
            == .empty(LibraryFolder.directory(tmp.path)))
    }

    /// He picked an empty folder from the empty sidebar, the engine restarted
    /// on it, and the sidebar went on saying nothing could be found there.
    @Test("the empty library says a library he has just started is new, as Settings and the welcome do")
    func theSidebarSaysNew() async throws {
        let tmp = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("shoots"),
                                                withIntermediateDirectories: true)
        let started = await EmptyLibrary.look { tmp }
        #expect(started.isNew)
        #expect(started.shelf.path == tmp.appendingPathComponent("shoots").path)

        // A folder that holds other things, or is not there, keeps the
        // sentence that says where it looked and what it looks for.
        try Data("notes".utf8).write(to: tmp.appendingPathComponent("notes.txt"))
        #expect(await EmptyLibrary.look { tmp }.isNew == false)
        let gone = tmp.appendingPathComponent("gone", isDirectory: true)
        let missing = await EmptyLibrary.look { gone }
        #expect(!missing.isNew)
        #expect(missing.shelf.path == gone.appendingPathComponent("shoots").path)
    }

    @Test("a folder with shoots in it is chosen as it always was")
    func aLibrary() throws {
        let tmp = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("shoots/2026-09-19/raw"),
                                                withIntermediateDirectories: true)
        guard case .chose(let r) = LibraryFolderPicker.outcome(for: tmp) else {
            Issue.record("a library was not chosen"); return
        }
        #expect(r.shoots == ["2026-09-19"])
    }

    @Test("a folder that holds other things and no shoot is still turned down, with a sentence")
    func somethingElse() throws {
        let tmp = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("notes".utf8).write(to: tmp.appendingPathComponent("notes.txt"))
        #expect(LibraryFolderPicker.outcome(for: tmp) == .noShoots(tmp))
        #expect(LibraryFolderPicker.outcome(for: tmp.appendingPathComponent("nope"))
            == .noShoots(tmp.appendingPathComponent("nope")))
        #expect(Strings.Settings.noShootsHere("~/Documents").contains("an empty folder for new ones"))
    }

    @Test("the three places say the same thing about an empty folder")
    func theSentence() {
        let line = Strings.Library.newLibrary("~/new/shoots")
        #expect(line.contains("No shoots here yet"))
        #expect(line.contains("~/new/shoots"))
        #expect(Strings.FirstRun.willGoIn("~/photos/shoots").contains("~/photos/shoots"))
        #expect(Strings.Settings.pickerMessage.contains("empty folder"))
    }
}
