import SwiftUI

/// The viewer a page gets by calling `pipeline.viewFrames`.
///
/// Every extension grid gets a full-size look for free, so no page has to
/// build a loupe of its own and no verdict is ever taken off a 168 pt
/// thumbnail (EXT-04, EXT-05).
///
/// One seam, one line: the light table assigns its own viewer here and the
/// page gets Compare, 1:1 and the face aim without changing. Until it does,
/// this is a real full-size look on the app's own surround, which is what the
/// page needed in the first place.
///
/// A look is not only a look. Whoever opens it can offer a few marks with
/// one-letter keys (``ExtViewerMarking``) — in or out of a reel, a page's
/// own yes and no — so a decision about each frame is made on the frame, at
/// full size, one key a frame; and the look ends with where he stopped and
/// what he marked (``ExtViewerResult``), so the page behind it can go on from
/// there rather than make him find that card again.
///
/// Its keys are Choose Keepers' over Full Image (``ExtViewerKeys``): S F and
/// ← → the previous and next frame, E (or K) and D the marks a keep and a
/// drop leave (``ExtViewerVerdicts``), X clears, Q undoes, and Space or Esc
/// close it as Space opened it. It moved with the arrows only, and a mark
/// was whatever letter the page chose.
@MainActor
public enum ExtViewer {
    /// Whatever draws the look calls `close` exactly once, when it ends,
    /// however it ends.
    public typealias Maker = @MainActor (ShootSession, [String], Int, ExtViewerMarking,
                                         @escaping (ExtViewerResult) -> Void) -> AnyView

    public static var maker: Maker?

    /// `source` is which picture of each frame is drawn. The light table's
    /// viewer, when it fills the seam, takes over only `.frame`: a reel's
    /// frames are judged on what the reel is cut from.
    public static func make(session: ShootSession, stems: [String], startAt: Int,
                            source: ExtViewerSource = .frame,
                            marking: ExtViewerMarking = ExtViewerMarking(),
                            close: @escaping (ExtViewerResult) -> Void) -> AnyView {
        if case .frame = source, let maker { return maker(session, stems, startAt, marking, close) }
        return AnyView(ExtFullLook(session: session, stems: stems, startAt: startAt, source: source,
                                   marking: marking, close: close))
    }
}

/// One mark the viewer offers on every frame: drawn as a checkbox in its bar,
/// and toggled by its key.
public struct ExtViewerAction: Identifiable, Equatable, Sendable {
    public let id: String
    /// The words on the checkbox — the step's own, never the host's.
    public let label: String
    /// One lower-case letter, or empty for none.
    public let key: String

    /// One letter, or nothing. A letter Choose Keepers reads over a large
    /// frame means here what it means there, so a mark may take one only
    /// for that meaning: E or K for the mark a keep leaves, D for the mark a
    /// drop leaves (``ExtViewerVerdicts/derived(from:)``). Every other such
    /// letter — S and F move, X clears, Q undoes, R, W, Z, C, G, N, P, U —
    /// goes to nothing, so no page can make one of them mean something else.
    public init(id: String, label: String, key: String = "") {
        self.id = id
        self.label = label
        let k = key.lowercased()
        guard k.count == 1, k.first?.isLetter == true else { self.key = ""; return }
        let schemes = KeyMap.action(for: KeyMap.Press(k), mode: .fullImage)
        self.key = schemes == nil || schemes == .keep || schemes == .drop ? k : ""
    }

    /// The same key, as far as the viewer is concerned: E and K are one.
    var sameKeyAs: String { key == "k" ? "e" : key }

