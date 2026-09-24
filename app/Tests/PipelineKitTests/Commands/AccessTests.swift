import AppKit
import Testing
import WebKit
@testable import PipelineKit

/// The keyboard, the Dock, the notification, the sleep assertion and what
/// VoiceOver says — the parts of §2.12/§2.15 that are behaviour rather than a
/// table.
@Suite("Keys, the Dock, and what is spoken")
@MainActor
struct AccessTests {

    // MARK: - single letters and a text field

    /// Build a real window with a real search field and give it the keyboard.
    private func windowWithSearchField() -> (NSWindow, NSSearchField) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSSearchField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        return (window, field)
    }

    private func keyDown(_ characters: String, _ flags: NSEvent.ModifierFlags = [],
                         repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: repeating,
                         keyCode: 0)!
    }

    @Test("typing e into a search field types an e, and keeps no photograph")
    func eInASearchField() {
        let (window, field) = windowWithSearchField()
        #expect(MenuValidation.isTextEditing(in: window))

        let center = CommandCenter()
        let target = MenuTarget(center: center)
        var kept = 0
        center.register(CommandTable.ID.keep) { kept += 1 }
        let keep = MenuBar.item(for: CommandTable.command(CommandTable.ID.keep)!, target: target)

        // The menu row refuses while the field has the keyboard, so AppKit
        // passes the keystroke on.
        #expect(!MenuValidation.allows(CommandTable.command(CommandTable.ID.keep)?.shortcut,
                                       textEditing: true))
        #expect(KeyBindings.binding(for: keyDown("e"), textEditing: true) == nil)

        // And the letter lands in the field.
        field.currentEditor()?.insertText("e")
        #expect(field.stringValue == "e")
        #expect(kept == 0)

        // With the keyboard back on the light table, the same press keeps.
        window.makeFirstResponder(nil)
        #expect(!MenuValidation.isTextEditing(in: window))
        let hit = KeyBindings.binding(for: keyDown("e"), textEditing: false)
        #expect(hit?.command == CommandTable.ID.keep)
        center.run(hit!.command)
        #expect(kept == 1)
        _ = keep
    }

    @Test("inside an extension's page every single letter is the page's, H included")
    func aPageKeepsItsLetters() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(page)
        window.makeFirstResponder(page)
        #expect(MenuValidation.isTextEditing(in: window))
        let hold = try #require(CommandTable.allCommands.first { $0.shortcut == Shortcut("h") })
        #expect(!MenuValidation.allows(hold.shortcut, textEditing: MenuValidation.isTextEditing(in: window)))
        // ⌘-keys are still the app's.
        #expect(MenuValidation.allows(Shortcut("r", .command), textEditing: true))
        window.makeFirstResponder(nil)
        #expect(!MenuValidation.isTextEditing(in: window))
    }

    @Test("a shortcut with a modifier still works while he is typing")
    func modifiersSurviveTextEditing() {
        #expect(MenuValidation.allows(Shortcut("r", .command), textEditing: true))
        #expect(KeyBindings.binding(for: keyDown("r", .command), textEditing: true)?.command
                    == CommandTable.ID.cull)
        // Space and the arrows belong to the field too.
        #expect(KeyBindings.binding(for: keyDown(" "), textEditing: true) == nil)
    }

    @Test("a held E keeps one frame; a held F walks the burst")
    func repeats() {
        #expect(KeyBindings.binding(for: keyDown("e", repeating: true), textEditing: false) == nil)
        #expect(KeyBindings.binding(for: keyDown("d", repeating: true), textEditing: false) == nil)
        #expect(KeyBindings.binding(for: keyDown("f", repeating: true), textEditing: false)?.command
                    == CommandTable.ID.nextFrame)
        #expect(KeyBindings.binding(for: keyDown("s", repeating: true), textEditing: false)?.command
                    == CommandTable.ID.previousFrame)
    }

    @Test("? opens the Keyboard Shortcuts window, the same as ⌘/")
    func questionMark() {
        #expect(KeyBindings.binding(for: keyDown("?"), textEditing: false)?.command
                    == CommandTable.ID.shortcuts)
        #expect(KeyBindings.binding(for: keyDown("/", .command), textEditing: false)?.command
                    == CommandTable.ID.shortcuts)
        // Not while he is typing one into Find Burst….
        #expect(KeyBindings.binding(for: keyDown("?"), textEditing: true) == nil)
    }

    // MARK: - the Dock

    @Test("the Dock carries only a bar while a job runs, and nothing after")
    func dock() throws {
        DockProgress.forgetFailures()
        let running = try Fixture.decodeJob(running: true, fraction: 0.38, kind: "cull")
        DockProgress.show(running)
        #expect(DockProgress.percent(running) == 38)
        // No badge: a red "38 %" on top of the bar said "needs you" for the
        // length of every job, and said again what the bar said.
        #expect(NSApplication.shared.dockTile.badgeLabel == nil)
        #expect(NSApplication.shared.dockTile.contentView is DockTileView)

        DockProgress.show(try Fixture.decodeJob(running: false, fraction: 1, kind: "cull"))
        #expect(NSApplication.shared.dockTile.badgeLabel == nil)
        #expect(NSApplication.shared.dockTile.contentView == nil)
    }

    @Test("the Dock is badged only when his work failed, until he looks at Activity")
    func dockBadgeIsForAFailure() {
        DockProgress.forgetFailures()
        defer { DockProgress.forgetFailures() }
        let failed = Job(running: false, stopped: false, id: 7, kind: "cull", shoot: "2026-09-19",
                         log: "Traceback (most recent call last):\nMemoryError", code: 1)
        #expect(failed.outcome == .failed)
        QueueDock.show(.empty, job: failed)
        #expect(NSApplication.shared.dockTile.badgeLabel == DockProgress.failureBadge)
        // He looks at Activity: the badge goes, and the same failure seen
        // again on the next poll does not bring it back.
        DockProgress.sawTheFailures()
        #expect(NSApplication.shared.dockTile.badgeLabel == nil)
        QueueDock.show(.empty, job: failed)
        #expect(NSApplication.shared.dockTile.badgeLabel == nil)
        // A failure the list wrote down between two looks badges too.
        QueueDock.show(QueueState(listed: 1, pass: 2,
                                  done: [QueueDone(id: 9, kind: "presets", shoot: "2026-09-19", outcome: "failed")]),
                       job: nil)
        #expect(NSApplication.shared.dockTile.badgeLabel == DockProgress.failureBadge)
        DockProgress.sawTheFailures()
        // One that lands while Activity is in front of him is read already.
        DockProgress.activityInFront = { true }
        QueueDock.show(QueueState(listed: 1, pass: 3,
                                  done: [QueueDone(id: 10, kind: "cull", shoot: "2026-09-20", outcome: "failed")]),
                       job: nil)
        #expect(NSApplication.shared.dockTile.badgeLabel == nil)
        DockProgress.activityInFront = { false }
        // Done, stopped, refused and the machine's homework are not news.
        for j in [Job(running: false, stopped: false, id: 11, kind: "cull", code: 0),
                  Job(running: false, stopped: true, id: 12, kind: "cull", code: -15),
                  Job(running: false, stopped: false, id: 13, kind: "plan-drop", log: "$ x\nno manifest", code: 1),
                  Job(running: false, stopped: false, id: 14, kind: "learn-learn",
                      log: "Traceback (most recent call last):\nMemoryError", code: 1, background: true)] {
            QueueDock.show(.empty, job: j)
            #expect(NSApplication.shared.dockTile.badgeLabel == nil, "\(j.kind) \(j.outcome)")
        }
    }

    /// The Activity window existing was "in front of him": open behind
    /// PhotoLab, minimized or in a hidden app, a failure overnight was never
    /// badged - the one case the badge is for.
    @Test("an Activity window that is open but not in front of him does not hide a failure")
    func dockBadgeWithActivityBehind() {
        DockProgress.forgetFailures()
        defer { DockProgress.forgetFailures() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                         styleMask: [.titled], backing: .buffered, defer: true)
        DockProgress.activityInFront = { false }
        DockProgress.watchActivity(w)
        DockProgress.noteFailure(id: 21, kind: "cull", shoot: "2026-09-21")
        #expect(NSApplication.shared.dockTile.badgeLabel == DockProgress.failureBadge)
        // It becomes his key window: he is looking at the failure.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        #expect(NSApplication.shared.dockTile.badgeLabel == nil)
    }

    @Test("with nothing running, a held list's Dock menu offers Continue")
    func dockMenuHeld() {
        DockProgress.forgetFailures()
        let center = CommandCenter()
        #expect(DockProgress.dockMenu(center: center, list: .empty) == nil)
        let held = QueueState(waiting: [QueueItem(id: 3, kind: "presets", shoot: "2026-09-19")], held: true)
        let menu = DockProgress.dockMenu(center: center, list: held)
        #expect(menu?.items.map(\.title) == [Strings.StatusItem.held(1), Strings.Queue.letGo, Strings.Queue.title])
    }

    @Test("the Dock menu says what is running and can stop it")
    func dockMenu() throws {
        let center = CommandCenter()
        var stopped = 0
        center.register(CommandTable.ID.stopJob) { stopped += 1 }
        DockProgress.forgetFailures()
        #expect(DockProgress.dockMenu(center: center, list: .empty) == nil)

        center.job = try Fixture.decodeJob(running: true, fraction: 0.38, kind: "cull")
        let menu = try #require(DockProgress.dockMenu(center: center))
        #expect(menu.items.count == 2)
        #expect(menu.items[0].title.contains("38"))
        #expect(menu.items[1].title == Words.Shoot.stopJob)
        _ = stopped
    }

    // MARK: - the Mac stays awake

    @Test("the sleep assertion is held for exactly the life of a job")
    func assertion() throws {
        final class Token: NSObject {}
        nonisolated(unsafe) var begun = 0
        nonisolated(unsafe) var ended = 0
        var reason = ""
        let a = ActivityAssertion(begin: { r in begun += 1; reason = r; return Token() },
                                  end: { _ in ended += 1 })
        #expect(!a.isHeld)

        a.follow(try Fixture.decodeJob(running: true, fraction: 0.1, kind: "cull"))
        #expect(a.isHeld && begun == 1 && ended == 0)
        #expect(reason == ActivityAssertion.reason)

        // Every further poll while it runs changes nothing.
        a.follow(try Fixture.decodeJob(running: true, fraction: 0.5, kind: "cull"))
        #expect(begun == 1)

        a.follow(try Fixture.decodeJob(running: false, fraction: 1, kind: "cull"))
        #expect(!a.isHeld && ended == 1)
        // And it is not given back twice.
        a.follow(nil)
        #expect(ended == 1)
    }

    // MARK: - the notification

    @Test("a notification only when he is looking elsewhere, and only once")
    func notifications() throws {
        let n = Notifications()
        n.isAvailable = true
        nonisolated(unsafe) var posted: [String] = []
        n.post = { content, _ in posted.append(content.subtitle) }
        n.requestAuthorization = { true }
        n.allowed = true                      // he said yes on some earlier shoot
        n.isFrontmost = { true }

        let done = try Fixture.decodeJob(running: false, fraction: 1, kind: "cull",
                                         shoot: "2026-09-13-dog", title: "culling 2026-09-13-dog",
                                         code: 0)
        n.jobChanged(done)
        #expect(posted.isEmpty, "he is looking at it; the window already said so")

        n.isFrontmost = { false }
        n.jobChanged(done)
        #expect(posted.count == 1)
        #expect(posted[0] == "2026-09-13-dog")
        // The poll sees "done" again five times; he is told once.
        n.jobChanged(done)
        n.jobChanged(done)
        #expect(posted.count == 1)

        // A job still running is not an ending.
        let running = try Fixture.decodeJob(running: true, fraction: 0.4, kind: "cull")
        #expect(!n.shouldAnnounce(running))
        // Nothing has run at all: no notification about an idle queue.
        #expect(!n.shouldAnnounce(try Fixture.decode(Job.self, "job")))
    }

    @Test("a job the list ran is the list's to announce, even once the engine has written it down")
    func aListJobIsNotAnnouncedTwice() {
        let n = Notifications()
        n.isFrontmost = { false }
        // The reading after the list's last job ended, from an engine that
        // dropped the flag once it had recorded the job: only `queue_done`
        // says it came off the list.
        let ended = Job(running: false, stopped: false, id: 7, kind: "cull", shoot: "2026-09-19",
                        title: "culling 2026-09-19", code: 0, fromList: false,
                        listDone: [QueueDone(id: 7, kind: "cull", shoot: "2026-09-19")])
        #expect(!n.shouldAnnounce(ended))
        // And the engine says so itself now.
        let flagged = Job(running: false, stopped: false, id: 7, kind: "cull", shoot: "2026-09-19",
                          code: 0, fromList: true)
        #expect(!n.shouldAnnounce(flagged))
        // A job he started by hand, after the list finished, is still his.
        let byHand = Job(running: false, stopped: false, id: 8, kind: "presets", shoot: "2026-09-19",
                         code: 0, listDone: [QueueDone(id: 7, kind: "cull", shoot: "2026-09-19")])
        #expect(n.shouldAnnounce(byHand))
    }

    @Test("asking for permission happens the first time one is about to be sent")
    func authorizationIsLate() async throws {
        let n = Notifications()
        n.isAvailable = true
        nonisolated(unsafe) var asked = 0
        nonisolated(unsafe) var posted = 0
        n.requestAuthorization = { asked += 1; return false }
        n.post = { _, _ in posted += 1 }
        n.isFrontmost = { false }
        #expect(asked == 0, "nothing is asked at launch")

        n.jobChanged(try Fixture.decodeJob(running: false, fraction: 1, kind: "cull", code: 0))
        for _ in 0..<8 { await Task.yield() }
        // Asked once, because a job ended — not because the app opened. And
        // refused, so nothing is posted.
        #expect(asked == 1)
        #expect(posted == 0)
    }

    @Test("a plan that refused says what it said, and is not called a failure")
    func refusalNotification() throws {
        let job = try Fixture.decode(Job.self, "job-finished")
        #expect(job.outcome == .refused)
        let content = Notifications.content(for: job)
        #expect(content.body == job.refusalSentence)
        #expect(content.subtitle == job.shoot)
        #expect(!content.title.contains(job.shoot), "the shoot is said once, under the title")
        #expect(!content.title.contains(Strings.Job.failed))
    }

    @Test("clicking one opens that shoot at that step")
    func notificationOpens() {
        let n = Notifications()
        var opened: (String, String)?
        n.open = { shoot, step in opened = (shoot, step) }
        n.open?("2026-09-13-dog", "keepers")
        #expect(opened?.0 == "2026-09-13-dog")
        #expect(opened?.1 == "keepers")
    }

    // MARK: - what VoiceOver says

    @Test("a frame says the sentence §2.15 writes, word for word")
    func spokenFrame() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot")
        var row = try #require(r.rows.first)
        row.override = VerdictValue.keep(row)
        let said = Announcements.frame(row, position: 2, of: 7, burst: 3, stackCount: 4)
        #expect(said.hasPrefix("Frame 04313, 2 of 7 in burst 3."))
        #expect(said.contains("You kept it."))
        #expect(said.contains("The cull's guess: maybe, only frame."))
        #expect(said.hasSuffix("In a stack of 4 similar frames."))
        // No stack, no clause about one.
        #expect(!Announcements.frame(row, position: 1, of: 1, burst: 1).contains("stack"))
    }

    @Test("his verdict and the cull's are never the same words")
    func hisAndTheMachine() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot")
        var row = try #require(r.rows.first)
        #expect(SpokenVerdict.his(row) == Words.Spoken.unmarked)
        row.override = VerdictValue.drop
        #expect(SpokenVerdict.his(row) == Words.Spoken.youPutOut)
        // The cull's line never says "you".
        for r in r.rows.prefix(20) {
            #expect(!SpokenVerdict.cull(r).lowercased().contains("you"))
        }
    }

    @Test("the four things he can do to a frame are offered by name")
    func customActions() {
        let names = Announcements.frameActions.map(\.name)
        #expect(names == [Words.Spoken.keep, Words.Spoken.drop,
                          Words.Spoken.clearMark, Words.Spoken.compare])
        #expect(Announcements.frameActions.map(\.command)
                    == [CommandTable.ID.keep, CommandTable.ID.drop,
                        CommandTable.ID.clearMark, CommandTable.ID.compare])
    }

    @Test("a long job is announced at its start and its finish, and never in between")
    func announcer() throws {
        let a = Announcer()
        nonisolated(unsafe) var said: [String] = []
        a.speak = { said.append($0) }
        a.jobChanged(try Fixture.decodeJob(running: true, fraction: 0.1, kind: "cull",
                                           title: "culling 2026-09-13-dog"))
        a.jobChanged(try Fixture.decodeJob(running: true, fraction: 0.4, kind: "cull",
                                           title: "culling 2026-09-13-dog"))
        a.jobChanged(try Fixture.decodeJob(running: true, fraction: 0.9, kind: "cull",
                                           title: "culling 2026-09-13-dog"))
        #expect(said.count == 1)
        a.jobChanged(try Fixture.decodeJob(running: false, fraction: 1, kind: "cull",
                                           title: "culling 2026-09-13-dog", code: 0))
        #expect(said.count == 2)
        #expect(said[0].contains("started") && said[1].contains("finished"))
    }

    /// §2.15: politely. A job that lands must not cut across VoiceOver reading
    /// him the frame he is looking at.
    @Test("a job's announcement waits its turn rather than interrupting him")
    func announcementIsPolite() {
        #expect(Announcer.priority == .low)
        let info = Announcer.announcement("Culling 2026-09-13-dog finished.")
        #expect(info[.announcement] as? String == "Culling 2026-09-13-dog finished.")
        #expect(info[.priority] as? Int == NSAccessibilityPriorityLevel.low.rawValue)
    }

    // MARK: - Increase Contrast

    @Test("Increase Contrast thickens what a verdict is read from")
    func contrast() {
        // 3 pt is the floor, whatever the normal weight was.
        #expect(A11y.emphasised == 3)
        if A11y.increaseContrast {
            #expect(A11y.stroke(1) == 3)
            #expect(A11y.border == 1)
        } else {
            #expect(A11y.stroke(1) == 1)
            #expect(A11y.stroke(4) == 4)
            #expect(A11y.border == 0)
        }
    }

    // MARK: - Help

    @Test("Help works with no help book in the bundle, and reports without a network write")
    func help() throws {
        #expect(!HelpBook.hasHelpBook, "a checkout has no compiled help book")
        let url = try #require(HelpBook.reportURL(version: "0.1.3"))
        #expect(url.scheme == "https")
        #expect(url.absoluteString.contains("issues/new"))
        #expect(url.absoluteString.contains("0.1.3"))
    }
}

extension Fixture {
    /// The job fixture with the few fields a test cares about changed, so a
    /// test never hand-builds a model the decoder has not seen.
    static func decodeJob(running: Bool, fraction: Double, kind: String,
                          shoot: String = "2026-09-13-dog", title: String = "",
                          code: Int? = nil, fromList: Bool = false, id: Int? = nil) throws -> Job {
        var o = try #require(try JSONSerialization.jsonObject(with: data("job")) as? [String: Any])
        if let id { o["id"] = id }
        o["running"] = running
        o["fraction"] = fraction
        o["kind"] = kind
        o["shoot"] = shoot
        o["title"] = title
        o["code"] = code as Any? ?? NSNull()
        o["queue_from_list"] = fromList
        return try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: o))
    }
}
