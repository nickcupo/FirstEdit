import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// Control parity (DESIGN.md §2.5.3, "One scheme"). He asked for it in so
/// many words: "make sure there is control parity so same way you maneuver
/// the other steps carries over and i'm not doing different buttons for
/// forward and backward".
///
/// The scheme is written out here key by key, as his rule, and not read from
/// `KeyMap`: the light table is one of the places held to it, not the judge
/// of it. Every place that shows photographs and takes keys is walked press
/// by press.
@Suite("One key means one thing on every page with photographs", .serialized)
@MainActor
struct KeyParityTests {

    /// The rule. `nil` is a key the scheme leaves free, for a place's own.
    static func scheme(_ p: KeyMap.Press) -> Control? {
        if p.option || p.control { return nil }
        if p.command {
            switch p.characters {
            case "z": return p.shift ? .redo : .undo
            // ⇧⌘0 is Go ▸ All Shoots, which the menu takes before any
            // place sees it; as a press it is ⌘0.
            case "0": return .oneToOne
            case "9": return .fit
            case "+", "=": return .zoomIn
            case "-": return .zoomOut
            case "/": return .shortcuts
            default: return nil
            }
        }
        if let key = p.key {
            switch key {
            case .left: return p.shift ? .pan : .previous
            case .right: return p.shift ? .pan : .next
            case .up: return p.shift ? .pan : .up
            case .down: return p.shift ? .pan : .down
            case .escape: return .back
            case .space: return .large
            case .return: return .primary
            }
        }
        if p.shift {
            switch p.characters {
            case "e", "k": return .keepOnly
            case "?", "/": return .shortcuts
            default: return nil
            }
        }
        switch p.characters {
        case "s": return .previous
        case "f": return .next
        case "w", "p": return .previousBurst
        case "r", "n": return .nextBurst
        case "e", "k": return .include
        case "d": return .leaveOut
        case "x", "0": return .clear
        case "1", "2", "3", "4", "5", "6": return .reason
        case "z": return .oneToOne
        case "c": return .compare
        case "g": return .allBursts
        case "q", "u": return .undo
        case "?": return .shortcuts
        default: return nil
        }
    }

    /// Every press worth trying: each letter, digit and sign plain, shifted
    /// and with ⌘, the arrows, Esc, Space and Return plain, shifted and with
    /// ⌘ — held down as well as pressed.
    static var presses: [KeyMap.Press] {
        var out = KeyMap.everyPress
        for k in [KeyMap.SpecialKey.left, .right, .up, .down, .escape, .space, .return] {
            out.append(KeyMap.Press(key: k, command: true))
        }
        for c in "abcdefghijklmnopqrstuvwxyz" {
            out.append(KeyMap.Press(String(c), option: true))
            out.append(KeyMap.Press(String(c), control: true))
        }
        return out
    }

    @Test("every place that shows photographs reads each key as the scheme does, or not at all, and with every key the scheme gives that meaning")
    func everyPlaceKeepsTheScheme() throws {
        // Every step and library page the app registers is either a place
        // here or one with no photograph a key acts on: a new step cannot
        // arrive with keys nobody holds to the scheme.
        StepRegistry.reset()
        WorkflowSteps.register()
        LightTableRegistration.register()
        StorageLearningRegistration.register()
        let placed = Set(KeyParity.places.map(\.step))
        for id in StepRegistry.registeredIDs + StepRegistry.registeredLibraryIDs {
            #expect(placed.contains(id) || KeyParity.noPhotographKeys.contains(id),
                    "\(id) is registered, and nothing says what its keys mean or that it has none")
        }
        for id in ["keepers", "instagram", "reels", "learned", "extension"] {
            #expect(placed.contains(id), "\(id) shows photographs and has no place walked here")
        }