    /// A page's `actions`: `[{id, label, key}]`. An entry with no id or no
    /// label is left out, not the whole list, and a key already taken by an
    /// earlier one goes to nothing — E and K count as one key. Four at the
    /// most: past that it is a form.
    public static func parse(_ raw: Any?) -> [ExtViewerAction] {
        var out: [ExtViewerAction] = []
        for case let o as [String: Any] in raw as? [Any] ?? [] {
            guard let id = o["id"] as? String, !id.isEmpty,
                  let label = o["label"] as? String, !label.isEmpty,
                  !out.contains(where: { $0.id == id }) else { continue }
            var a = ExtViewerAction(id: id, label: label, key: o["key"] as? String ?? "")
            if !a.key.isEmpty, out.contains(where: { $0.sameKeyAs == a.sameKeyAs }) {
                a = ExtViewerAction(id: id, label: label)
            }
            out.append(a)
            if out.count == maximum { break }
        }
        return out
    }

    public static let maximum = 4
}

/// Which picture of a frame the viewer draws.
public enum ExtViewerSource {
    /// The photograph: the camera's JPEG, then the decode of the RAW.
    case frame
    /// What a reel is cut from, off `/reelthumb` at the viewer's size: the
    /// JPEG he exported, or the cull's decode where there is none. The tile
    /// showed his export and Space showed the camera's JPEG and then the
    /// unedited RAW, a different picture from the one that goes in the video.
    /// `exported` is the stems whose export is there, which the picture under
    /// the one URL depends on (`ReelThumbs.cached`).
    case reel(thumbs: ReelThumbs, src: String?, exported: Set<String>)
}

/// What Choose Keepers' three deciding keys leave on a frame in this look:
/// E (or K), D and X, each as a mark's id or `nil` for no mark. As on the
/// light table E and D mark the frame and go on to the next one, and X
/// marks it and stays.
public struct ExtViewerVerdicts: Equatable, Sendable {
    public var include: String?
    public var leaveOut: String?
    public var clear: String?

    public init(include: String?, leaveOut: String?, clear: String?) {
        self.include = include
        self.leaveOut = leaveOut
        self.clear = clear
    }

    /// A page's: the mark it gave E or K, the mark it gave D, and X back to
    /// no mark. None, when it gave neither: E, D and X then do nothing.
    public static func derived(from actions: [ExtViewerAction]) -> ExtViewerVerdicts? {
        let include = actions.first { $0.sameKeyAs == "e" }?.id
        let leaveOut = actions.first { $0.key == "d" }?.id
        guard include != nil || leaveOut != nil else { return nil }
        return ExtViewerVerdicts(include: include, leaveOut: leaveOut, clear: nil)
    }
}

/// What the viewer lets him mark, and what is marked when it opens. A frame
/// has one mark at most; pressing the key of the mark it has clears it.
public struct ExtViewerMarking {
    public var actions: [ExtViewerAction]
    /// Stem to action id.
    public var marks: [String: String]
    /// What E, D and X leave. A page's come from the keys it gave its marks;
    /// a step of the app's hands its own (Reels: E and X in the reel, D out).
    public var verdicts: ExtViewerVerdicts?
    /// Each change as it is made, for a step that shows it behind the viewer
    /// at once (Reels ticks the tile). A page hears them all when it closes.
    public var onMark: (@MainActor (_ stem: String, _ action: String?) -> Void)?
    /// A mark taken back with Q, for a step that keeps an undo of its own
    /// (Reels): the step takes its own last change back, rather than hear a
    /// new mark and keep it as one more change. Without it the step's undo
    /// and the viewer's disagreed: D then Q in the viewer left Edit ▸ Undo
    /// reading "Undo Include 06264", and the grid's Q then took the frame
    /// out again. Without it, a taken-back mark is heard as any other.
    public var onUndo: (@MainActor (_ stem: String, _ action: String?) -> Void)?

