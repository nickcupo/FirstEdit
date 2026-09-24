import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// The whole safety argument of this feature, asserted rather than assumed.
///
/// A window that cannot become key cannot take first responder, cannot steal
/// K/D/N, and cannot make NAT-01 — "the keys are dead until the first click" —
/// come back through a side door.
@Suite("The picture window never takes the keyboard", .serialized)
@MainActor
struct PictureWindowFocusTests {

    static func mainWindow() -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let stage = FocusableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        w.contentView?.addSubview(stage)
        KeyFocus.preferred = stage
        return (w, stage)
    }

    static func picture() -> PictureWindow {
        let w = PictureWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    @Test("AppKit will not make it key, however it is asked")
    func neverKey() {
        let picture = Self.picture()
        defer { picture.close() }

        #expect(!picture.canBecomeKey)
        #expect(!picture.canBecomeMain)

        // Not by ordering it front, and not by asking outright.
        // (`makeKey()` and `makeMain()` are not tried here: AppKit asserts on
        // them for a window that says no, which is the same answer, louder.)
        picture.orderFront(nil)
        picture.makeKeyAndOrderFront(nil)
        #expect(!picture.isKeyWindow)
        #expect(!picture.isMainWindow)
        // Not by handing it a first responder either.
        let view = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        picture.contentView?.addSubview(view)
        _ = picture.makeFirstResponder(view)
        #expect(!picture.isKeyWindow)
    }

    @Test("with both windows open the main window is the one that has the keys")
    func mainKeeps() {
        let (main, stage) = Self.mainWindow()
        let picture = Self.picture()
        defer { main.close(); picture.close(); KeyFocus.preferred = nil }

        main.makeKeyAndOrderFront(nil)
        KeyFocus.restore(in: main)
        picture.orderFront(nil)
        picture.makeKeyAndOrderFront(nil)

        #expect(NSApp.keyWindow !== picture)
        #expect(main.firstResponder === stage)
    }

    @Test("it is set up so that no operation can leave it key")
    func afterEveryOperation() {
        let (main, stage) = Self.mainWindow()
        let settings = Fake.settings()
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let director = DisplayDirector(settings: settings, screens: watcher)
        var made: [PictureWindowController] = []
        director.makeWindow = { info, d in
            let c = PictureWindowController(on: info, director: d)
            made.append(c)
            return c
        }
        defer {
            director.close()
            main.close()
            KeyFocus.preferred = nil
        }

        main.makeKeyAndOrderFront(nil)
        KeyFocus.restore(in: main)

        director.open(on: nil)
        check(main, stage, made)
        // And it really is wired: what the director computed reached the
        // window, which put the shoot and the burst in its own native title.
        #expect(made.first?.window?.title.isEmpty == false)
        director.setMode(.wholeBurst)
        check(main, stage, made)
        director.fillScreen(false)
        check(main, stage, made)
        director.fillScreen(true)
        check(main, stage, made)
        director.toggleHold()
        check(main, stage, made)
        director.refresh()
        check(main, stage, made)
        watcher.simulate(Fake.docked)
        check(main, stage, made)
    }

    private func check(_ main: NSWindow, _ stage: NSView, _ made: [PictureWindowController]) {
        for c in made {
            #expect(c.window?.isKeyWindow != true)
            #expect(c.window?.isMainWindow != true)
            if let w = c.window { #expect(NSApp.keyWindow !== w) }
        }
        #expect(main.firstResponder === stage)
    }

    @Test("the Tab ring can never reach into it, because it has no key window to ring in")
    func tabRing() {
        let picture = Self.picture()
        defer { picture.close() }
        let a = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let b = FocusableView(frame: NSRect(x: 20, y: 0, width: 10, height: 10))
        picture.contentView?.addSubview(a)
        picture.contentView?.addSubview(b)
        picture.orderFront(nil)
        // Every control the ring could reach is on the laptop, which is the
        // correct behaviour and not a gap.
        picture.selectNextKeyView(nil)
        #expect(!picture.isKeyWindow)
    }

    @Test("⌘W, ⌘` and the tab bar can none of them reach it")
    func windowBehaviour() {
        let settings = Fake.settings()
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let director = DisplayDirector(settings: settings, screens: watcher)
        var controller: PictureWindowController?
        director.makeWindow = { info, d in
            let c = PictureWindowController(on: info, director: d)
            controller = c
            return c
        }
        director.open(on: nil)
        defer { director.close() }
        let w = try? #require(controller?.window)

        // ⌘W targets the key window, which is never this one.
        #expect(w?.canBecomeKey == false)
        // ⌘` skips it.
        #expect(w?.collectionBehavior.contains(.ignoresCycle) == true)
        // It belongs to one Space on one display, and never follows him around.
        #expect(w?.collectionBehavior.contains(.managed) == true)
        #expect(w?.collectionBehavior.contains(.canJoinAllSpaces) == false)
        // "Prefer tabs when opening documents" cannot absorb it into the main
        // window's tab bar, which would put it on the laptop, silently.
        #expect(w?.tabbingMode == .disallowed)
        // We restore it ourselves, after the screen list is known.
        #expect(w?.isRestorable == false)
        // A minimised picture window is an invisible feature with no way back.
        #expect(w?.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        // It never floats above PhotoLab.
        #expect(w?.level == .normal)
        // A background drag pans the photograph; it does not move the window.
        #expect(w?.isMovableByWindowBackground == false)
        // No genie on a photograph.
        #expect(w?.animationBehavior == NSWindow.AnimationBehavior.none)
        // It is in the Window menu by title, so there is always a way to it.
        #expect(w?.isExcludedFromWindowsMenu == false)
    }

    @Test("the picture's box is inset so the photograph never touches the bezel")
    func geometry() {
        let settings = Fake.settings()
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let director = DisplayDirector(settings: settings, screens: watcher)
        var controller: PictureWindowController?
        director.makeWindow = { info, d in
            let c = PictureWindowController(on: info, director: d)
            controller = c
            return c
        }
        director.open(on: nil)
        defer { director.close() }
        guard let w = controller?.window else { Issue.record("no window"); return }

        // Filling a screen means the menu bar and the Dock keep their strip and
        // the window covers everything else — no Space is created, Mission
        // Control behaves normally, and ⌘-tab covers it like any other window.
        director.fillScreen(true)
        if let screen = w.screen {
            #expect(w.frame == screen.visibleFrame)
            // And the green button does the same thing.
            #expect(controller?.windowWillUseStandardFrame(w, defaultFrame: .zero)
                    == screen.visibleFrame)
        }

        // The photograph never touches the bezel, at whatever size the window
        // ends up.
        let box = DisplayMetric.pictureBox(in: CGRect(origin: .zero, size: w.frame.size))
        #expect(box.minX == DisplayMetric.pictureInset)
        #expect(w.frame.width - box.maxX == DisplayMetric.pictureInset)
        #expect(w.minSize == NSSize(width: 480, height: 360))
    }
}
