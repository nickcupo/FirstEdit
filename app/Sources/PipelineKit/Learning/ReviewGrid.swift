import SwiftUI

/// What a held version would change, sorted into what happens to each group
/// of his keepers — a value, so the order can be tested without drawing.
///
/// The grid used to be 48 tiles in the engine's flat order, each captioned
/// "Now: shown · New version: folded away", with the 16 that would go out of
/// sight mixed in among the 20 moved lower and the 12 shown more. Now each
/// change is said once, over its own group, and the one that costs him most
/// comes first.
///
/// Nothing here knows what the engine's words mean. Which change is worse is
/// read off the frames themselves: a frame that moves down from `now` to
/// `new` says `new` is lower, and the group that lands lowest leads.
struct ReviewGroups: Equatable {
    struct Group: Equatable, Identifiable {
        let now: String
        let new: String
        let down: Bool
        /// Every shoot's frames, in the engine's order, shoots in the order
        /// they first appear.
        let shoots: [(shoot: String, frames: [LearnerFrame])]
        var id: String { "\(now)→\(new)" }
        var count: Int { shoots.reduce(0) { $0 + $1.frames.count } }
        var frames: [LearnerFrame] { shoots.flatMap(\.frames) }

        static func == (a: Group, b: Group) -> Bool {
            a.now == b.now && a.new == b.new && a.down == b.down && a.frames == b.frames
        }
    }

    let groups: [Group]

    /// Every frame, in the order the grid draws them — the order the arrow
    /// keys move through.
    var frames: [LearnerFrame] { groups.flatMap(\.frames) }

    /// Whether more than one shoot is in any group, so a shoot's name is
    /// worth a line of its own.
    var namesShoots: Bool { Set(frames.map(\.shoot)).count > 1 }