    public init(actions: [ExtViewerAction] = [], marks: [String: String] = [:],
                verdicts: ExtViewerVerdicts? = nil,
                onMark: (@MainActor (_ stem: String, _ action: String?) -> Void)? = nil,
                onUndo: (@MainActor (_ stem: String, _ action: String?) -> Void)? = nil) {
        self.actions = actions
        self.marks = marks.filter { m in actions.contains { $0.id == m.value } }
        let ids = Set(actions.map(\.id))
        let given = verdicts ?? ExtViewerVerdicts.derived(from: actions)
        // A verdict naming no mark on offer is no mark.
        self.verdicts = given.map { v in
            ExtViewerVerdicts(include: v.include.flatMap { ids.contains($0) ? $0 : nil },
                              leaveOut: v.leaveOut.flatMap { ids.contains($0) ? $0 : nil },
                              clear: v.clear.flatMap { ids.contains($0) ? $0 : nil })
        }
        self.onMark = onMark
        self.onUndo = onUndo
    }

    /// Q in the viewer: the frame's mark back to what it was. The step's own
    /// undo when it keeps one, so its Q and Edit ▸ Undo agree with what was
    /// taken back here; otherwise the mark it had before, heard as any other.
    @MainActor public func takeBack(_ stem: String, to before: String?) {
        if let onUndo { onUndo(stem, before) } else { onMark?(stem, before) }
    }

    /// The key a mark's checkbox names in its help tag: the deciding key
    /// that leaves it, from the menu bar's own table ("E or K"), or its own
    /// letter.
    @MainActor public func key(of action: ExtViewerAction) -> String? {
        if verdicts?.include == action.id { return LightTableKeys.key(CommandTable.ID.keep) ?? "E" }
        if verdicts?.leaveOut == action.id { return LightTableKeys.key(CommandTable.ID.drop) ?? "D" }
        return action.key.isEmpty ? nil : action.key.uppercased()
    }

    /// The same marks after one key: set, or cleared if it was already set.
    public static func toggled(_ marks: [String: String], stem: String, action: String) -> [String: String] {
        var m = marks
        m[stem] = m[stem] == action ? nil : action
        return m
    }
}

/// Where a look ended: the frame he was on, and every mark as it then stood.
public struct ExtViewerResult: Equatable, Sendable {
    public let index: Int
    public let stem: String
    public let marks: [String: String]

    public init(index: Int, stem: String, marks: [String: String]) {
        self.index = index
        self.stem = stem
        self.marks = marks
    }

    /// What `pipeline.viewFrames` resolves with.
    public var reply: [String: Any] { ["index": index, "stem": stem, "marks": marks] }
}

/// What a press means in the viewer.
public enum ExtLookMeaning: Equatable, Sendable {
    case previous, next
    /// E (or K), D and X: the marks ``ExtViewerVerdicts`` names.
    case include, leaveOut, clear
    /// A page's mark on a letter of its own: on, or off again.
    case toggle(String)
    /// Q, U or ⌘Z: the last mark made in this look, taken back, on its frame.
    case undo
    /// Space, as it opened the look, or Esc. Return is Done's own.
    case close
}

/// The viewer's keys: Choose Keepers', read over Full Image (DESIGN.md
/// §2.16-3). The viewer had keys of its own — ‹ › on the arrows alone and a
/// mark on whatever letter the page chose — so S and F did nothing in it and
/// the Reels grid's X meant one thing on the tile and another large.
@MainActor
public enum ExtViewerKeys {

    /// Keepers' action, as the viewer's meaning. Total over every action;
    /// `nil` is a key the viewer does not take. E, D and X are taken only
    /// when the look has verdicts to leave.
    public static func meaning(of a: KeyMap.Action, verdicts: Bool) -> ExtLookMeaning? {
        switch a {
        case .previousFrame: return .previous
        case .nextFrame: return .next
        case .keep: return verdicts ? .include : nil
        case .drop: return verdicts ? .leaveOut : nil
        case .clearMark: return verdicts ? .clear : nil
        case .undo: return .undo
        case .toggleFullImage, .leave: return .close
        // The light table's own, and the zoom: this viewer has no 1:1.
        case .previousPick, .nextPick, .nextBurst, .previousBurst, .reason, .keepOnly, .compare, .allBursts,
             .single, .oneToOne, .toggleOneToOne, .fit, .zoomIn, .zoomOut, .pan, .redo, .shortcuts:
            return nil
        }
    }

