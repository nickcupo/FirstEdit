import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Showing someone the shoot: a slideshow that **cannot change anything**, by
/// construction rather than by care (§5.6).
///
/// It has its own cursor. The light table's cursor, burst, filmstrip scroll and
/// zoom never move during Presentation, so there is nothing to restore when it
/// ends and nothing that could be recorded while it runs. Walking across bursts
/// in the deck is free precisely because the light table is not walking
/// anywhere.
public struct PresentationDeck: Equatable, Sendable {

    public enum Kind: String, CaseIterable, Sendable, Codable {
        /// His filled-green verdicts across the whole shoot, in shutter order.
        case whatIKept
        case thisBurst
        case wholeShoot

        public var title: String {
            switch self {
            case .whatIKept: return DisplayStrings.Menu.whatIKept
            case .thisBurst: return DisplayStrings.Menu.thisBurstEveryFrame
            case .wholeShoot: return DisplayStrings.Menu.wholeShootEveryFrame
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public let stem: String
        public let burst: Int
        public init(stem: String, burst: Int) { self.stem = stem; self.burst = burst }
    }

    public let kind: Kind
    public private(set) var entries: [Entry]
    public private(set) var index: Int

    public init(kind: Kind, entries: [Entry], startAt: Int = 0) {
        self.kind = kind
        self.entries = entries
        self.index = entries.isEmpty ? 0 : min(max(0, startAt), entries.count - 1)
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    public var currentStem: String? { entries.indices.contains(index) ? entries[index].stem : nil }
    public var currentBurst: Int? { entries.indices.contains(index) ? entries[index].burst : nil }

    // MARK: - the only four things a guest can do

    /// `false` means the end of the deck: the last frame stays, with an 8 pt
    /// rubber-band. No end-of-deck line, no tally, nothing written for a guest
    /// to read.
    @discardableResult
    public mutating func next() -> Bool { move(to: index + 1) }

    @discardableResult
    public mutating func previous() -> Bool { move(to: index - 1) }

    @discardableResult
    public mutating func nextBurst() -> Bool {
        guard let here = currentBurst else { return false }
        guard let i = entries.indices.first(where: { $0 > index && entries[$0].burst != here }) else {
            return false
        }
        index = i
        return true
    }

    @discardableResult
    public mutating func previousBurst() -> Bool {
        guard let here = currentBurst else { return false }
        // The first frame of the previous burst, not its last: ↑ lands where
        // ↓ would have started.
        guard let last = entries.indices.last(where: { $0 < index && entries[$0].burst != here }) else {
            return false
        }
        let want = entries[last].burst
        index = entries.indices.first(where: { entries[$0].burst == want }) ?? last
        return true
    }

    @discardableResult
    public mutating func first() -> Bool { move(to: 0) }

    @discardableResult
    public mutating func last() -> Bool { move(to: entries.count - 1) }

    private mutating func move(to i: Int) -> Bool {
        guard entries.indices.contains(i), i != index else { return false }
        index = i
        return true
    }

    // MARK: - building one from a shoot

    /// Built from the session, and from nothing the machine decided.
    ///
    /// "What I Kept" is his filled-green verdicts, in shutter order, starting
    /// at the kept frame nearest the one he is on. With no keepers it is empty,
    /// and the director falls back to This Burst and says so in one line.
    @MainActor
    public static func make(_ kind: Kind, from session: ShootSession) -> PresentationDeck {
        var entries: [Entry] = []
        switch kind {
        case .thisBurst:
            if let b = session.currentBurst {
                entries = b.frames.map { Entry(stem: $0, burst: session.cursor.burst) }
            }
        case .wholeShoot:
            for (i, b) in session.bursts.enumerated() {
                entries += b.frames.map { Entry(stem: $0, burst: i) }
            }
        case .whatIKept:
            for (i, b) in session.bursts.enumerated() {
                for stem in b.frames {
                    guard let row = session.rows[stem], VerdictValue.his(row) == .kept else { continue }
                    entries.append(Entry(stem: stem, burst: i))
                }
            }
        }
        return PresentationDeck(kind: kind, entries: entries,
                                startAt: nearest(to: session, in: entries))
    }

    /// The entry nearest where he is now, so the deck opens on something he
    /// recognises rather than on frame one of the shoot.
    @MainActor
    private static func nearest(to session: ShootSession, in entries: [Entry]) -> Int {
        guard !entries.isEmpty else { return 0 }
        if let stem = session.currentStem, let exact = entries.firstIndex(where: { $0.stem == stem }) {
            return exact
        }
        let burst = session.cursor.burst
        if let inBurst = entries.firstIndex(where: { $0.burst >= burst }) { return inBurst }
        return entries.count - 1
    }
}

/// The keys Presentation answers to, and nothing else.
///
/// Esc arrives at the main window like every key — but a Space switch (true
/// full screen on the external, or a Mission Control gesture mid-show) can
/// leave an app with **no** key window at all, and then no key arrives
/// anywhere. So for the life of Presentation the director also watches for
/// these app-wide, before dispatch. A guest can never be stuck in a chrome-less
/// window with no way out.
///
/// They are Choose Keepers' keys for the same moves (DESIGN-displays.md §5.6):
/// S and F step the deck as ← and → do, and R and W (or N and P) go to the
/// next and previous burst in it as ↓ and ↑ do. The deck took the arrows
/// only, so F went on to the light table's frame behind the show while →
/// stepped the show. It has its own cursor, so none of them records
/// anything on the light table.
public enum PresentationKey: String, Sendable, Equatable, CaseIterable {
    case escape, left, right, up, down, home, end, nextBurst, previousBurst
}

extension PresentationKey {
    /// A press as `KeyMap` reads it, by Keepers' own table: the same action
    /// is the same move in the deck. A letter only with no modifier at all —
    /// ⌘F is Find, ⌘R is Cull — and Home and End, which the table has no
    /// key for, come from the key code (`from(_:)`).
    public static func from(_ p: KeyMap.Press) -> PresentationKey? {
        if p.key == nil, p.command || p.option || p.control || p.shift { return nil }
        switch KeyMap.action(for: p, mode: .single) {
        case .previousFrame?: return .left
        case .nextFrame?: return .right
        case .previousPick?: return .up
        case .nextPick?: return .down
        case .nextBurst?: return .nextBurst
        case .previousBurst?: return .previousBurst
        case .leave?: return .escape
        default: return nil
        }
    }
}

#if canImport(AppKit)
extension PresentationKey {
    /// A key event, for the local monitor. Esc whatever else is held, so a
    /// show can always be ended; everything else only while nothing is being
    /// typed into, because the watch is app-wide and a key it took would be
    /// taken from a text field too. The arrows and the letters are read by
    /// `from(_:)` on the press — the table Choose Keepers reads — so a plain
    /// arrow steps the show and ⇧, ⌘, ⌥ or ⌃ with it does not: ⇧→ is a pan
    /// and ⌘→ nothing in the scheme (`KeyParity`), where the arrows used to
    /// be taken by key code with anything held, ⌘← and ⌘→ in a text field
    /// included. Home and End, which the table has no key for, only plain.
    @MainActor
    public static func from(_ event: NSEvent) -> PresentationKey? {
        if event.keyCode == 53 { return .escape }
        guard !MenuValidation.isTextEditing(in: NSApp.keyWindow) else { return nil }
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 115: return held.isEmpty ? .home : nil
        case 119: return held.isEmpty ? .end : nil
        default: return from(KeyMap.Press(event: event))
        }
    }
}
#endif