    init(_ frames: [LearnerFrame]) {
        // How far down each word sits, from the moves the frames themselves
        // make: every downward move says its `new` is below its `now`.
        let below = Dictionary(grouping: frames.filter(\.down), by: \.now)
            .mapValues { Set($0.map(\.candidate)) }
        var depth: [String: Int] = [:]
        func depthOf(_ word: String, _ seen: Set<String> = []) -> Int {
            if let d = depth[word] { return d }
            guard !seen.contains(word) else { return 0 }
            // The longest run of moves down that ends at this word.
            let above = below.filter { $0.value.contains(word) }.map(\.key)
            let d = above.map { depthOf($0, seen.union([word])) + 1 }.max() ?? 0
            depth[word] = d
            return d
        }

        var order: [String] = []
        var byKey: [String: [LearnerFrame]] = [:]
        for f in frames {
            let key = "\(f.now)→\(f.candidate)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(f)
        }
        let made: [Group] = order.map { key in
            let fs = byKey[key] ?? []
            var shootOrder: [String] = []
            var byShoot: [String: [LearnerFrame]] = [:]
            for f in fs {
                if byShoot[f.shoot] == nil { shootOrder.append(f.shoot) }
                byShoot[f.shoot, default: []].append(f)
            }
            return Group(now: fs[0].now, new: fs[0].candidate, down: fs[0].down,
                         shoots: shootOrder.map { ($0, byShoot[$0] ?? []) })
        }
        // Down before up; among the downs, the lowest landing first; then the
        // engine's own order, which a stable sort keeps.
        groups = made.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.down != y.down { return x.down }
            if x.down {
                let (dx, dy) = (depthOf(x.new), depthOf(y.new))
                if dx != dy { return dx > dy }
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// What a press means in the review (DESIGN.md §2.9): Choose Keepers' keys,
/// read as its review reads them, so moving is the same four keys it is
/// everywhere — S F and ← → — and ↑ ↓ are a row, as on every grid.
enum ReviewMeaning: Equatable, Sendable {
    case previous, next, rowUp, rowDown
    /// Space: the frame large, and back.
    case large
    /// Esc over the frame large: back to the grid. Over the grid it is not
    /// taken, and goes on to Done.
    case back
}

enum ReviewKeys {
    /// The review has no verdict keys: E, D and X are simply not bound here,
    /// and nothing on it zooms, so Z is not either.
    static func action(_ p: KeyMap.Press, enlarged: Bool) -> ReviewMeaning? {
        switch KeyMap.action(for: p, mode: .review, spaceShowsWholePicture: true) {
        case .previousFrame?: return .previous
        case .nextFrame?: return .next
        case .previousPick?: return .rowUp
        case .nextPick?: return .rowDown
        case .toggleFullImage?: return .large
        case .leave?: return enlarged ? .back : nil
        default: return nil
        }
    }
}

/// The review's grid: one section per change, its frames together by shoot
/// and named by shoot where there is more than one, and tiles the keys can
/// walk.
///
/// S F and ← → move one frame, ↑ ↓ a row; Space or a double-click opens the
/// frame large, and Space or Esc puts it back. The review has no verdict
/// keys: E and D are simply not bound here (§2.9).
struct ReviewGrid: View {
    let groups: ReviewGroups
    let pump: ImagePump?
    /// The frame open large, the host's, so its Done gives Esc up to the
    /// frame while one is open.
    @Binding var enlarged: LearnerFrame?

    @State private var cursor: String?
    @State private var columns = 1
    @FocusState private var focused: Bool

    nonisolated static let tile: CGFloat = 220
    static let tileHeight: CGFloat = 150

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Metric.groupGap,
                           pinnedViews: [.sectionHeaders]) {
                    ForEach(groups.groups) { g in
                        Section {
                            // One grid per change, its frames kept together
                            // by shoot, and each tile naming its shoot where
                            // there is more than one: a line per shoot left a
                            // row with one tile in it for every shoot that
                            // lent a single frame.
                            tiles(g.frames)
                        } header: {
                            header(g)
                        }
                    }
                }
                .padding(Tokens.Metric.windowMargin)
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { columns = Self.columns(in: geo.size.width) }
                            .onChange(of: geo.size.width) { _, w in columns = Self.columns(in: w) }
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear {
                cursor = cursor ?? groups.frames.first?.id
                focused = true
            }
            // Every key through Keepers' table (`ReviewKeys`): the arrows
            // alone moved here, and S and F, which move on every other page
            // with photographs, did nothing.
            .onKeyPress(phases: [.down, .repeat]) { press in
                switch ReviewKeys.action(KeyMap.Press(press), enlarged: enlarged != nil) {
                case .previous?: return move(-1, scroll)
                case .next?: return move(1, scroll)
                case .rowUp?: return move(-columns, scroll)
                case .rowDown?: return move(columns, scroll)
                case .large?:
                    guard press.phase != .repeat else { return .handled }
                    if enlarged != nil { enlarged = nil; return .handled }
                    guard let f = current else { return .ignored }
                    enlarged = f
                    return .handled
                case .back?:
                    enlarged = nil
                    return .handled
                case nil:
                    return .ignored
                }
            }
            .overlay { if let f = enlarged { large(f) } }
        }
    }

    // MARK: a group, said once

