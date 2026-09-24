import AppKit

/// The Frame and View menus, behind the light table that is on screen.
///
/// `CommandHost` says the light table registers these against the same ids,
/// and `ViewerModel` says every menu item comes through `perform(_:)`. Neither
/// was true: nothing registered a single Frame or View row, so in the real app
/// both menus were greyed from top to bottom while K and D worked, and the keys
/// that exist only in the menu — ⌥⌘C, ⌥⌘R — did nothing at all while the
/// Keyboard Shortcuts window promised them.
///
/// **This changes nothing about where a key press goes.** A row whose key has
/// no ⌘, ⌃ or ⌥ declines that key when it arrives as a key press
/// (`MenuValidation.declinesKeyPress`) — and the light table's own monitor
/// (`LightTableKeys`) has taken it before any menu is asked — so K, D, N, the
/// digits, the arrows and Space reach `ViewerModel.key` with the repeat rule,
/// the held-key line and the display gate, and a clicked row goes through the
/// same `perform(_:)` the buttons use.
@MainActor
public enum LightTableCommands {

    /// Row → the press it is. One list, so a row cannot mean something
    /// different from its key.
    public static var rows: [(CommandID, KeyMap.Action)] {
        typealias ID = CommandTable.ID
        var out: [(CommandID, KeyMap.Action)] = [
            (ID.keep, .keep), (ID.drop, .drop), (ID.clearMark, .clearMark),
            (ID.compare, .compare), (ID.keepOnly, .keepOnly),
            (ID.nextFrame, .nextFrame), (ID.previousFrame, .previousFrame),
            (ID.nextForward, .nextPick), (ID.previousForward, .previousPick),
            (ID.finishBurst, .nextBurst), (ID.previousBurst, .previousBurst),
            (ID.single, .single), (ID.allBursts, .allBursts), (ID.fullImage, .toggleFullImage),
            (ID.actualSize, .oneToOne), (ID.zoomToFit, .fit), (ID.zoomIn, .zoomIn), (ID.zoomOut, .zoomOut),
        ]
        for r in DropReason.allCases { out.append((ID.reason(r), .reason(r.key))) }
        return out
    }

    /// The two rows that are not presses: they hand the frame to something
    /// else and change nothing of his.
    public static let copyFrameNumber = CommandTable.ID.copyFrameNumber
    public static let showFrameInFinder = CommandTable.ID.showFrameInFinder

    private static weak var attached: ViewerModel?
    /// The general pasteboard; a test's own, so a test run never touches his.
    static var pasteboard: NSPasteboard = .general

    /// The light table came on screen.
    public static func attach(_ model: ViewerModel, center: CommandCenter = .shared) {
        attached = model
        for (id, action) in rows {
            center.register(id, isEnabled: { [weak model] in model.map { enabled(action, $0) } ?? false },
                            state: { [weak model] in model.flatMap { state(action, $0) } },
                            title: { [weak model] in model.flatMap { title(action, $0) } }) { [weak model] in
                model?.perform(action)
            }
        }
        center.register(copyFrameNumber, isEnabled: { [weak model] in model?.currentStem != nil }) { [weak model] in
            guard let stem = model?.currentStem else { return }
            pasteboard.clearContents()
            pasteboard.setString(ShootSession.shortStem(stem), forType: .string)
        }
        center.register(showFrameInFinder, isEnabled: { [weak model] in model?.currentRow != nil }) { [weak model] in
            guard let model, let url = finderURL(model) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Go ▸ Next Step (⌘]), asked by the app-wide row before it moves. The
    /// line at the end of the shoot says "Continue to Presets (⌘])", and
    /// Continue records the last burst before going on (§2.5.2); ⌘] used to
    /// go straight on, so the key the line offered left the last burst
    /// unrecorded — Presets counted its picks as not looked through, and the
    /// next launch reopened on it. With that burst to finish this records it
    /// and then calls `go`, or stays where a refusal is; with nothing to
    /// finish it returns false and the row moves at once.
    public static func nextStep(then go: @escaping @MainActor () -> Void) -> Bool {
        guard let model = attached, model.nextStepFinishesTheShoot else { return false }
        Task { @MainActor in
            if await model.finishBeforeContinuing() { go() }
        }
        return true
    }

    /// The light table went away. Only its own rows, and only if a newer one
    /// has not already taken them.
    public static func detach(_ model: ViewerModel, center: CommandCenter = .shared) {
        guard attached === model else { return }
        attached = nil
        for (id, _) in rows { center.unregister(id) }
        center.unregister(copyFrameNumber)
        center.unregister(showFrameInFinder)
    }

    /// The RAW if it is on this Mac, otherwise the folder it belongs in — the
    /// RAWs may be in iCloud, and a Finder that opens on nothing says nothing.
    static func finderURL(_ model: ViewerModel) -> URL? {
        guard let row = model.currentRow else { return nil }
        let raw = URL(fileURLWithPath: model.session.info.raw, isDirectory: true)
        let file = raw.appendingPathComponent(row.file)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if FileManager.default.fileExists(atPath: raw.path) { return raw }
        return URL(fileURLWithPath: model.session.info.path, isDirectory: true)
    }

    /// A row is available when the press would do something on screen now.
    /// Greyed is honest; a row that bounces or does nothing is not.
    static func enabled(_ a: KeyMap.Action, _ m: ViewerModel) -> Bool {
        let hasFrame = m.currentStem != nil
        switch a {
        case .keep, .drop, .clearMark, .reason: return hasFrame && m.mode != .allBursts
        case .compare: return m.canCompare
        case .keepOnly: return m.mode == .compare
        case .nextFrame, .previousFrame, .nextPick, .previousPick: return hasFrame
        case .nextBurst: return m.canGoToNextBurst
        case .previousBurst: return m.burstIndex > 0
        case .oneToOne, .toggleOneToOne, .fit, .zoomIn, .zoomOut, .toggleFullImage:
            return hasFrame && m.mode != .allBursts
        default: return true
        }
    }

    /// A row that says what it does from here. Next Burst on the last burst
    /// goes on to Presets, and says so in the words of the line's own link.
    static func title(_ a: KeyMap.Action, _ m: ViewerModel) -> String? {
        a == .nextBurst && m.nextBurstLeavesForPresets ? Strings.LightTable.continueToPresets : nil
    }

    /// The checkmark beside a mode.
    static func state(_ a: KeyMap.Action, _ m: ViewerModel) -> Bool? {
        switch a {
        case .single: return m.mode == .single && !m.fullImage
        case .allBursts: return m.mode == .allBursts
        case .toggleFullImage: return m.fullImage
        default: return nil
        }
    }
}
