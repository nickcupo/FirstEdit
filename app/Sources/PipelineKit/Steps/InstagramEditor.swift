import SwiftUI

/// The editor, open on one photograph over the whole step (DESIGN.md §2.17).
///
/// A bar of what can be done, the photograph with its cut, and a bar of what
/// the cut comes to. The window is dragged to move it and by a corner to size
/// it; every move goes through the engine's own arithmetic, so what is drawn
/// is what will be kept. The cut is saved when he goes to another photograph,
/// closes, or undoes, and the tile shows it the moment he is back.
struct InstagramEditor: View {
    @Bindable var model: InstagramModel
    let pictures: InstagramPictures

    var body: some View {
        if let e = model.editor, let f = model.frames[e.stem] {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Metric.groupGap) {
                        where_(e)
                        Spacer(minLength: Tokens.Metric.relatedGap)
                        shapePicker(e, f)
                        viewPicker(e)
                        automaticButton(e, f)
                        doneButton
                    }
                    VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
                        HStack(spacing: Tokens.Metric.groupGap) {
                            where_(e)
                            Spacer(minLength: Tokens.Metric.relatedGap)
                            doneButton
                        }
                        HStack(spacing: Tokens.Metric.relatedGap) {
                            shapePicker(e, f)
                            viewPicker(e)
                            Spacer(minLength: 0)
                            automaticButton(e, f)
                        }
                    }
                }
                .padding(.horizontal, Tokens.Metric.groupGap)
                .padding(.vertical, 10)
                .background(.bar)
                Divider()
                InstagramStage(model: model, pictures: pictures, e: e, f: f)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A scroll over the photograph steps photographs, as it
                    // steps frames in Choose Keepers; never clicked.
                    .background { InstagramScrollArea(model: model).accessibilityHidden(true) }
                    .background(Tokens.Palette.fullImageBackground)
                    .clipped()
                Divider()
                facts(e, f)
                    .padding(.horizontal, Tokens.Metric.groupGap)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            .background(.background)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel(Text(Strings.Instagram.adjustTheCut))
        }
    }

    // MARK: - the top bar

    private func where_(_ e: InstagramEditorState) -> some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            HStack(spacing: 2) {
                Button { model.perform(.previous) } label: { Image(systemName: "chevron.left") }
                    .help(Strings.Instagram.previousHelp)
                    .accessibilityLabel(Text(Strings.Instagram.previousPhotograph))
                    .disabled(model.editorPosition?.index == 1)
                Button { model.perform(.next) } label: { Image(systemName: "chevron.right") }
                    .help(Strings.Instagram.nextHelp)
                    .accessibilityLabel(Text(Strings.Instagram.nextPhotograph))
                    .disabled(model.editorPosition.map { $0.index == $0.count } ?? true)
            }
            Text(ShootSession.shortStem(e.stem)).font(.headline).monospacedDigit()
            if let p = model.editorPosition {
                Text(Strings.Instagram.position(p.index, of: p.count))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .fixedSize()
    }

    private func shapePicker(_ e: InstagramEditorState, _ f: InstagramFrame) -> some View {
        Picker(Strings.Instagram.cutOrWhole, selection: Binding(get: { e.mode }, set: { model.setMode($0) })) {
            Text(Strings.Instagram.cutToButton(model.status?.ratio ?? "3:4")).tag("crop")
            Text(Strings.Instagram.whole).tag("whole")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!model.canEdit)
        .help(Strings.Instagram.cutOrWholeHelp)
    }

    private func viewPicker(_ e: InstagramEditorState) -> some View {
        Picker(Strings.Instagram.fit, selection: Binding(get: { e.view }, set: { v in
            switch v {
            case .fit: model.perform(.fit)
            case .oneToOne: model.perform(.oneToOne)
            case .result: if e.view != .result { model.perform(.result) }
            }
        })) {
            Text(Strings.Instagram.fit).tag(InstagramEditorView.fit).help(Strings.Instagram.fitHelp)
            Text(Strings.Instagram.oneToOne).tag(InstagramEditorView.oneToOne).help(Strings.Instagram.oneToOneHelp)
            Text(Strings.Instagram.result).tag(InstagramEditorView.result).help(Strings.Instagram.resultHelp)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func automaticButton(_ e: InstagramEditorState, _ f: InstagramFrame) -> some View {
        Button(Strings.Instagram.automatic) { model.perform(.automatic) }
            .disabled(!model.canEdit || (e.mode == "crop" && e.manual == nil && !e.dirty && !f.his))
            .help(Strings.Instagram.automaticHelp)
            .fixedSize()
    }

    private var doneButton: some View {
        Button(Strings.Instagram.done) { model.perform(.close) }
            .buttonStyle(.borderedProminent)
            .help(Strings.Instagram.doneHelp)
            .fixedSize()
    }

    // MARK: - the bottom bar

    /// "1080 × 1440 · keeps 64% of the frame · your cut · ⚠ … · not made yet"
    static func factsLine(_ model: InstagramModel, _ e: InstagramEditorState, _ f: InstagramFrame) -> String {
        factsParts(model, e, f).map(\.text).joined(separator: " · ")
    }

    /// The same line in parts, the warning marked so it alone is coloured.
    static func factsParts(_ model: InstagramModel, _ e: InstagramEditorState,
                           _ f: InstagramFrame) -> [(text: String, warns: Bool)] {
        guard model.canEdit, let size = f.frame, let out = model.draftOut else {
            return [(Strings.Instagram.cannotAdjustYet, false)]
        }
        let kept = Int((InstagramWindow.kept(e.rect, of: size) * 100).rounded())
        var parts: [(String, Bool)] = [(Strings.Instagram.size(out, kept: kept), false)]
        if e.mode == "crop" {
            parts.append((e.manual != nil ? Strings.Instagram.yourCut : Strings.Instagram.automaticWord, false))
        } else if f.mode_by == "you" || e.dirty {
            parts.append((Strings.Instagram.yourCut, false))
        }
        if !model.draftGridOK { parts.append((Strings.Instagram.gridWarning, true)) }
        parts.append((f.copy_current && !e.dirty ? Strings.Instagram.madeWord : Strings.Instagram.notMadeYet, false))
        return parts
    }

    private func factsText(_ e: InstagramEditorState, _ f: InstagramFrame) -> Text {
        var out = Text(verbatim: "")
        for (i, p) in Self.factsParts(model, e, f).enumerated() {
            if i > 0 { out = out + Text(verbatim: " · ").foregroundStyle(.secondary) }
            out = out + Text(p.text).foregroundStyle(p.warns ? AnyShapeStyle(Tokens.Palette.fault) : AnyShapeStyle(.primary))
        }
        return out
    }

    private func facts(_ e: InstagramEditorState, _ f: InstagramFrame) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.groupGap) {
                VStack(alignment: .leading, spacing: 2) {
                    factsText(e, f)
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let s = model.saved, s.stem == e.stem {
                        Text(s.text)
                            .font(.callout)
                            .foregroundStyle(s.failed ? AnyShapeStyle(Tokens.Palette.alarm) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                marks(e)
            }
            Text(Strings.Instagram.keysLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func marks(_ e: InstagramEditorState) -> some View {
        let mark = model.mark(e.stem)
        return HStack(spacing: 4) {
            Toggle(isOn: Binding(get: { mark == .include },
                                 set: { model.set(e.stem, $0 ? .include : nil) })) {
                Label(Strings.Instagram.include, systemImage: "checkmark")
            }
            .help(Strings.Instagram.includeHelp)
            Toggle(isOn: Binding(get: { mark == .leaveOut },
                                 set: { model.set(e.stem, $0 ? .leaveOut : nil) })) {
                Label(Strings.Instagram.leaveOut, systemImage: "xmark")
            }
            .help(Strings.Instagram.leaveOutHelp)
        }
        .toggleStyle(.button)
        .fixedSize()
    }
}

/// The photograph, in the view he chose: whole with the cut on it, at one
/// pixel to one pixel centred on the cut, or the copy as it will be written.
struct InstagramStage: View {
    @Bindable var model: InstagramModel
    let pictures: InstagramPictures
    let e: InstagramEditorState
    let f: InstagramFrame
    @Environment(\.displayScale) private var displayScale
    @State private var position = ScrollPosition()
    @State private var dragging = false

    var body: some View {
        let size = f.frame ?? PixelSize(3, 2)
        InstagramPicture(pictures: pictures, shoot: model.name, stem: f.stem, version: f.export_mtime,
                         px: e.view == .oneToOne ? InstagramPictures.full : InstagramPictures.large) { image in
            GeometryReader { geo in
                switch e.view {
                case .fit:
                    let box = fitted(size.aspect, in: CGSize(width: max(1, geo.size.width - 32),
                                                             height: max(1, geo.size.height - 32)))
                    photo(image, size: size, box: box.size)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                case .oneToOne:
                    oneToOne(image, size: size, viewport: geo.size)
                case .result:
                    result(image, size: size, in: geo.size)
                }
            }
        }
    }

    private func photo(_ image: CGImage?, size: PixelSize, box: CGSize) -> some View {
        InstagramEditorPhoto(model: model, e: e, f: f, size: size, image: image, box: box, dragging: $dragging)
    }

    /// The photograph at its own pixels, the cut in the middle of the view,
    /// and the view going with the cut whenever a key or a button moves it.
    private func oneToOne(_ image: CGImage?, size: PixelSize, viewport: CGSize) -> some View {
        let scale = max(1, displayScale)
        let box = CGSize(width: Double(size.w) / scale, height: Double(size.h) / scale)
        return ScrollView([.horizontal, .vertical]) {
            photo(image, size: size, box: box)
                .frame(width: max(box.width, viewport.width), height: max(box.height, viewport.height))
        }
        .scrollPosition($position)
        .scrollIndicators(.visible)
        .onAppear { centre(on: e.rect, scale: scale, content: box, viewport: viewport) }
        .onChange(of: e.stem) { _, _ in centre(on: e.rect, scale: scale, content: box, viewport: viewport) }
        .onChange(of: e.rect) { _, r in
            guard !dragging else { return }
            centre(on: r, scale: scale, content: box, viewport: viewport)
        }
    }

    /// Scrolls so the cut's centre is the view's, as near as the photograph's
    /// edges allow.
    private func centre(on r: PixelRect, scale: Double, content: CGSize, viewport: CGSize) {
        let p = Self.origin(centre: CGPoint(x: r.centre.x / scale, y: r.centre.y / scale),
                            content: content, viewport: viewport)
        position.scrollTo(point: p)
    }

    /// The scroll origin that puts `centre` in the middle of the viewport,
    /// kept inside the content.
    static func origin(centre: CGPoint, content: CGSize, viewport: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, centre.x - viewport.width / 2), max(0, content.width - viewport.width)),
                y: min(max(0, centre.y - viewport.height / 2), max(0, content.height - viewport.height)))
    }

    /// The export cut to the draft window and fitted at the size it is
    /// written: what the copy will be, made or not.
    @ViewBuilder
    private func result(_ image: CGImage?, size: PixelSize, in area: CGSize) -> some View {
        let out = model.draftOut ?? PixelSize(e.rect.w, e.rect.h)
        let box = fitted(out.aspect, in: CGSize(width: max(1, area.width - 48), height: max(1, area.height - 48)))
        ZStack {
            if let image, let cut = Self.crop(image, e.rect, of: size) {
                Image(decorative: cut, scale: 1)
                    .resizable()
                    .frame(width: box.width, height: box.height)
            } else {
                Tokens.Palette.viewerBackground.frame(width: box.width, height: box.height)
            }
        }
        .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .position(x: area.width / 2, y: area.height / 2)
        .accessibilityElement()
        .accessibilityLabel(Text(Strings.Instagram.result))
        .accessibilityValue(Text(InstagramEditor.factsLine(model, e, f)))
    }

    /// The window, cut out of whatever size of the export is loaded.
    static func crop(_ image: CGImage, _ r: PixelRect, of size: PixelSize) -> CGImage? {
        guard size.w > 0, size.h > 0 else { return nil }
        let sx = Double(image.width) / Double(size.w), sy = Double(image.height) / Double(size.h)
        let rect = CGRect(x: Double(r.x) * sx, y: Double(r.y) * sy, width: Double(r.w) * sx, height: Double(r.h) * sy)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty else { return nil }
        return image.cropping(to: rect)
    }
}

/// The photograph with its draft cut, the handles, and the drag.
struct InstagramEditorPhoto: View {
    @Bindable var model: InstagramModel
    let e: InstagramEditorState
    let f: InstagramFrame
    let size: PixelSize
    let image: CGImage?
    /// The photograph's size on screen.
    let box: CGSize
    @Binding var dragging: Bool

    /// What a drag started as, and the window it started from.
    private struct Start { let resize: Bool; let manual: InstagramManual }
    @State private var start: Start?
    @State private var pinchFrom: InstagramManual?

    private var editable: Bool { model.canEdit && e.mode == "crop" }
    /// Points of screen per pixel of the frame.
    private var k: Double { box.width / Double(max(1, size.w)) }

    private func onScreen(_ r: PixelRect) -> CGRect {
        CGRect(x: Double(r.x) * k, y: Double(r.y) * k, width: Double(r.w) * k, height: Double(r.h) * k)
    }

    var body: some View {
        let strip = model.draftOut.flatMap { InstagramWindow.gridStrip(out: $0) }
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: box.width, height: box.height)
            } else {
                Tokens.Palette.viewerBackground.frame(width: box.width, height: box.height)
            }
            if model.canEdit {
                InstagramCutLines(frame: size, cut: e.rect, other: model.draftOther,
                                  thirds: e.mode == "crop", gridStrip: strip, subject: f.subject)
                    .frame(width: box.width, height: box.height)
            }
            if editable { handles }
            cutElement
        }
        .frame(width: box.width, height: box.height)
        .contentShape(Rectangle())
        .gesture(drag, including: editable ? .all : .subviews)
        .simultaneousGesture(pinch, including: editable ? .all : .subviews)
    }

    private var handles: some View {
        let r = onScreen(e.rect)
        return ForEach(Array([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                              CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].enumerated()),
                       id: \.offset) { _, p in
            Rectangle()
                .fill(Color.white)
                .overlay { Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1) }
                .frame(width: 9, height: 9)
                .position(x: min(max(p.x, 4.5), box.width - 4.5), y: min(max(p.y, 4.5), box.height - 4.5))
                .allowsHitTesting(false)
        }
    }

    /// Near a corner of the cut: a drag there sizes it.
    private func nearCorner(_ p: CGPoint) -> Bool {
        let r = onScreen(e.rect)
        let reach = 14.0
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        where abs(c.x - p.x) <= reach && abs(c.y - p.y) <= reach { return true }
        return false
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard editable, let from = model.draftManual else { return }
                if start == nil {
                    let r = onScreen(e.rect)
                    let corner = nearCorner(v.startLocation)
                    guard corner || r.contains(v.startLocation) else { return }
                    start = Start(resize: corner, manual: from)
                    dragging = true
                }
                guard let s = start else { return }
                var m = s.manual
                if s.resize {
                    // About the centre: the corner under the pointer, the
                    // shape kept, so the window grows or shrinks both ways.
                    let cx = m.cx * Double(size.w), cy = m.cy * Double(size.h)
                    let qx = v.location.x / k, qy = v.location.y / k
                    let want = model.want
                    let cw = max(2 * abs(qx - cx), 2 * abs(qy - cy) * want)
                    let big = min(Double(size.w), Double(size.h) * want)
                    m.scale = min(1, max(InstagramWindow.leastScale, cw / big))
                } else {
                    m.cx += v.translation.width / box.width
                    m.cy += v.translation.height / box.height
                }
                model.setDraft(m)
            }
            .onEnded { _ in
                start = nil
                dragging = false
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                guard editable else { return }
                if pinchFrom == nil { pinchFrom = model.draftManual }
                guard var m = pinchFrom else { return }
                m.scale = min(1, max(InstagramWindow.leastScale, m.scale * v.magnification))
                model.setDraft(m)
            }
            .onEnded { _ in pinchFrom = nil }
    }

    /// The cut as VoiceOver meets it: one adjustable element, sized with
    /// increment and decrement, moved and reset with its actions.
    private var cutElement: some View {
        let r = onScreen(e.rect)
        return Color.clear
            .frame(width: max(1, r.width), height: max(1, r.height))
            .offset(x: r.minX, y: r.minY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(Strings.Instagram.theCut))
            .accessibilityValue(Text(InstagramEditor.factsLine(model, e, f)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.perform(.larger)
                case .decrement: model.perform(.smaller)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text(Strings.Instagram.moveLeft)) { model.perform(.nudge(dx: -1, dy: 0)) }
            .accessibilityAction(named: Text(Strings.Instagram.moveRight)) { model.perform(.nudge(dx: 1, dy: 0)) }
            .accessibilityAction(named: Text(Strings.Instagram.moveUp)) { model.perform(.nudge(dx: 0, dy: -1)) }
            .accessibilityAction(named: Text(Strings.Instagram.moveDown)) { model.perform(.nudge(dx: 0, dy: 1)) }
            .accessibilityAction(named: Text(Strings.Instagram.automatic)) { model.perform(.automatic) }
            .accessibilityAction(named: Text(Strings.Instagram.cutOrWhole)) { model.perform(.cutOrWhole) }
    }
}