        for place in KeyParity.places {
            var taken: [Control: [KeyMap.Press]] = [:]
            for p in Self.presses {
                guard let reading = place.reads(p) else { continue }
                let rule = Self.scheme(p)
                switch reading {
                case .shared(let c):
                    #expect(rule == c, "\(place.id): \(Self.name(p)) means \(c) here and \(rule.map(\.rawValue) ?? "nothing") everywhere else")
                    taken[c, default: []].append(p)
                case .own(let what):
                    #expect(rule == nil, "\(place.id): \(Self.name(p)) is \(what) here, over the scheme's \(rule.map(\.rawValue) ?? "")")
                    #expect([KeyMap.Mode.single, .fullImage, .compare, .allBursts, .review]
                                .allSatisfy { KeyMap.action(for: p, mode: $0) == nil },
                            "\(place.id): its own key \(Self.name(p)) is one Choose Keepers reads")
                }
            }
            // No different buttons for the same move: a meaning a place takes
            // by one key it takes by every key the scheme gives it. Held keys
            // count as the keys they are.
            for (c, _) in taken {
                let every = Self.presses.filter { Self.scheme($0) == c && !$0.isARepeat }
                for p in every where place.reads(p) != .shared(c) {
                    Issue.record("\(place.id): \(c) is taken by \(taken[c]!.map(Self.name).joined(separator: ", ")) but not by \(Self.name(p))")
                }
            }
        }
    }

    @Test("the moves, the marks, back and undo reach every place that decides, with the left hand's keys first")
    func theLeftHandEverywhere() {
        let deciding = ["keepers.single", "keepers.fullImage", "keepers.compare", "instagram.wall",
                        "instagram.editor", "reels.frames", "reels.list", "reels.large", "extension.viewer"]
        let must: [(KeyMap.Press, Control)] = [
            (.init("s"), .previous), (.init("f"), .next), (.init(key: .left), .previous), (.init(key: .right), .next),
            (.init("e"), .include), (.init("k"), .include), (.init("d"), .leaveOut),
            (.init("q"), .undo), (.init("z", command: true), .undo), (.init(key: .space), .large),
        ]
        for id in deciding {
            let place = KeyParity.places.first { $0.id == id }
            #expect(place != nil, "no place \(id)")
            for (p, c) in must {
                #expect(place?.reads(p) == .shared(c), "\(id): \(Self.name(p)) should be \(c)")
            }
        }
        // X clears wherever there is a mark to clear, the page viewer
        // included: its page gave no mark a clear of its own, so X is back
        // to no mark.
        for id in ["keepers.single", "instagram.wall", "instagram.editor", "reels.frames", "reels.list", "reels.large",
                   "extension.viewer"] {
            #expect(KeyParity.places.first { $0.id == id }?.reads(.init("x")) == .shared(.clear), "\(id): X")
        }
        // R and W go to the next and previous burst wherever there are
        // bursts to go to.
        for id in ["keepers.single", "keepers.fullImage", "keepers.allBursts", "keepers.presentation", "reels.frames",
                   "reels.list"] {
            let place = KeyParity.places.first { $0.id == id }
            #expect(place?.reads(.init("r")) == .shared(.nextBurst), "\(id): R")
            #expect(place?.reads(.init("w")) == .shared(.previousBurst), "\(id): W")
        }
        // Moving is S and F in every place with more than one photograph.
        for place in KeyParity.places {
            #expect(place.reads(.init("s")) == .shared(.previous), "\(place.id): S")
            #expect(place.reads(.init("f")) == .shared(.next), "\(place.id): F")
        }
    }

    @Test("on Reels, ↑ and ↓ are a row of the frames while they have the keys and the bursts list's while it does, and nothing else changes with where the keys are")
    func reelsWhereverTheKeysAre() {
        let frames = KeyParity.places.first { $0.id == "reels.frames" }
        let list = KeyParity.places.first { $0.id == "reels.list" }
        #expect(frames?.reads(.init(key: .down)) == .shared(.down))
        #expect(frames?.reads(.init(key: .up)) == .shared(.up))
        #expect(list?.reads(.init(key: .down)) == nil, "↓ in the list walks the bursts")
        #expect(list?.reads(.init(key: .up)) == nil)
        for p in Self.presses where p.key != .up && p.key != .down {
            #expect(frames?.reads(p) == list?.reads(p), "Reels: \(Self.name(p)) changes with where the keys are")
        }
    }

    @Test("with Settings ▸ Choosing's Space finishing the burst, Space is the next burst on the light table and still opens the photograph large everywhere else")
    func spaceFinishingTheBurst() {
        let space = KeyMap.Press(key: .space)
        for mode in [KeyMap.Mode.single, .fullImage] {
            #expect(KeyMap.action(for: space, mode: mode, spaceShowsWholePicture: false) == .nextBurst,
                    "Choose Keepers \(mode): Space finishes the burst under that setting")
        }
        // Every other place reads Space as the photograph large whatever the
        // setting says: they have no burst to finish, or opened large on it.
        for id in ["instagram.wall", "instagram.editor", "reels.frames", "reels.list", "reels.large",
                   "extension.viewer", "learned.review", "learned.review.large"] {
            #expect(KeyParity.places.first { $0.id == id }?.reads(space) == .shared(.large), "\(id): Space")
        }
        #expect(InstagramKeys.keepersAction(space, .wall) == .toggleFullImage)
        #expect(ReelsKeys.keepersAction(space) == .toggleFullImage)
        #expect(ExtViewerKeys.keepersAction(space) == .toggleFullImage)
    }

    @Test("a presentation reads a real key event as its place does: a plain arrow steps it, ⇧, ⌘, ⌥ or ⌃ with it does not, and Esc ends it with anything held")
    func presentationFromAnEvent() throws {
        _ = NSApplication.shared
        func event(_ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: c,
                                          charactersIgnoringModifiers: c, isARepeat: false, keyCode: code))
        }
        func arrow(_ scalar: Int) -> String { String(UnicodeScalar(UInt32(scalar))!) }
        // An arrow's own flags, which AppKit sets on every arrow press.
        let own: NSEvent.ModifierFlags = [.numericPad, .function]
        let arrows: [(String, UInt16, PresentationKey)] = [
            (arrow(NSLeftArrowFunctionKey), 123, .left), (arrow(NSRightArrowFunctionKey), 124, .right),
            (arrow(NSUpArrowFunctionKey), 126, .up), (arrow(NSDownArrowFunctionKey), 125, .down),
        ]
        let place = KeyParity.places.first { $0.id == "keepers.presentation" }
        for (c, code, k) in arrows {
            let plain = try event(c, code, own)
            #expect(PresentationKey.from(plain) == k)
            #expect(PresentationKey.from(plain) == PresentationKey.from(KeyMap.Press(event: plain)))
            for held: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
                let e = try event(c, code, own.union(held))
                #expect(PresentationKey.from(e) == nil, "\(k) with \(held.rawValue) held stepped the show")
                #expect(place?.reads(KeyMap.Press(event: e)) == nil, "the place and the monitor disagree")
            }
        }
        for held: NSEvent.ModifierFlags in [[], .shift, .command, .option, .control] {
            #expect(PresentationKey.from(try event("\u{1b}", 53, held)) == .escape)
        }
        #expect(PresentationKey.from(try event("f", 3)) == .right)
        #expect(PresentationKey.from(try event("r", 15)) == .nextBurst)
        #expect(PresentationKey.from(try event("f", 3, .command)) == nil, "⌘F is Find")
    }

    @Test("a page cannot give one of the scheme's letters a meaning of its own in the viewer")
    func aPageCannotTakeASchemeLetter() {
        for c in "abcdefghijklmnopqrstuvwxyz" {
            let k = String(c)
            let parsed = ExtViewerAction.parse([["id": "mark", "label": "Mark", "key": k]])
            let marking = ExtViewerMarking(actions: parsed)
            let reading = KeyParity.viewer(.init(k), marking)
            if let rule = Self.scheme(.init(k)) {
                // E, K and D are the page's mark as a keep or a drop leaves
                // it; every other letter of the scheme keeps its meaning or
                // does nothing.
                #expect(reading == nil || reading == .shared(rule), "a page's \(k) reads \(String(describing: reading))")
                #expect(parsed.first?.key == (rule == .include || rule == .leaveOut ? k : ""),
                        "a page asked for \(k) and got \(parsed.first?.key ?? "nothing")")
            } else {
                #expect(reading == .own("mark mark"), "a page's own \(k) is its mark")
            }
        }
        // E and K are one key: a second mark asking for the other gets none.
        let both = ExtViewerAction.parse([["id": "a", "label": "A", "key": "e"], ["id": "b", "label": "B", "key": "k"]])
        #expect(both.map(\.key) == ["e", ""])
    }

    static func name(_ p: KeyMap.Press) -> String {
        var s = ""
        if p.control { s += "⌃" }
        if p.option { s += "⌥" }
        if p.shift { s += "⇧" }
        if p.command { s += "⌘" }
        if let k = p.key {
            switch k {
            case .left: s += "←"
            case .right: s += "→"
            case .up: s += "↑"
            case .down: s += "↓"
            case .escape: s += "Esc"
            case .space: s += "Space"
            case .return: s += "Return"
            }
        } else {
            s += p.characters.uppercased()
        }
        return s
    }
}
