import SwiftUI

/// The lines on a photograph (DESIGN.md §2.17): a scrim outside the clear
/// cut, the clear cut, and the faint window of the option not taken.
///
/// Drawn in fractions of the frame, over exactly the picture's rectangle, so
/// the line on the screen is the edge of the copy that will be written.
struct InstagramCutLines: View {
    let frame: PixelSize
    let cut: PixelRect?
    let other: PixelRect?
    /// Exported again: the old lines, half as strong.
    var faded = false
    var scrim = true
    /// The editor's extras: the thirds and the profile grid's strip.
    var thirds = false
    var gridStrip: ClosedRange<Double>?
    var subject: InstagramSubject?

    var body: some View {
        Canvas { ctx, size in
            guard frame.w > 0, frame.h > 0 else { return }
            let sx = size.width / Double(frame.w), sy = size.height / Double(frame.h)
            func r(_ p: PixelRect) -> CGRect {
                CGRect(x: Double(p.x) * sx, y: Double(p.y) * sy, width: Double(p.w) * sx, height: Double(p.h) * sy)
            }
            let strength = faded ? 0.5 : 1.0
            if let c = cut, scrim {
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addRect(r(c))
                ctx.fill(outside, with: .color(.black.opacity(0.35 * strength)), style: FillStyle(eoFill: true))
            }
            if let o = other {
                ctx.stroke(Path(r(o).insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.5 * strength)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            guard let c = cut else { return }
            let cr = r(c)
            if thirds {
                var p = Path()
                for f in [1.0 / 3, 2.0 / 3] {
                    p.move(to: CGPoint(x: cr.minX + cr.width * f, y: cr.minY))
                    p.addLine(to: CGPoint(x: cr.minX + cr.width * f, y: cr.maxY))
                    p.move(to: CGPoint(x: cr.minX, y: cr.minY + cr.height * f))
                    p.addLine(to: CGPoint(x: cr.maxX, y: cr.minY + cr.height * f))
                }
                ctx.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
            if let g = gridStrip {
                // What the profile grid leaves out of the post, shaded, and
                // the strip it shows edged with a dotted line — not the
                // dashes of the faint window, which is another thing.
                let left = CGRect(x: cr.minX, y: cr.minY, width: cr.width * g.lowerBound, height: cr.height)
                let right = CGRect(x: cr.minX + cr.width * g.upperBound, y: cr.minY,
                                   width: cr.width * (1 - g.upperBound), height: cr.height)
                ctx.fill(Path(left), with: .color(.black.opacity(0.18)))
                ctx.fill(Path(right), with: .color(.black.opacity(0.18)))
                var p = Path()
                for f in [g.lowerBound, g.upperBound] {
                    p.move(to: CGPoint(x: cr.minX + cr.width * f, y: cr.minY))
                    p.addLine(to: CGPoint(x: cr.minX + cr.width * f, y: cr.maxY))
                }
                ctx.stroke(p, with: .color(.white.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 4]))
            }
            // A dark hairline just outside the white, so the edge reads on a
            // white sky as well as on a dark wall.
            ctx.stroke(Path(cr.insetBy(dx: 0.5, dy: 0.5)), with: .color(.black.opacity(0.7 * strength)), lineWidth: 1)
            ctx.stroke(Path(cr.insetBy(dx: 2, dy: 2)), with: .color(.white.opacity(strength)), lineWidth: 2)
            if let s = subject {
                let p = CGPoint(x: s.cx * size.width, y: s.cy * size.height)
                let dot = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: dot), with: .color(.white))
                ctx.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.7)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The largest rectangle of `aspect` (width over height) inside `box`,
/// centred.
func fitted(_ aspect: Double, in box: CGSize) -> CGRect {
    guard aspect > 0, box.width > 0, box.height > 0 else { return CGRect(origin: .zero, size: box) }
    let w = min(box.width, box.height * aspect)
    let h = w / aspect
    return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
}

/// Whether a loaded picture is the frame the record describes: an export
/// made again at another shape is not, and its old cut is not drawn on it.
func sameShape(_ image: CGImage?, _ frame: PixelSize?) -> Bool {
    guard let image, let frame, image.height > 0, frame.h > 0 else { return false }
    let a = Double(image.width) / Double(image.height)
    return abs(a / frame.aspect - 1) <= 0.01
}

/// One exported photograph on the wall, its cut drawn on it.
struct InstagramTile: View {
    let frame: InstagramFrame
    let model: InstagramModel
    let pictures: InstagramPictures
    var focus: FocusState<String?>.Binding

    private var mark: InstagramMark? { model.mark(frame.stem) }
    private var included: Bool { mark == .include }
    private var leftOut: Bool { mark == .leaveOut }
    private var dimmed: Bool { model.anyIncluded && !included }
    private var ringed: Bool { model.ringShown && model.ring == frame.stem }
    private var planning: Bool { if case .running = model.plan { return true } else { return false } }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                Button { model.open(frame.stem) } label: {
                    picture
                        .aspectRatio(1, contentMode: .fit)
                        .saturation(leftOut ? 0 : 1)
                        .overlay {
                            if leftOut {
                                ZStack {
                                    Color.black.opacity(0.55)
                                    Text(Strings.Instagram.leftOut)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused(focus, equals: frame.stem)
                .help(Strings.Instagram.tileHint)

                Button { model.toggleInclude(frame.stem) } label: {
                    Image(systemName: included ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(included ? Color.white : Color.white.opacity(0.9),
                                         included ? Tokens.Palette.kept : Color.black.opacity(0.35))
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Strings.Instagram.includeHelp)
            }
            .overlay(alignment: .topTrailing) { badges }
            .overlay(alignment: .bottomLeading) {
                if !frame.isPlanned && frame.state == .unplanned && planning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(ringed ? Color.accentColor : Color.primary.opacity(0.12),
                                   lineWidth: ringed ? 2.5 : 0.5)
            }
            caption
        }
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ShootSession.shortStem(frame.stem)))
        .accessibilityValue(Text(InstagramTile.spoken(frame, mark: mark, planning: planning)))
        .accessibilityHint(Text(Strings.Instagram.tileHint))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(included ? .isSelected : [])
        .accessibilityAction { model.open(frame.stem) }
        .accessibilityAction(named: Text(Strings.Instagram.include)) { model.set(frame.stem, .include) }
        .accessibilityAction(named: Text(Strings.Instagram.leaveOut)) { model.set(frame.stem, .leaveOut) }
        .accessibilityAction(named: Text(Strings.Instagram.clear)) { model.set(frame.stem, nil) }
        .accessibilityAction(named: Text(Strings.Instagram.adjustTheCut)) { model.open(frame.stem) }
    }

    private var picture: some View {
        ZStack {
            Tokens.Palette.viewerBackground
            InstagramPicture(pictures: pictures, shoot: model.name, stem: frame.stem,
                             version: frame.export_mtime) { image in
                GeometryReader { geo in
                    let aspect = image.map { Double($0.width) / Double(max(1, $0.height)) } ?? frame.frame?.aspect ?? 1.5
                    let box = fitted(aspect, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .frame(width: box.width, height: box.height)
                        }
                        if let size = frame.frame, sameShape(image, size), frame.state != .unplanned {
                            InstagramCutLines(frame: size, cut: frame.cut?.rect, other: frame.other?.rect,
                                              faded: frame.state == .stale)
                                .frame(width: box.width, height: box.height)
                        }
                    }
                    .offset(x: box.minX, y: box.minY)
                }
            }
        }
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 3) {
            if frame.gridMiss {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black, Tokens.Palette.fault)
                    .help(Strings.Instagram.gridBadge)
            }
            if frame.isPlanned && frame.his {
                Image(systemName: "pencil")
                    .foregroundStyle(.white)
                    .help(Strings.Instagram.yoursBadge)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background {
            if frame.gridMiss || (frame.isPlanned && frame.his) {
                Capsule().fill(Color.black.opacity(0.45))
            }
        }
        .padding(6)
    }

    private var caption: some View {
        let line = InstagramTile.stateLine(frame, planning: planning)
        return VStack(alignment: .leading, spacing: 1) {
            Text(ShootSession.shortStem(frame.stem)).font(.caption.weight(.bold)).monospacedDigit()
            Text(line)
                .font(.caption)
                .foregroundStyle(frame.gridMiss ? AnyShapeStyle(Tokens.Palette.fault) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
                .help(line)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - words

    /// The shape a copy on disk was written at: "3:4", "4:5", or its size.
    static func copyShape(_ out: PixelSize) -> String {
        if out.w == InstagramWindow.wide {
            if out == InstagramWindow.outSize(want: 0.75) { return "3:4" }
            if out == InstagramWindow.outSize(want: 0.8) { return "4:5" }
        }
        return "\(out.w) × \(out.h)"
    }

    /// The one line under a tile.
    @MainActor static func stateLine(_ f: InstagramFrame, planning: Bool) -> String {
        switch f.state {
        case .unplanned:
            return planning ? Strings.Instagram.workingOut : Strings.Instagram.notWorkedOut
        case .stale:
            return f.made ? Strings.Instagram.exportedAgainMade : Strings.Instagram.exportedAgain
        case .planned:
            break
        }
        if f.gridMiss { return Strings.Instagram.gridCuts }
        let what = f.isWhole ? Strings.Instagram.leftWhole : Strings.Instagram.cutTo(f.cut?.shape ?? "")
        var more: String?
        if let copy = f.copy {
            if f.copy_current {
                more = Strings.Instagram.madeWord
            } else if copy.out != f.cut?.out {
                more = Strings.Instagram.madeAt(copyShape(copy.out))
            } else {
                more = Strings.Instagram.madeBefore
            }
        } else if f.his {
            more = Strings.Instagram.yourCut
        }
        return [what, more].compactMap { $0 }.joined(separator: " · ")
    }

    /// The tile's VoiceOver value: only the parts that are true.
    @MainActor static func spoken(_ f: InstagramFrame, mark: InstagramMark?, planning: Bool) -> String {
        var parts: [String] = []
        if f.state == .unplanned {
            parts.append(Strings.Instagram.spokenWorking)
        } else if f.state == .stale {
            parts.append(Strings.Instagram.exportedAgain)
        } else if let cut = f.cut, let size = f.frame {
            let kept = Int(((cut.kept ?? InstagramWindow.kept(cut.rect, of: size)) * 100).rounded())
            parts.append(f.isWhole ? Strings.Instagram.spokenWhole(out: cut.out, kept: kept)
                                   : Strings.Instagram.spokenCut(cut.shape, out: cut.out, kept: kept))
            if f.his { parts.append(Strings.Instagram.yourCut) }
            if f.gridMiss { parts.append(Strings.Instagram.spokenGrid) }
            if f.copy_current { parts.append(Strings.Instagram.spokenMade) }
        }
        switch mark {
        case .include?: parts.append(Strings.Instagram.spokenIncluded)
        case .leaveOut?: parts.append(Strings.Instagram.spokenLeftOut)
        case nil: break
        }
        return parts.joined(separator: "; ")
    }
}
