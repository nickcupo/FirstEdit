import SwiftUI

/// The right region: what the reel will be (DESIGN.md §2.6). Format with one
/// line each, speed, what the crop follows, slow into the cut, size, where
/// the pictures come from, and where the reel is saved. The explanation the
/// old page printed on every visit is behind the "?".
struct ReelsInspector: View {
    @Bindable var model: ReelsModel
    @Binding var showAbout: Bool
    /// `false` when the page is narrow and the format is chosen above the
    /// frames instead (`ReelsFormatBar`), so it is not under thirteen tiles.
    var showFormats = true

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            if showFormats {
                ReelsFormatHeader(showAbout: $showAbout)
                formats
                Divider()
            }
            settings
            Divider()
            output
        }
        .font(.callout)
    }

    // MARK: - format

    @ViewBuilder private var formats: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            ForEach(ReelFormat.allCases) { f in
                Button {
                    model.choose(format: f)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
                        Image(systemName: model.format == f ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(model.format == f ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Strings.Reels.formatName(f))
                                .foregroundStyle(.primary)
                            Text(Strings.Reels.formatNote(f))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(model.format == f ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    // MARK: - how it moves

    @ViewBuilder private var settings: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            row(Strings.Reels.speed) {
                Picker(Strings.Reels.speed, selection: $model.speed) {
                    ForEach(ReelsModel.speeds, id: \.self) { n in
                        Text(speedName(n)).tag(n)
                    }
                }
                .labelsHidden()
            }
            row(Strings.Reels.follows) {
                Picker(Strings.Reels.follows, selection: $model.follow) {
                    ForEach(model.followChoices) { c in
                        Text(c.label).tag(c.id)
                    }
                }
                .labelsHidden()
            }
            if let note = model.followChoices.first(where: { $0.id == model.follow })?.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only a cut slows into anything: the engine eases its last frames
            // into the frame it lands on, and the other shapes have no such
            // frame. A checkbox that did nothing for them is not drawn.
            if model.format == .cut {
                Toggle(Strings.Reels.slowIn, isOn: $model.ramp)
                    .help(Strings.Reels.slowInNote)
            }
            row(Strings.Reels.size) {
                Picker(Strings.Reels.size, selection: $model.size) {
                    ForEach(ReelSize.allCases) { s in
                        Text(Strings.Reels.sizeName(s)).tag(s)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private func speedName(_ n: Int) -> String {
        n == ReelsModel.speeds.first ? Strings.Reels.perSecondSlow(n)
            : n == ReelsModel.speeds.last ? Strings.Reels.perSecondFast(n)
            : Strings.Reels.perSecond(n)
    }

    // MARK: - where from, where to

    @ViewBuilder private var output: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            if model.format.isBurst, let sources = model.options?.sources, !sources.isEmpty {
                row(Strings.Reels.picturesFrom) {
                    Picker(Strings.Reels.picturesFrom,
                           selection: Binding(get: { model.source }, set: { model.choose(source: $0) })) {
                        Text(Strings.Reels.everywhere).tag("")
                        ForEach(sources, id: \.path) { s in
                            Text(Strings.Reels.folder(Self.tilde(s.path), s.frames)).tag(s.path)
                        }
                    }
                    .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                Text(Strings.Reels.savedIn).foregroundStyle(.secondary)
                HStack(spacing: Tokens.Metric.relatedGap) {
                    // The path as words, cut from the front: in a 260 pt
                    // column a path control drew only its folder icons.
                    Text(Self.tilde(model.reelDirectory))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .help(model.reelDirectory)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(Strings.Edit.show) { model.showFolder() }
                        .accessibilityLabel(Text("\(Strings.Edit.show) \(Strings.Reels.savedIn)"))
                }
                if let n = model.options?.reels.count, n > 0 {
                    Text(Strings.Reels.reelsCut(n)).font(.caption).foregroundStyle(.secondary)
                }
                if let note = model.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A label above its control: the inspector is too narrow for the two to
    /// share a line without cutting the words of either.
    @ViewBuilder private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Text(label).foregroundStyle(.secondary)
            control().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// "Format" and the "?" beside it, above whichever form the format takes.
struct ReelsFormatHeader: View {
    @Binding var showAbout: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Strings.Reels.format).font(.headline)
            Spacer()
            Button {
                showAbout.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help(Strings.Reels.aboutHelp)
            .accessibilityLabel(Text(Strings.Reels.aboutHelp))
            .popover(isPresented: $showAbout, arrowEdge: .leading) {
                ScrollView {
                    Text(Strings.Reels.aboutText)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Tokens.Metric.groupGap)
                }
                .frame(width: 360, height: 320)
            }
        }
    }
}

/// The format when the page is too narrow for the inspector's column: one
/// row of five above the frames, and the chosen one's line under it. The
/// format decides what the rest of the page is, so it is the one choice that
/// is never scrolled away under the frames.
struct ReelsFormatBar: View {
    @Bindable var model: ReelsModel
    @Binding var showAbout: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            ReelsFormatHeader(showAbout: $showAbout)
            Picker(Strings.Reels.format, selection: Binding(get: { model.format },
                                                           set: { model.choose(format: $0) })) {
                ForEach(ReelFormat.allCases) { f in
                    Text(Strings.Reels.formatName(f)).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Small, so the five fit the narrowest middle there is (about
            // 400 pt with the sidebar open at the least window) without
            // cutting a name or widening the page past its scroll view.
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Strings.Reels.formatNote(model.format))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
