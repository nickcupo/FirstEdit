import AppKit
import Testing
@testable import PipelineKit

/// The menu bar of DESIGN.md §2.12, checked row by row and key by key.
///
/// These are the tests that make "every action in the app is a real menu item
/// with its shortcut" a fact rather than an intention.
@Suite("The menu bar")
@MainActor
struct CommandTableTests {

    // MARK: - every menu, every key equivalent

    @Test("the nine menus of §2.12 are all there, in order")
    func menus() {
        #expect(CommandTable.menus.map(\.id) == [.app, .file, .edit, .frame, .view, .go,
                                                 .shoot, .window, .help])
        #expect(CommandTable.menus.allSatisfy { !$0.title.isEmpty })
    }

    /// Every key equivalent DESIGN.md §2.12 and DESIGN-displays.md §3.10 name,
    /// against the row that must carry it.
    @Test("each item carries the key the design gives it")
    func keyEquivalents() {
        let expected: [(CommandID, Shortcut)] = [
            (CommandTable.ID.settings, Shortcut(",", .command)),
            (CommandTable.ID.newShoot, Shortcut("n", .command)),
            (CommandTable.ID.eject, Shortcut("e", .command)),
            (CommandTable.ID.showShoot, Shortcut("r", [.command, .option])),
            (CommandTable.ID.showExports, Shortcut("x", [.command, .option])),
            (CommandTable.ID.findBurst, Shortcut("f", .command)),
            (CommandTable.ID.keep, Shortcut("e")),
            (CommandTable.ID.drop, Shortcut("d")),
            (CommandTable.ID.clearMark, Shortcut("x")),
            (CommandTable.ID.compare, Shortcut("c")),
            (CommandTable.ID.keepOnly, Shortcut("e", .shift)),
            (CommandTable.ID.nextFrame, Shortcut("f")),
            (CommandTable.ID.previousFrame, Shortcut("s")),
            (CommandTable.ID.nextForward, Shortcut(.down)),
            (CommandTable.ID.previousForward, Shortcut(.up)),
            (CommandTable.ID.finishBurst, Shortcut("r")),
            (CommandTable.ID.previousBurst, Shortcut("w")),
            (CommandTable.ID.copyFrameNumber, Shortcut("c", [.command, .option])),
            (CommandTable.ID.allBursts, Shortcut("g")),
            (CommandTable.ID.fullImage, Shortcut(.space)),
            (CommandTable.ID.actualSize, Shortcut("0", .command)),
            (CommandTable.ID.zoomToFit, Shortcut("9", .command)),
            (CommandTable.ID.zoomIn, Shortcut("+", .command)),
            (CommandTable.ID.zoomOut, Shortcut("-", .command)),
            (CommandTable.ID.sidebar, Shortcut("s", [.command, .control])),
            (CommandTable.ID.inspector, Shortcut("i", [.command, .option])),
            (CommandTable.ID.allShoots, Shortcut("0", [.command, .shift])),
            (CommandTable.ID.learned, Shortcut("l", [.command, .shift])),
            (CommandTable.ID.storagePage, Shortcut("s", [.command, .shift])),
            (CommandTable.ID.nextStep, Shortcut("]", .command)),
            (CommandTable.ID.previousStep, Shortcut("[", .command)),
            (CommandTable.ID.resume, Shortcut("j", .command)),
            (CommandTable.ID.cull, Shortcut("r", .command)),
            (CommandTable.ID.openInEditor, Shortcut("e", [.command, .shift])),
            (CommandTable.ID.stopJob, Shortcut(".", .command)),
            (CommandTable.ID.activity, Shortcut("l", [.command, .option])),
            (CommandTable.ID.shortcuts, Shortcut("/", .command)),
        ]
        for (id, key) in expected {
            let c = CommandTable.command(id)
            #expect(c != nil, "no row for \(id.rawValue)")
            #expect(c?.shortcut == key, "\(id.rawValue) carries \(String(describing: c?.shortcut))")
        }
        // The left hand's keys lead, and the ones he learned before them are
        // listed beside them (§2.5.3).
        let also: [(CommandID, [String])] = [
            (CommandTable.ID.keep, ["K"]), (CommandTable.ID.clearMark, ["0"]),
            (CommandTable.ID.keepOnly, ["⇧K"]), (CommandTable.ID.nextFrame, ["→"]),
            (CommandTable.ID.previousFrame, ["←"]), (CommandTable.ID.finishBurst, ["N"]),
            (CommandTable.ID.previousBurst, ["P"]), (CommandTable.ID.undo, ["Q", "U"]),
        ]
        for (id, keys) in also {
            #expect(CommandTable.command(id)?.alternates == keys, "\(id.rawValue)")
        }
        // S is Previous Frame; Single Frame carries no key of its own, since
        // S is Single in All Bursts alone.
        #expect(CommandTable.shortcut(CommandTable.ID.single) == nil)
        // The six reasons are 1–6, in the order of the keys.
        for r in DropReason.allCases {
            #expect(CommandTable.shortcut(CommandTable.ID.reason(r))
                        == Shortcut(Character("\(r.key)")))
        }
        // The system rows AppKit owns are still real rows with real keys.
        for (title, key) in [("app.hide", Shortcut("h", .command)),
                             ("app.quit", Shortcut("q", .command)),
                             ("file.close", Shortcut("w", .command)),
                             ("edit.undo", Shortcut("z", .command)),
                             ("edit.redo", Shortcut("z", [.command, .shift])),
                             ("view.fullScreen", Shortcut("f", [.command, .control])),
                             ("window.minimize", Shortcut("m", .command))] {
            #expect(CommandTable.shortcut(CommandID(title)) == key, "\(title)")
        }
    }

    // MARK: - the ⌘9 collision DESIGN-displays.md §3.10 found

    @Test("⌘9 belongs to Zoom to Fit, and the steps stop at ⌘8")
    func theNineCollision() {
        let nine = KeyBindings.all.filter { $0.shortcut == Shortcut("9", .command) }
        #expect(nine.count == 1)
        #expect(nine.first?.command == CommandTable.ID.zoomToFit)

        // The Go menu numbers by position, 1…8. Nothing it can hold lands on 9.
        #expect(CommandTable.stepNumberLimit == 8)
        #expect(CommandTable.stepShortcut(position: 8) == Shortcut("8", .command))
        #expect(CommandTable.stepShortcut(position: 9) == nil)

        // A shoot with two extension steps: nine rows, eight numbered, and the
        // ninth reached with ⌘] or a click.
        let steps = (1...9).map {
            StepState(id: "s\($0)", label: "Step \($0)", done: false, enabled: true,
                      why_disabled: nil, source: $0 > 7 ? .extensionProvided : .base)
        }
        let rows = CommandTable.stepCommands(steps)
        #expect(rows.count == 9)
        #expect(rows.compactMap(\.shortcut).count == 8)
        #expect(rows.last?.shortcut == nil)
        #expect(!rows.contains { $0.shortcut == Shortcut("9", .command) })
    }

    @Test("no two actions share a key equivalent, and none lands on one another crew was promised")
    func noCollisions() {
        var byShortcut: [Shortcut: CommandID] = [:]
        for b in KeyBindings.all {
            if let already = byShortcut[b.shortcut] {
                #expect(already == b.command,
                        "\(b.shortcut.display) is both \(already.rawValue) and \(b.command.rawValue)")
            }
            byShortcut[b.shortcut] = b.command
        }
        // Reserved for DESIGN-displays.md §3.10. Those rows are in the table
        // now, so each key is either still unclaimed or claimed by exactly the
        // row it was promised to — never by anything else.
        for (shortcut, who) in CommandTable.reserved {
            let taken = byShortcut[shortcut]?.rawValue
            #expect(taken == nil || taken == who,
                    Comment(rawValue: "\(shortcut.display) is promised to \(who) and is taken by \(taken ?? "")"))
        }
        // And every one of them is actually drawn: a promise kept by nobody
        // turning up is a menu row that went missing in a merge.
        let displayed = Set(CommandTable.allCommands.map(\.id.rawValue))
        for (_, who) in CommandTable.reserved {
            #expect(displayed.contains(who), Comment(rawValue: "\(who) is not in the menu bar"))
        }
    }

    // MARK: - the rules about destructive actions

    @Test("nothing destructive has a key, and Delete is bound to nothing anywhere")
    func destructiveHasNoKey() {
        let destructive = CommandTable.allCommands.filter(\.isDestructive)
        #expect(destructive.count == 2)
        #expect(Set(destructive.map(\.id)) == [CommandTable.ID.removeLocal, CommandTable.ID.letGo])
        #expect(destructive.allSatisfy { $0.shortcut == nil })

        // No Delete, no Backspace, anywhere in the bar.
        let forbidden: Set<Character> = ["\u{7F}", "\u{8}", "\u{3}"]
        for b in KeyBindings.all {
            if case .character(let c) = b.shortcut.key {
                #expect(!forbidden.contains(c), "\(b.command.rawValue) is on a delete key")
            }
        }
    }

    @Test("the two that delete photographs are last, under a rule of their own")
    func destructiveLast() {
        let storage = CommandTable.command(CommandTable.ID.storage)
        let children = storage?.children ?? []
        #expect(children.count == 6)
        #expect(children.suffix(2).allSatisfy { $0.isDestructive })
        #expect(children.prefix(4).allSatisfy { !$0.isDestructive })

        let center = CommandCenter()
        let target = MenuTarget(center: center)
        let item = MenuBar.item(for: storage!, target: target)
        let titles = item.submenu!.items.map { $0.isSeparatorItem ? "—" : $0.title }
        // Frequent four, a rule, then the two that remove photographs.
        #expect(titles.firstIndex(of: "—") == 4)
        #expect(titles.count == 7)
    }

    @Test("no toolbar and no menu row writes a verdict without a frame on screen")
    func verdictsAreNotFreeFloating() {
        // Every verdict row refuses to repeat: a held key writes one frame.
        for id in [CommandTable.ID.keep, CommandTable.ID.drop, CommandTable.ID.clearMark,
                   CommandTable.ID.keepOnly, CommandTable.ID.finishBurst] {
            #expect(CommandTable.command(id)?.allowsRepeat == false, "\(id.rawValue) repeats")
        }
        for r in DropReason.allCases {
            #expect(CommandTable.command(CommandTable.ID.reason(r))?.allowsRepeat == false)
        }
        // Moving does repeat: holding → walks the burst.
        #expect(CommandTable.command(CommandTable.ID.nextFrame)?.allowsRepeat == true)
    }

    // MARK: - the table and the key map cannot drift

    @Test("every key has a menu row and every bare-letter row has a key")
    func tableAndKeysAgree() {
        // One direction: a binding exists only because a row in a menu has it.
        for b in KeyBindings.all {
            let row = CommandTable.allCommands.first { $0.id == b.command }
                ?? CommandTable.baseStepCommands.first { $0.id == b.command }
            #expect(row != nil, "\(b.command.rawValue) is a key with no menu row")
            #expect(row?.shortcut == b.shortcut)
        }
        // The other: a bare-letter row is reachable from the keyboard.
        for c in CommandTable.allCommands where c.shortcut?.isBareCharacter == true {
            #expect(KeyBindings.all.contains { $0.command == c.id },
                    "\(c.id.rawValue) is in a menu with a bare letter and no key binding")
        }
        // And `?`, the one second way in, is in the table's row for ⌘/.
        #expect(CommandTable.command(CommandTable.ID.shortcuts)?.alternateDisplay == "?")
        #expect(KeyBindings.questionMark.command == CommandTable.ID.shortcuts)
    }

    @Test("the Shortcuts window lists every key of the app's own, and leaves the Mac's standard ones out")
    func shortcutsWindowCoversTheBar() {
        let listed = Set(ShortcutsCatalog.rows.map(\.id))
        for b in KeyBindings.all {
            let c = CommandTable.command(b.command)
            let standard: Bool
            if case .system = c?.role, c?.group == .everything { standard = true } else { standard = false }
            #expect(listed.contains(b.command) != standard,
                    "\(b.command.rawValue) is \(standard ? "a standard Mac key in" : "missing from") the window")
        }
        // And the two that cannot be undone are listed with a reason, not a key.
        let letGo = ShortcutsCatalog.rows.first { $0.id == CommandTable.ID.letGo }
        #expect(letGo?.keys == nil)
        #expect(letGo?.note == Strings.Help.noneOnPurpose)
    }

    @Test("the search finds a shortcut by its name, its menu or its key")
    func search() {
        func titles(_ q: String) -> [String] {
            ShortcutsCatalog.grouped(matching: q).flatMap(\.1).map(\.title)
        }
        #expect(titles("keep").contains(Words.Frame.keep))
        #expect(titles("⌘R").contains(Words.Shoot.cull))
        #expect(titles(CommandTable.frame.title).contains(Words.Frame.drop))
        #expect(titles("zzzz").isEmpty)
    }

    // MARK: - what the menu says about itself

    @Test("a row nobody has taken responsibility for is greyed, not silently dead")
    func unregisteredIsDisabled() {
        let center = CommandCenter()
        let target = MenuTarget(center: center)
        let keep = MenuBar.item(for: CommandTable.command(CommandTable.ID.keep)!, target: target)
        #expect(!target.validateMenuItem(keep))

        var pressed = 0
        center.register(CommandTable.ID.keep) { pressed += 1 }
        #expect(target.validateMenuItem(keep))
        target.performCommand(keep)
        #expect(pressed == 1)

        // A row whose owner says "not now" is greyed and does nothing.
        center.register(CommandTable.ID.keep, isEnabled: { false }) { pressed += 1 }
        #expect(!target.validateMenuItem(keep))
        target.performCommand(keep)
        #expect(pressed == 1)
    }

    @Test("a toggle row says which way it goes")
    func toggleTitles() {
        let center = CommandCenter()
        let target = MenuTarget(center: center)
        var shown = true
        center.register(CommandTable.ID.sidebar, state: { shown }) { shown.toggle() }
        let item = MenuBar.item(for: CommandTable.command(CommandTable.ID.sidebar)!, target: target)
        _ = target.validateMenuItem(item)
        #expect(item.title == Words.View.hideSidebar)
        shown = false
        _ = target.validateMenuItem(item)
        #expect(item.title == Words.View.showSidebar)
    }

    @Test("a row that is a state carries a checkmark instead of changing its name")
    func checkmarks() {
        let center = CommandCenter()
        let target = MenuTarget(center: center)
        var background = ViewerBackground.neutralGrey
        for b in ViewerBackground.allCases {
            center.register(CommandTable.ID.background(b), state: { background == b }) { background = b }
        }
        let grey = MenuBar.item(for: CommandTable.command(CommandTable.ID.background(.neutralGrey))!,
                                target: target)
        let black = MenuBar.item(for: CommandTable.command(CommandTable.ID.background(.black))!,
                                 target: target)
        _ = target.validateMenuItem(grey)
        _ = target.validateMenuItem(black)
        #expect(grey.state == .on)
        #expect(black.state == .off)
    }

    @Test("every row has a name VoiceOver can read, and none is a bare symbol")
    func everyRowIsSpoken() {
        let center = CommandCenter()
        let target = MenuTarget(center: center)
        for c in CommandTable.allCommands {
            let item = MenuBar.item(for: c, target: target)
            #expect(!item.title.isEmpty, "\(c.id.rawValue) has no title")
            #expect(item.accessibilityLabel() == c.title, "\(c.id.rawValue)")
        }
    }

    // MARK: - the bar AppKit is actually given

    @Test("installing hands AppKit the whole bar, its Help menu and its Window menu")
    func install() {
        let center = CommandCenter()
        MenuBar.install(center: center)
        // `NSApplication.mainMenu` is non-optional to Swift, so it is read
        // straight rather than through #require.
        let main = NSApplication.shared.mainMenu
        #expect(main?.items.count == CommandTable.menus.count)
        #expect(main?.items.map(\.title) == CommandTable.menus.map(\.title))

        // Set, so the system's own Help search reads every item by name
        // (NATIVE-M02), and so AppKit lists the open windows.
        #expect(NSApplication.shared.helpMenu?.title == CommandTable.help.title)
        #expect(NSApplication.shared.windowsMenu?.title == CommandTable.window.title)
        #expect(NSApplication.shared.servicesMenu != nil)

        // ⌘W, ⌃⌘F and the zoom keys are on rows AppKit itself answers, so they
        // work in every window the app has without this crew writing them.
        let view = main?.item(withTitle: CommandTable.view.title)?.submenu
        let fullScreen = view?.items.first { $0.action == NSSelectorFromString("toggleFullScreen:") }
        #expect(fullScreen != nil)
        let file = main?.item(withTitle: CommandTable.file.title)?.submenu
        let close = file?.items.first { $0.action == NSSelectorFromString("performClose:") }
        #expect(close?.keyEquivalent == "w")
        #expect(close?.keyEquivalentModifierMask == .command)

        // The Go menu holds the open shoot's own steps, with the extension's
        // own labels and no number past ⌘8.
        center.setSteps((1...9).map {
            StepState(id: "s\($0)", label: "Step \($0)", done: false, enabled: true,
                      why_disabled: nil, source: .base)
        })
        let go = NSApplication.shared.mainMenu?.item(withTitle: CommandTable.go.title)?.submenu
        let numbered = go?.items.filter { $0.keyEquivalent.first?.isNumber == true
            && $0.keyEquivalentModifierMask == .command } ?? []
        #expect(numbered.count == 8)
        #expect(!numbered.contains { $0.keyEquivalent == "9" })
    }

    @Test("Refused is a first-class outcome and is never called Failed")
    func outcomeWords() throws {
        #expect(ActivityWindow.word(.refused) == Strings.Job.refused)
        #expect(ActivityWindow.word(.failed) == Strings.Job.failed)
        #expect(Strings.Job.refused != Strings.Job.failed)
        let job = try Fixture.decode(Job.self, "job-finished")
        #expect(job.outcome == .refused)
        #expect(ActivityWindow.word(job.outcome) == Strings.Job.refused)
    }

    @Test("a job this session ran becomes a row with its own log")
    func activityRows() throws {
        let jobs = JobModel()
        jobs.take(try Fixture.decodeJob(running: true, fraction: 0.2, kind: "cull",
                                        title: "culling 2026-09-13-dog"))
        jobs.take(try Fixture.decodeJob(running: false, fraction: 1, kind: "cull",
                                        title: "culling 2026-09-13-dog", code: 0))
        let rows = jobs.history.map(ActivityRow.init)
        #expect(rows.count == 1)
        // Named the way the list names it, with the shoot beside it, not the
        // engine's lowercase title (ActivityNamesTests).
        #expect(rows[0].what == Strings.Queue.what("cull"))
        #expect(rows[0].shootAfterWhat == "2026-09-13-dog")
        #expect(rows[0].outcome == .done)
    }
}
