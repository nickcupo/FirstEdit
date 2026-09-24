import Foundation
import Testing
@testable import PipelineKit

/// When a job ended while he was looking at the app, the toolbar's item just
/// disappeared: done, stopped and failed all looked the same. It now says how
/// the job ended — for a moment when it finished or he stopped it, until he
/// looks when it was refused or failed.
@Suite("The toolbar says how a job ended")
@MainActor
struct JobEndedTests {

    static func app() throws -> AppModel {
        AppModel(preview: Library(preview: try LastPlaceTests.shoots()), state: .stopped,
                 navigation: Navigation(selection: .allShoots))
    }

    /// A crash as a job's log ends: a traceback, never a sentence.
    static let traceback = "Traceback (most recent call last):\n  File \"cull.py\", line 9, in <module>"

    static func ended(_ id: Int, code: Int?, stopped: Bool = false, log: String = "", background: Bool = false,
                      kind: String = "presets", shoot: String = "2026-09-19") -> Job {
        Job(running: false, stopped: stopped, id: id, kind: kind, shoot: shoot,
            title: "\(kind) for \(shoot)", log: log, code: code, background: background)
    }

    @Test("a finished job is said; the machine's own homework finishing is not")
    func done() throws {
        let app = try Self.app()
        app.jobEnded(Self.ended(1, code: 0))
        #expect(app.justEnded?.id == 1)
        app.dismissEnded()
        app.jobEnded(Self.ended(2, code: 0, background: true))
        #expect(app.justEnded == nil)
    }

    @Test("a refusal or a failure stays, and another job's success does not bury it")
    func staysUntilLooked() throws {
        let app = try Self.app()
        let refused = Self.ended(3, code: 2, log: "$ presets\n  there is nothing to write presets for.")
        #expect(refused.outcome == .refused)
        app.jobEnded(refused)
        app.jobEnded(Self.ended(4, code: 0, kind: "cull"))
        #expect(app.justEnded?.id == 3)
        app.jobEnded(Self.ended(6, code: 0, shoot: "2026-09-21"))
        #expect(app.justEnded?.id == 3)
        // Stopped is expected, not news that has to wait for him.
        app.jobEnded(Self.ended(5, code: nil, stopped: true))
        #expect(app.justEnded?.id == 3)
        app.dismissEnded()
        #expect(app.justEnded == nil)
    }

    @Test("the same work run again and finished takes the failure's place, and goes by itself")
    func sameWorkAgain() throws {
        let app = try Self.app()
        let failed = Self.ended(7, code: 1, log: Self.traceback, kind: "cull")
        #expect(failed.outcome == .failed)
        app.jobEnded(failed)
        // Stopped, or refused, is not the work done: the failure stays.
        app.jobEnded(Self.ended(8, code: nil, stopped: true, kind: "cull"))
        #expect(app.justEnded?.id == 7)
        app.jobEnded(Self.ended(9, code: 0, kind: "cull"))
        #expect(app.justEnded?.id == 9)
        #expect(app.justEnded?.outcome == .done)
    }

    @Test("a storage plan turned down on purpose is said for a moment, not held; a plan that failed is held")
    func plans() throws {
        let app = try Self.app()
        let refused = Self.ended(10, code: 2, log: "2026-09-13-dog has no archive manifest", kind: "plan-drop")
        #expect(refused.outcome == .refused)
        #expect(!AppModel.stays(refused))
        app.jobEnded(refused)
        #expect(app.justEnded?.id == 10)
        // Not held, so a later ending replaces it.
        app.jobEnded(Self.ended(11, code: 0, kind: "cull"))
        #expect(app.justEnded?.id == 11)
        let failed = Self.ended(12, code: 1, log: Self.traceback, kind: "plan-drop")
        #expect(AppModel.stays(failed))
    }

    @Test("the toolbar's subject is the list, held, when nothing runs and nothing has just ended")
    func subject() throws {
        #expect(ActivityToolbarItem.Subject.list(held: true) != .list(held: false))
        #expect(AppModel.stays(.failed) && AppModel.stays(.refused))
        #expect(!AppModel.stays(.done) && !AppModel.stays(.stopped))
    }
}