    /// Keepers' action for a press, read as Full Image reads it, with Space
    /// the whole picture: Space opened the look, so Space closes it.
    public static func keepersAction(_ p: KeyMap.Press) -> KeyMap.Action? {
        KeyMap.action(for: p, mode: .fullImage, spaceShowsWholePicture: true)
    }

    public static func action(_ p: KeyMap.Press, marking: ExtViewerMarking) -> ExtLookMeaning? {
        if let a = keepersAction(p) { return meaning(of: a, verdicts: marking.verdicts != nil) }
        guard !p.command, !p.option, !p.control, p.key == nil,
              let a = marking.actions.first(where: { !$0.key.isEmpty && $0.key == p.characters })
        else { return nil }
        return .toggle(a.id)
    }

    /// Only the two that move repeat; a held mark's key marks once.
    public static func allowsRepeat(_ p: KeyMap.Press) -> Bool {
        keepersAction(p)?.allowsRepeat ?? false
    }
}

/// The picture, the app's surround, and a way out. And, when he was offered
/// some, a checkbox for each mark with its key.
struct ExtFullLook: View {
    let session: ShootSession
    let stems: [String]
    let startAt: Int
    var source: ExtViewerSource = .frame
    let marking: ExtViewerMarking
    let close: (ExtViewerResult) -> Void

    @Environment(\.displayScale) private var displayScale

    @State private var index: Int = 0
    @State private var marks: [String: String] = [:]
    /// The marks made in this look, newest last, for Q: the frame and the
    /// mark it had before.
    @State private var made: [(stem: String, before: String?)] = []
    @State private var ended = false
    @FocusState private var focused: Bool

