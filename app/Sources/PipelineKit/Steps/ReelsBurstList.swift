import SwiftUI
import AppKit

/// The left region: every burst worth cutting, searchable by number and
/// sortable by number or best first (DESIGN.md §2.6). For a timelapse, which
/// is made of a day rather than a burst, the same place lists what can be
/// played instead: the whole day, or one name filed in the shoot.
struct ReelsBurstList: View {
    @Bindable var model: ReelsModel
    let thumbs: ReelThumbs
    /// The page's keyboard: the burst field is one of its two places.
    var focus: FocusState<ReelsFocus?>.Binding
    /// The burst was just chosen in the list itself, by a click or an arrow,
    /// so the row is where he is looking and the list must not move.
    @State private var chosenHere = false

    var body: some View {
        VStack(spacing: 0) {
            if model.format == .timelapse {
                timelapseList
            } else {
                controls
                Divider()
                burstList
            }
        }
        // Not under the title bar: painted there, the list's colour cut the
        // window's title in two once the sidebar was put away.
        .background(.background, ignoresSafeAreaEdges: [])
    }

    // MARK: - bursts

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(Strings.Reels.findPrompt, text: $model.search)
                    .textFieldStyle(.plain)
                    .focused(focus, equals: .search)
                    // Return goes to the burst typed and hands the keys to its
                    // frames; while the field has the keyboard, Cut It does
                    // not take Return (ReelsStep). Return with nothing typed
                    // goes nowhere and hands the keys back, so the next Return
                    // is Cut It on the burst he was on; with a number that
                    // matches nothing the field keeps them, to fix it. Escape
                    // empties the field.
                    .onSubmit {
                        if model.goToSearched() || model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                            focus.wrappedValue = .grid
                        }
                    }
                    .onExitCommand {
                        model.search = ""
                        focus.wrappedValue = .grid
                    }
                    .onChange(of: model.search) { model.searchChanged() }
                    .background(TakesTheKeyboard(requests: model.findRequests))
                    .help(Strings.Reels.findHelp)
                    .accessibilityLabel(Text(Strings.Reels.findPrompt))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))

            Picker(Strings.Reels.order, selection: $model.order) {
                Text(Strings.Reels.byNumber).tag(ReelOrder.number)
                Text(Strings.Reels.bestFirst).tag(ReelOrder.best)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(Tokens.Metric.relatedGap + 2)
    }

    @ViewBuilder private var burstList: some View {
        let all = model.bursts
        let shown = model.shownBursts
        let covers = model.covers
        ScrollViewReader { proxy in
            List(selection: Binding(get: { model.burst }, set: { choose($0) })) {
                if model.options != nil && all.isEmpty {
                    Text(Strings.Reels.noBursts)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                }
                ForEach(shown) { b in
                    BurstRow(option: b, exported: model.exported(b), cover: covers[b.burst], shoot: model.session.name,
                             src: model.source.isEmpty ? nil : model.source, thumbs: thumbs,
                             lasted: model.length(of: b.burst), kept: model.keptOne(b))
                        .tag(Optional(b.burst))
                        .id(b.burst)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onAppear { if let b = model.burst { proxy.scrollTo(b, anchor: .center) } }
            // A burst chosen from elsewhere — N or P in the frames, the burst
            // field, the lister's first pick — is brought into sight, by as
            // little as that takes. One clicked here is not moved at all: it
            // was centred, so the row he clicked slid out from under the
            // pointer and the one he meant to click next moved with it.
            .onChange(of: model.burst) { _, b in
                guard !chosenHere else { chosenHere = false; return }
                if let b { withAnimation(nil) { proxy.scrollTo(b) } }
            }
        }
        Divider()
        Text(model.search.trimmingCharacters(in: .whitespaces).isEmpty
             ? Strings.Reels.bursts(all.count) : Strings.Reels.found(shown.count, of: all.count))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Metric.relatedGap + 2)
            .padding(.vertical, 6)
    }

    /// A row chosen. Clicked, the keys go to its frames, so ↑ and ↓ are a row
    /// of them straight away; chosen with the arrows, the list keeps them so
    /// the next arrow still moves down the list. E, D, Space and the rest
    /// work on the frames either way (`ReelsKeySink`).
    private func choose(_ b: String?) {
        guard let b, b != model.burst else { return }
        let byKeys = NSApp.currentEvent?.type == .keyDown
        chosenHere = true
        model.choose(burst: b, byKeys: byKeys)
        if !byKeys { DispatchQueue.main.async { focus.wrappedValue = .grid } }
    }

    // MARK: - timelapse

    @ViewBuilder private var timelapseList: some View {
        // One ForEach over every row, the whole day included, so the row he
        // chose is drawn chosen whichever it is.
        let rows = [(name: "", frames: model.options?.visible ?? 0)]
            + (model.options?.tags ?? []).map { (name: $0.name, frames: $0.frames) }
        List(selection: Binding<String?>(get: { model.tag }, set: { model.tag = $0 ?? "" })) {
            ForEach(rows, id: \.name) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name.isEmpty ? Strings.Reels.wholeDay : t.name)
                    Text(Strings.Reels.frames(t.frames))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .tag(Optional(t.name))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

/// One burst: the frame a cut of it lands on, its number, a dot when he kept
/// a frame of it, how much of it is exported and how long it lasted. "1 of 4
/// exported" was all a row said, so which bursts ran long enough to be worth
/// a reel, and which he had kept from, meant opening them.
struct BurstRow: View {
    let option: BurstOption
    /// The page's count, which is the wait's while it watches this burst.
    let exported: Int
    let cover: String?
    let shoot: String
    let src: String?
    let thumbs: ReelThumbs
    /// From its frames' capture times (`BurstLength`).
    var lasted: BurstLength? = nil
    var kept = false

    var body: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            Group {
                if let cover {
                    ReelThumbView(thumbs: thumbs, shoot: shoot, stem: cover, src: src,
                                  version: "\(option.exported)", fill: true)
                } else {
                    Tokens.Palette.viewerBackground
                }
            }
            .frame(width: 54, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.labelValueGap) {
                    Text(Strings.Reels.burst(option.burst))
                        .monospacedDigit()
                        .fixedSize()
                    if kept {
                        // His colour, as "368 you kept" is in the sidebar.
                        Circle()
                            .fill(Tokens.Palette.kept)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                            .help(Strings.Reels.keptOne)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: Tokens.Metric.labelValueGap)
                    // At the end of the line with the number, where it fits
                    // whole: under it, beside the export count, it was cut
                    // to "a…" in the 220 pt list.
                    if let lasted {
                        // Short, in one form down the whole list, so the
                        // number and the dot keep their room; said whole —
                        // "about 3 s" — to VoiceOver.
                        Text(Strings.Reels.lastedShort(lasted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                            .help(Strings.Reels.lastedHelp)
                            .accessibilityLabel(Strings.Reels.lasted(lasted))
                    }
                }
                Text(Strings.Reels.exportedOf(exported, option.frames))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(kept ? Strings.Reels.keptOne : "")
    }
}

/// Gives the text field it is drawn behind the keyboard each time `requests`
/// moves: Edit ▸ Find Burst… (⌘F) on Reels.
///
/// Setting the page's focus to the burst field left the keyboard on the
/// frames: SwiftUI would not move it into the field from there. AppKit does
/// it here, as a click in the field does, and the page's focus then reads the
/// field like any other time it has the keys.
private struct TakesTheKeyboard: NSViewRepresentable {
    let requests: Int

    func makeNSView(context: Context) -> Behind {
        let v = Behind()
        v.served = requests         // arriving on the page is not a ⌘F
        return v
    }

    func updateNSView(_ v: Behind, context: Context) {
        guard requests != v.served else { return }
        v.served = requests
        DispatchQueue.main.async { v.giveTheFieldTheKeyboard() }
    }

    final class Behind: NSView {
        var served = 0

        /// Never in the way of a click on the field it is behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The editable field that covers most of this view.
        func giveTheFieldTheKeyboard() {
            guard let window, let root = window.contentView else { return }
            let here = convert(bounds, to: nil)
            func fields(_ v: NSView) -> [NSTextField] {
                ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(fields)
            }
            let covering = fields(root)
                .filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
                .map { f in (f, f.convert(f.bounds, to: nil).intersection(here)) }
                .filter { !$0.1.isEmpty }
                .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
            if let field = covering?.0 { window.makeFirstResponder(field) }
        }
    }
}
