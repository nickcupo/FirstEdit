import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// A click in the sidebar while the light table was on screen left the
/// keyboard with the sidebar's list: K and N went dead, ↑ and ↓ moved him to
/// Cull or Presets mid-burst, and type-select could jump to a row by its first
/// letter. After the click, the photograph has the keyboard back — while the
/// selection is still Choose Keepers, and only then — and a way into the list
/// that was not a click (Tab, Full Keyboard Access, VoiceOver) keeps it.
@Suite("A click in the sidebar gives the light table its keys back", .serialized)
@MainActor
struct SidebarKeysTests {

    /// The stage stand-in: a view that takes the keyboard.
    final class Stage: NSView { override var acceptsFirstResponder: Bool { true } }
    /// The sidebar's list stand-in. SwiftUI's is an `NSOutlineView` too; an
    /// empty one declines the keyboard, so this one is told to take it.
    final class Sidebar: NSOutlineView { override var acceptsFirstResponder: Bool { true } }

    @MainActor struct Rig {
        let window: NSWindow
        let sidebar: NSOutlineView
        let stage: Stage
        let chrome: WindowChrome.ChromeView

        /// One pass of the event loop.
        func pass() { NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window) }

        /// A click in the list: the press is noted, the list takes the
        /// keyboard, the button comes up, the pass runs.
        func click() {
            chrome.pressed()
            window.makeFirstResponder(sidebar)
            pass()
        }

        func close() {
            window.close()
            KeyFocus.preferred = nil
            WindowChrome.ChromeView.buttonsHeld = { NSEvent.pressedMouseButtons != 0 }
        }
    }

    static func rig(onKeepers: @escaping @MainActor () -> Bool, stage preferred: Bool = true) -> Rig {
        _ = NSApplication.shared
        WindowChrome.ChromeView.buttonsHeld = { false }
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 620),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let content = w.contentView!
        let sidebar = Sidebar(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        let stage = Stage(frame: NSRect(x: 220, y: 0, width: 680, height: 600))
        let chrome = WindowChrome.ChromeView(autosaveName: "")
        chrome.keysBelongToTheStage = onKeepers
        content.addSubview(sidebar)
        content.addSubview(stage)
        content.addSubview(chrome)
        KeyFocus.preferred = preferred ? stage : nil
        return Rig(window: w, sidebar: sidebar, stage: stage, chrome: chrome)
    }

    @Test("on Choose Keepers, the pass after a click in the sidebar hands the keyboard back to the photograph")
    func backToTheStage() {
        let r = Self.rig(onKeepers: { true })
        defer { r.close() }
        r.click()
        #expect(r.window.firstResponder === r.stage)
        #expect(!r.chrome.pressPending)
    }

    @Test("Tab, Full Keyboard Access or VoiceOver moving into the list keeps it there")
    func keyboardRouteKeepsTheList() {
        let r = Self.rig(onKeepers: { true })
        defer { r.close() }
        r.window.makeFirstResponder(r.sidebar)
        r.pass()
        r.pass()
        #expect(r.window.firstResponder === r.sidebar)
    }

    @Test("a press is looked at once: a later keyboard route into the list is not taken back")
    func aPressIsLookedAtOnce() {
        let r = Self.rig(onKeepers: { true })
        defer { r.close() }
        // A click on the photograph: nothing to give back, and the press is
        // spent.
        r.chrome.pressed()
        r.window.makeFirstResponder(r.stage)
        r.pass()
        #expect(!r.chrome.pressPending)
        r.window.makeFirstResponder(r.sidebar)
        r.pass()
        #expect(r.window.firstResponder === r.sidebar)
    }

    @Test("while the button is still down nothing is decided, and the pass after it comes up decides")
    func waitsForTheButton() {
        let r = Self.rig(onKeepers: { true })
        defer { r.close() }
        WindowChrome.ChromeView.buttonsHeld = { true }
        r.chrome.pressed()
        r.window.makeFirstResponder(r.sidebar)
        r.pass()
        #expect(r.window.firstResponder === r.sidebar)
        #expect(r.chrome.pressPending)
        WindowChrome.ChromeView.buttonsHeld = { false }
        r.pass()
        #expect(r.window.firstResponder === r.stage)
    }

    @Test("in Compare or All Bursts, with no photograph to hold it, the window takes the keyboard from the list")
    func noStageTheWindowTakesIt() {
        let r = Self.rig(onKeepers: { true }, stage: false)
        defer { r.close() }
        r.click()
        #expect(r.window.firstResponder === r.window)
    }

    @Test("a click that left Choose Keepers leaves the keyboard with the sidebar")
    func leftTheStep() {
        let r = Self.rig(onKeepers: { false })
        defer { r.close() }
        r.click()
        #expect(r.window.firstResponder === r.sidebar)
    }

    @Test("a text field he is typing in keeps the keyboard")
    func textFieldKeepsIt() {
        let r = Self.rig(onKeepers: { true })
        defer { r.close() }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        r.window.contentView!.addSubview(field)
        r.chrome.pressed()
        r.window.makeFirstResponder(field)
        let editor = r.window.firstResponder
        r.pass()
        #expect(r.window.firstResponder === editor)
    }
}