    init(session: ShootSession, stems: [String], startAt: Int, source: ExtViewerSource = .frame,
         marking: ExtViewerMarking = ExtViewerMarking(), close: @escaping (ExtViewerResult) -> Void) {
        self.session = session
        self.stems = stems
        self.startAt = startAt
        self.source = source
        self.marking = marking
        self.close = close
        _index = State(initialValue: min(max(0, startAt), max(0, stems.count - 1)))
        _marks = State(initialValue: marking.marks)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // The surround a photographer judges tone against. The
                // darkest variant belongs to Full Image; this is a viewer.
                Tokens.Palette.viewerBackground
                if let stem = current {
                    picture(stem)
                        .id(stem)
                        .accessibilityLabel(ShootSession.shortStem(stem))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: Tokens.Metric.relatedGap) {
                Button {
                    go(-1)
                } label: {
                    Label(Strings.Extensions.previousFrame, systemImage: Symbols.previous)
                        .labelStyle(.iconOnly)
                }
                .disabled(index == 0)
                // No key on the button: every key goes through the one
                // table below, and the tag names it from the menu bar's.
                .help(Strings.Extensions.markHelp(Strings.Extensions.previousFrame,
                                                  LightTableKeys.key(CommandTable.ID.previousFrame) ?? "←"))

                Button {
                    go(1)
                } label: {
                    Label(Strings.Extensions.nextFrame, systemImage: Symbols.next)
                        .labelStyle(.iconOnly)
                }
                .disabled(index >= stems.count - 1)
                .help(Strings.Extensions.markHelp(Strings.Extensions.nextFrame,
                                                  LightTableKeys.key(CommandTable.ID.nextFrame) ?? "→"))

                if let stem = current {
                    Text(ShootSession.shortStem(stem))
                        .font(.frameNumber)
                        .foregroundStyle(.secondary)
                    ForEach(marking.actions) { a in
                        Toggle(a.label, isOn: Binding(get: { marks[stem] == a.id },
                                                      set: { _ in mark(a.id) }))
                            .toggleStyle(.checkbox)
                            .help(marking.key(of: a).map { Strings.Extensions.markHelp(a.label, $0) } ?? a.label)
                    }
                }

                Spacer(minLength: Tokens.Metric.groupGap)

                Text(Strings.Extensions.ofFrames(index + 1, stems.count))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button(Strings.Extensions.done) { finish() }
                    .keyboardShortcut(.defaultAction)
                    .help(Strings.Extensions.doneHelp)
            }
            .padding(.horizontal, Tokens.Metric.windowMargin)
            .frame(height: Tokens.Metric.controlBar)
            .background(.bar)
        }
        .frame(minWidth: 720, minHeight: 520)
        .frame(idealWidth: 1000, idealHeight: 720)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // Every key through Keepers' table (`ExtViewerKeys`): S F and the
        // arrows move, E D X mark, Q undoes, and Space — it opened the look
        // from a grid — or Escape closes it. A mark's key is once a press:
        // held, it would tick and untick down the frame as the key repeated.
        .onKeyPress(phases: [.down, .repeat]) { press in
            let p = KeyMap.Press(press)
            guard let m = ExtViewerKeys.action(p, marking: marking) else { return .ignored }
            if p.isARepeat && !ExtViewerKeys.allowsRepeat(p) { return .handled }
            perform(m)
            return .handled
        }
        .onExitCommand { finish() }
        .onAppear { focused = true }
        // However the sheet goes — Done, a key, the page behind it going —
        // whoever opened it hears where it ended.
        .onDisappear { finish() }
        .accessibilityIdentifier("extension.viewer")
    }

    @ViewBuilder private func picture(_ stem: String) -> some View {
        switch source {
        case .frame:
            // A full look at one photograph: the RAW decode, at whatever
            // size this window is.
            FrameImageView(shoot: session.name, stem: stem, fit: .fit(inset: Tokens.Metric.viewerInset),
                           showing: .aPhotograph, pump: session.pump, onDisplay: { _, _ in })
        case .reel(let thumbs, let src, let exported):
            GeometryReader { geo in
                ReelThumbView(thumbs: thumbs, shoot: session.name, stem: stem, src: src,
                              version: exported.contains(stem) ? "exported" : "",
                              px: ReelThumbs.pixels(for: geo.size, scale: displayScale))
            }
            .padding(Tokens.Metric.viewerInset)
        }
    }

    private var current: String? {
        stems.indices.contains(index) ? stems[index] : nil
    }

    private func go(_ delta: Int) {
        index = min(max(0, index + delta), max(0, stems.count - 1))
    }

    private func perform(_ m: ExtLookMeaning) {
        switch m {
        case .previous: go(-1)
        case .next: go(1)
        case .include:
            set(marking.verdicts?.include)
            go(1)
        case .leaveOut:
            set(marking.verdicts?.leaveOut)
            go(1)
        case .clear: set(marking.verdicts?.clear)
        case .toggle(let id): mark(id)
        case .undo: undo()
        case .close: finish()
        }
    }

    /// A checkbox, or a mark's own letter: on, or off again.
    private func mark(_ action: String) {
        guard let stem = current else { return }
        set(ExtViewerMarking.toggled(marks, stem: stem, action: action)[stem])
    }

    /// The frame on screen takes this mark, or none.
    private func set(_ mark: String?) {
        guard let stem = current, marks[stem] != mark else { return }
        made.append((stem, marks[stem]))
        marks[stem] = mark
        marking.onMark?(stem, mark)
    }

    /// Q: the last mark made in this look, taken back, on its frame.
    private func undo() {
        guard let last = made.popLast() else { return }
        if let i = stems.firstIndex(of: last.stem) { index = i }
        marks[last.stem] = last.before
        marking.takeBack(last.stem, to: last.before)
    }

    private func finish() {
        guard !ended, let stem = current else { return }
        ended = true
        close(ExtViewerResult(index: index, stem: stem, marks: marks))
    }
}