    private func header(_ g: ReviewGroups.Group) -> some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            Image(systemName: g.down ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(g.down ? Tokens.Palette.fault : Tokens.Palette.kept)
                .accessibilityHidden(true)
            Text(Strings.Learning.reviewGroup(g.now, g.new, g.count))
                .font(.headline)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The window's own colour, so a pinned heading reads as part of the
        // sheet rather than a white band across it.
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func tiles(_ frames: [LearnerFrame]) -> some View {
        // Top-aligned, so a tile whose reason runs to two lines does not push
        // its row's pictures out of line with each other.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tile, maximum: 320),
                                     spacing: Tokens.Metric.groupGap, alignment: .top)],
                  alignment: .leading, spacing: Tokens.Metric.groupGap) {
            ForEach(frames) { frame in
                ReviewFrameCell(frame: frame, pump: pump, namesShoot: groups.namesShoots,
                                isCursor: focused && cursor == frame.id)
                    .id(frame.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { cursor = frame.id; enlarged = frame }
                    .onTapGesture { cursor = frame.id; focused = true }
            }
        }
    }

    // MARK: the keys

    private var current: LearnerFrame? {
        groups.frames.first { $0.id == cursor } ?? groups.frames.first
    }

    private func move(_ by: Int, _ scroll: ScrollViewProxy) -> KeyPress.Result {
        let all = groups.frames
        guard !all.isEmpty else { return .ignored }
        let at = all.firstIndex { $0.id == cursor } ?? 0
        let next = min(max(at + by, 0), all.count - 1)
        cursor = all[next].id
        if enlarged != nil { enlarged = all[next] }
        scroll.scrollTo(all[next].id)
        return .handled
    }

    /// How many tiles a row holds, the way `.adaptive` lays them out.
    nonisolated static func columns(in width: CGFloat) -> Int {
        let gap = Tokens.Metric.groupGap
        let inner = width - 2 * Tokens.Metric.windowMargin
        return max(1, Int((inner + gap) / (tile + gap)))
    }

    // MARK: one frame, large

    /// The frame at the size he can judge it, over the grid: the same pump,
    /// asked for a photograph rather than a thumbnail. Space, Esc or a click
    /// puts it back; S, F and the arrows move on without closing it.
    private func large(_ f: LearnerFrame) -> some View {
        VStack(spacing: Tokens.Metric.relatedGap) {
            Group {
                if let pump {
                    FrameImageView(shoot: f.shoot, stem: f.stem, fit: .standard,
                                   showing: .aPhotograph, pump: pump, onDisplay: { _, _ in })
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.Palette.viewerBackground)
            HStack(spacing: Tokens.Metric.relatedGap) {
                Text("\(f.shoot) · \(ShootSession.shortStem(f.stem))")
                    .font(.frameNumber)
                    .foregroundStyle(.secondary)
                Text(Strings.Learning.nowAndNew(f.now, f.candidate)).font(.callout)
                if !f.why.isEmpty {
                    Text(f.why).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(Strings.Learning.reviewLargeHint).font(.footnote).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, Tokens.Metric.windowMargin)
            .padding(.bottom, Tokens.Metric.relatedGap)
        }
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture { enlarged = nil }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review.large")
    }
}

/// One photograph he kept. What happens to it is the group's heading; the
/// tile carries only what is its own — its number and, when the engine gives
/// one, why it moves.
struct ReviewFrameCell: View {
    let frame: LearnerFrame
    let pump: ImagePump?
    /// Whether the frames around it come from more than one shoot, so this
    /// one says which it is from.
    var namesShoot = false
    var isCursor = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Group {
                if let pump {
                    // A picture of the frame, not a frame to judge: Space
                    // opens it large for that.
                    FrameImageView(shoot: frame.shoot, stem: frame.stem, fit: .fit(inset: 0),
                                   showing: .aThumbnail, pump: pump, onDisplay: { _, _ in })
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: ReviewGrid.tileHeight)
            .background(Tokens.Palette.viewerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isCursor ? 3 : 0)
            }

            Text(namesShoot ? "\(frame.shoot) · \(ShootSession.shortStem(frame.stem))"
                            : ShootSession.shortStem(frame.stem))
                .font(.frameNumber)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !frame.why.isEmpty {
                Text(frame.why.capitalizedFirst)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(frame.shoot), \(frame.stem). \(Strings.Learning.nowAndNew(frame.now, frame.candidate)). \(frame.why)")
        .accessibilityAddTraits(isCursor ? .isSelected : [])
        .accessibilityIdentifier("review.\(frame.stem)")
    }
}
