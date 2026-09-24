import SwiftUI

/// The one rung that deletes photographs.
///
/// It is `PlanSheet` at `.deletesPhotographs`, named here because the rule it
/// carries is worth a file of its own: **the number of photographs has to be
/// typed, and it is the number the list was drawn with.**
public struct ExpireSheet: View {
    let shoot: String
    let model: StorageModel
    /// Unticked when he opens it. A caller passes true only to show what the
    /// ticked state looks like — a snapshot, or a test.
    let includeOnlyCopies: Bool
    let close: () -> Void

    public init(shoot: String, model: StorageModel, includeOnlyCopies: Bool = false,
                close: @escaping () -> Void) {
        self.shoot = shoot
        self.model = model
        self.includeOnlyCopies = includeOnlyCopies
        self.close = close
    }

    public var body: some View {
        PlanSheet(rung: .deletesPhotographs,
                  request: StorageModel.Request("expire"),
                  model: model,
                  includeOnlyCopies: includeOnlyCopies,
                  close: close)
    }
}

/// Whether the button that deletes photographs may work yet.
///
/// A value, not a view, so the rule can be tested without drawing anything.
/// Three things have to be true at once, and each of them was a bug once:
///
/// - The list on screen has to be **this** list. Ticking the checkbox changes
///   what would happen, so the old list stops counting the instant it is
///   ticked and the button waits for the new one.
/// - The token has to be there. A plan the engine refused, or one already
///   spent, has none.
/// - The typed text has to equal the count **the list was drawn with**. Not a
///   count measured now: the engine checks the same thing on its side, and
///   the app passes the text through rather than deciding for itself.
public struct ExpireGate: Sendable, Equatable {
    public let plan: Plan?
    public let listIsCurrent: Bool
    public let typed: String
    public let busy: Bool

    public init(plan: Plan?, listIsCurrent: Bool, typed: String, busy: Bool = false) {
        self.plan = plan
        self.listIsCurrent = listIsCurrent
        self.typed = typed
        self.busy = busy
    }

    /// Frozen at the value the list was drawn against, never recomputed.
    public var protectedKeepers: Int { plan?.protectedKeepers ?? 0 }
    public var doomed: Int { plan?.doomed ?? 0 }

    public var isOpen: Bool {
        guard let p = plan, listIsCurrent, !busy, p.isApplicable else { return false }
        guard p.doomed > 0 else { return true }
        return typed.trimmingCharacters(in: .whitespaces) == String(p.doomed)
    }

    /// What goes on the button: the engine's own label, which carries the
    /// engine's own number.
    public var confirmLabel: String {
        let l = plan?.label ?? ""
        return l.isEmpty ? Strings.Storage.nothingToDo : l
    }

    /// Whether the button would do anything at all. Where the engine's list
    /// is empty the button says so instead — and a sentence saying there is
    /// nothing to do is not a warning, so it is not drawn in red.
    public var isAnAction: Bool { !(plan?.label ?? "").isEmpty }
}
