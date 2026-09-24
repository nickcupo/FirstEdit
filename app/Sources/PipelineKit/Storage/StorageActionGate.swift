import Foundation

/// Whether each action on the panel can do anything on this shoot, read off
/// the engine's own counts, and why not when it cannot (§2.8: the button
/// disabled and the reason beside it, never a disabled button with no reason).
///
/// On a finished shoot that had never been archived — his commonest case —
/// Bring the RAWs Back, Remove the Local RAWs and Let Go of the RAWs in iCloud
/// all looked as live as Copy the RAWs to iCloud, and each one started a dry
/// run, waited, and came back with one line: "has no archive manifest". Every
/// figure this reads is one `GET /api/storage` already carries; nothing here
/// works out a count of its own.
struct StorageActionGate: Equatable {
    let storage: Storage

    /// `nil` when the action can do something.
    func reason(_ action: StoragePanel.PanelAction) -> String? {
        let a = storage.archive
        let r = storage.retain
        switch action {
        case .push:
            // Not held back for Finish: it copies and takes nothing away, and
            // the backup he wants is the same night, before the card is
            // formatted for the next shoot. Removing the local RAWs waits.
            if a.todo == 0 { return Strings.Storage.pushNothing }
        case .pull:
            if a.pullable == 0 {
                return a.up == 0 ? Strings.Storage.nothingInICloud : Strings.Storage.pullNothing
            }
        case .reclaim:
            // The engine's own refusals are listed in the cache group above
            // the buttons, under a heading that says they are why; this
            // points there.
            if !storage.cache.refusals.isEmpty { return Strings.Storage.reclaimRefused }
            if storage.cache.files == 0 { return Strings.Storage.reclaimNothing }
        case .drop:
            if a.droppable == 0 {
                if a.here == 0 && a.here_evicted == 0 { return Strings.Storage.dropNothingHere }
                return a.up == 0 ? Strings.Storage.dropNothingUp : Strings.Storage.dropNothingChecked
            }
            // Copied up before Finish, the RAWs are still going to be read;
            // the engine refuses the same (`archive.drop`).
            if !r.finished { return Strings.Storage.dropNotFinished }
        case .expire:
            if a.up == 0 { return Strings.Storage.nothingInICloud }
            if !r.finished { return Strings.Storage.expireNotFinished }
            if !r.due, let days = r.due_in_days { return Strings.Storage.expireNotDue(days) }
        }
        return nil
    }

    /// The engine's figure for what the action would carry, for its label.
    /// Empty where it has none to give, or none worth saying.
    func size(_ action: StoragePanel.PanelAction) -> String {
        let text: String
        switch action {
        case .push: text = storage.archive.todo_text
        case .pull: text = storage.archive.pullable_text
        case .drop: text = storage.archive.droppable_text
        case .reclaim: text = storage.cache.bytes_text
        case .expire: text = ""
        }
        return reason(action) == nil && text != "0 B" ? text : ""
    }
}
