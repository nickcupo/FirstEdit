import AppKit
import SwiftUI

/// One thumbnail in the filmstrip, and the marks on it.
///
/// The rule this view exists to keep: **his mark and the machine's never share
/// a shape, a corner or a colour** (§2.5.9, principle 4).
///
/// * His verdict is **filled**, bottom-left: a green check or a red cross.
/// * Suggestions have a purple star and a word, top-right. A dotted circle
///   means set aside, an amber triangle a fault. His green check stays distinct.
/// * **Agreed** is its own third state — *hollow*, never filled, because a
///   frame he left standing is not a press he made — and it is the cull's
///   call standing: a hollow green check where the cull put the frame
///   forward, a hollow red cross where it set it aside.
///
/// And nothing is ever hidden. A frame with a named fault is drawn at 50 %
/// with a two-word caption under it; it is still *there*.
@MainActor
final class FilmstripItemView: NSView {

    struct Marks: Equatable {
        var his: VerdictValue.His = .unmarked
        var agreed = false
        var cullRating = 0
        var fault: String?
        var faultCaption: String?
        var isCurrent = false
        var inStack = false
        var isStackTop = false
        /// Where this frame sits in its run, so the 2 pt bracket over the run
        /// is drawn by its own members and cannot be lost to recycling.
        var stackStart = false
        var stackEnd = false
        var stackCount = 0
        var selectedForCompare = false
        var number = ""
        /// Settings ▸ Choosing ▸ "Show the cull's marks in the filmstrip".
        /// Off, the top-right mark is not drawn - and the strip gives no
        /// fault, so no half strength and no two words either.
        var showCull = true
        var showsSuggestion: Bool {
            showCull && fault == nil && cullRating >= VerdictValue.inThreshold && his == .unmarked
        }
    }

    /// Set again for every visible thumbnail on every press; only a
    /// thumbnail whose marks, picture or contrast actually changed is drawn
    /// again. Every one of them used to be, symbols and picture and all, on
    /// every arrow and every K — two of them change.
    var marks = Marks() {
        didSet {
            guard marks != oldValue else { return }
            redraw()
            setAccessibilitySelected(marks.isCurrent)
        }
    }
    var image: CGImage? { didSet { if image !== oldValue { redraw() } } }
    /// The frame this view shows now. A recycled cell is given another, and a
    /// picture still on its way for the one before is not put on it.
    var stem: String?
    var increaseContrast = false { didSet { if increaseContrast != oldValue { redraw() } } }

    /// How many times this thumbnail has asked to be drawn again, counted so
    /// a test can see it ask only when something changed.
    private(set) var redrawsAsked = 0

    private func redraw() {
        redrawsAsked += 1
        needsDisplay = true
    }

    /// A press on this thumbnail — how many clicks, and which keys were held —
    /// handed to the strip, which decides what it means (§2.5.9). Set again
    /// every time a recycled cell is given a frame.
    var onPress: ((_ clicks: Int, _ modifiers: NSEvent.ModifierFlags) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A button VoiceOver can press, one per frame. The label is the
        // frame's own sentence, set by the strip with the marks.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    /// Never the keyboard's. A click here moves the photograph, and the
    /// photograph keeps K, D, N, the arrows and Space.
    override var acceptsFirstResponder: Bool { false }

    /// The press is taken here, not by the collection view's selection: that
    /// made the strip the keyboard's the moment it was clicked, and a
    /// thumbnail it still held selected ignored the next click on it.
    override func mouseDown(with e: NSEvent) {
        onPress?(e.clickCount, e.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress(1, [])
        return true
    }

    static let thumb = Tokens.Metric.filmstripThumb            // 90 × 60
    static let caption: CGFloat = 14
    /// The lane above the thumbnail that the stack bracket lives in. The 96 pt
    /// of §2.5.9 is 12 bracket + 60 thumb + 4 + 14 caption + 6 of padding.
    static let bracket: CGFloat = 12
    /// The item's full height. A **ceiling**: `Filmstrip.fitItemToTheBand`
    /// hands the flow layout less when the band is shorter than 91 pt.
    static var itemHeight: CGFloat { bracket + thumb.height + 4 + caption }

    /// Where the picture goes in an item this tall. The bracket lane above and
    /// the caption lane below keep their own 12 and 14 points whatever the
    /// band does, and **the picture gives up the difference** — a frame's run
    /// and a frame's number are writing, and §2.5.9 is that nothing in the
    /// strip is hidden; four points off a 60 pt picture is not hiding it.
    ///
    /// This was `height: thumb.height` from a fixed 12 pt down, which does not
    /// shrink at all: a shorter item cut the caption off the bottom, and then
    /// the bottom of the picture, which is the opposite of what
    /// `fitItemToTheBand` says it does.
    static func thumbRect(in bounds: CGSize) -> CGRect {
        let left = bounds.height - bracket - 4 - caption
        return CGRect(x: 0, y: bracket, width: thumb.width,
                      height: max(0, min(thumb.height, left)))
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let thumbRect = Self.thumbRect(in: bounds.size)
        drawStackBracket(thumbRect)

        // Where the picture actually lands: the whole frame, fitted inside the
        // cell. For a 3:2 frame either way up that is the cell exactly.
        let pictureRect = image.map { fitted(image: $0, in: thumbRect) } ?? thumbRect

        // The frame itself. A named fault is drawn at half strength — it is not
        // hidden, it is quieter.
        let alpha: CGFloat = marks.fault != nil ? 0.5 : (marks.inStack && !marks.isStackTop && !marks.showsSuggestion ? 0.7 : 1)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        // The grey is a placeholder for a picture still on its way, and the
        // cell's own surface is what shows either side of one that is not
        // 3:2. It filled the whole cell under every frame, so a portrait
        // burst was a row of 40 pt pictures in grey 90 pt boxes that read as
        // frames that had not loaded.
        if image == nil {
            NSColor.black.withAlphaComponent(0.25).setFill()
            ctx.fill(thumbRect)
        }
        if let image {
            ctx.saveGState()
            // Nothing of the photograph leaves its cell, whatever shape the
            // frame is. Aspect-fill put a 4024 × 6024 frame into the 90 × 60
            // cell at 90 × 135 — 37 pt over the top into the stack-bracket
            // lane and 37 pt under the bottom over its own frame number — and
            // there was no clip to stop it.
            ctx.clip(to: thumbRect)
            // Flipped about the thumbnail's own box, not the view's: this view
            // is flipped and a Core Graphics image is not, and getting the
            // pivot wrong slides every frame up into the bracket lane.
            ctx.translateBy(x: 0, y: thumbRect.minY + thumbRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: pictureRect)
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // The current frame: a 3 pt accent ring, thicker under Increase
        // Contrast. It goes round the **picture**, because what it means is
        // "this frame", and round a 90 pt cell holding a 40 pt picture it
        // would be pointing at the background either side as well.
        if marks.isCurrent {
            NSColor.controlAccentColor.setStroke()
            let w = increaseContrast ? Tokens.Metric.currentRing + 1 : Tokens.Metric.currentRing
            let p = NSBezierPath(rect: pictureRect.insetBy(dx: w / 2, dy: w / 2))
            p.lineWidth = w
            p.stroke()
        } else if marks.selectedForCompare {
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let p = NSBezierPath(rect: pictureRect.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.setLineDash([3, 2], count: 2, phase: 0)
            p.stroke()
        }

        // The marks, 14 pt — 16 under Increase Contrast — 3 pt in from the
        // picture's corners.
        let side: CGFloat = increaseContrast ? 16 : 14

        // His, filled, bottom-left of the picture. Under Increase Contrast
        // they are bolder and larger, on a white disc so the check or cross
        // cut out of them is white rather than whatever the frame is there.
        let hisPoint = CGPoint(x: pictureRect.minX + 3, y: pictureRect.maxY - 3 - side)
        let hisBacking: NSColor? = increaseContrast ? .white : nil
        switch marks.his {
        case .kept: drawMark(Symbols.hisKeep, at: hisPoint, side: side, colour: .systemGreen,
                             filled: true, backing: hisBacking)
        case .out: drawMark(Symbols.hisDrop, at: hisPoint, side: side, colour: .systemRed,
                            filled: true, backing: hisBacking)
        case .unmarked:
            if marks.agreed {
                // Agreed: hollow, never the filled mark, and the call he let
                // stand. It was a green check on every frame he left alone,
                // so a finished burst looked as if he had kept the lot —
                // the frames the cull set aside included, which stay out.
                // A hollow ring is a thin line on a busy frame, so it sits on
                // a dark disc.
                let keep = Self.agreedIsKeep(marks)
                drawMark(keep ? Symbols.agreed : Symbols.agreedOut, at: hisPoint, side: side,
                         colour: keep ? .systemGreen : .systemRed, filled: false, backing: markDisc)
            }
        }

        // A word and star replace the easily missed hollow circle. The banner
        // spans the cell, so portrait suggestions are just as legible. Personal
        // verdicts take precedence; clearing one restores the suggestion.
        let cullPoint = CGPoint(x: pictureRect.maxX - 3 - side, y: pictureRect.minY + 3)
        if !marks.showCull {
            // He asked not to see them.
        } else if marks.showsSuggestion {
            drawSuggestion(in: thumbRect)
        } else if marks.fault != nil {
            drawMark(Symbols.cullFault, at: cullPoint, side: side, colour: .systemOrange,
                     filled: false, backing: markDisc)
        } else if marks.cullRating >= VerdictValue.inThreshold {
            drawMark(Symbols.cullForward, at: cullPoint, side: side, colour: .white,
                     filled: false, backing: markDisc)
        } else {
            drawMark(Symbols.cullAside, at: cullPoint, side: side, colour: .white,
                     filled: false, backing: markDisc)
        }

        // The caption: the frame number, or the fault in two words. 11 pt in
        // `captionColour`, the current frame's in accent and semibold. It was
        // 10 pt in tertiary grey, 1.8:1 on the light bar and 1.6:1 on the dark
        // one: the numbers he copies into PhotoLab, and he had to lean in.
        let text = marks.faultCaption ?? marks.number
        let colour: NSColor = marks.isCurrent && marks.faultCaption == nil
            ? .controlAccentColor : Self.captionColour(increaseContrast: increaseContrast)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: CGRect(x: 0, y: thumbRect.maxY + 4, width: thumbRect.width, height: Self.caption),
            withAttributes: [
                .font: Self.captionFont(current: marks.isCurrent),
                .foregroundColor: colour,
                .paragraphStyle: style,
            ])
    }

    private func drawSuggestion(in rect: CGRect) {
        let banner = CGRect(x: rect.minX + 1, y: rect.minY + 1,
                            width: rect.width - 2, height: 17)
        Tokens.Palette.suggestionNS.setFill()
        NSBezierPath(roundedRect: banner, xRadius: 3, yRadius: 3).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        ("★ " + Strings.LightTable.suggested as NSString).draw(
            in: banner.insetBy(dx: 2, dy: 1),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                             .foregroundColor: NSColor.white, .paragraphStyle: style])
    }

    /// The disc under the marks that are outlines: dark enough that a thin
    /// ring reads on a white shirt or a black wall, opaque under Increase
    /// Contrast.
    private var markDisc: NSColor {
        NSColor.black.withAlphaComponent(increaseContrast ? 0.85 : 0.5)
    }

    /// The frame numbers: the label colour at 62 %, which is about 6:1 on the
    /// bar in either appearance, and the label colour itself under Increase
    /// Contrast.
    static func captionColour(increaseContrast: Bool) -> NSColor {
        increaseContrast ? .labelColor : NSColor.labelColor.withAlphaComponent(0.62)
    }

    static func captionFont(current: Bool) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 11, weight: current ? .semibold : .regular)
    }

    /// What leaving a frame standing in a burst he has been through comes to:
    /// the cull's call, which is a keeper where the cull put it forward and
    /// out where it set it aside — the engine's own rule for the frames he
    /// kept.
    static func agreedIsKeep(_ m: Marks) -> Bool {
        m.cullRating >= VerdictValue.inThreshold
    }

    /// A 2 pt bracket over the run, carried across the gaps between its
    /// members so it reads as one bar, with the count at its start. No
    /// strike-through, nothing hidden, and the word the old detector was named
    /// after appears nowhere (DUP-5).
    ///
    /// Each member carries the bar across the gap **after** it and none
    /// before, so no gap is painted twice: the colour is translucent, and two
    /// members both reaching into the same 6 pt left a darker blot between
    /// every pair of frames.
    private func drawStackBracket(_ thumbRect: CGRect) {
        guard marks.inStack else { return }
        let width = increaseContrast ? 3.0 : 2.0
        var from: CGFloat = 0
        let to = marks.stackEnd ? thumbRect.width : thumbRect.width + Tokens.Metric.filmstripGap
        if marks.stackStart {
            let text = Strings.LightTable.similar(marks.stackCount) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.stackLabelFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            text.draw(at: CGPoint(x: 1, y: 0), withAttributes: attributes)
            from = text.size(withAttributes: attributes).width + 5
        }
        // The bar runs level with the middle of the count's lower-case
        // letters, so the run reads as one bracket with its count at the start.
        let font = Self.stackLabelFont
        let y = (font.ascender - font.xHeight / 2 - width / 2).rounded()
        NSColor.secondaryLabelColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(rect: CGRect(x: from, y: y, width: max(0, to - from), height: width)).fill()
    }

    /// "4 similar", at the start of the bracket. 10 pt, whose line is the
    /// 12 pt lane exactly, drawn from the lane's top: 9 pt was hard to read,
    /// and neither size survived the item being laid out above the band.
    static let stackLabelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    /// The frame **whole**, centred in its cell (§2.5.9).
    ///
    /// This was aspect-fill, which is right for a cover and wrong for a strip
    /// he is culling from: a 3:2 cell centre-crops 56 % of a portrait frame's
    /// height away, so the one thing the strip is for — seeing what is in each
    /// frame of the burst — was the thing it lost. A 3:2 frame either way up
    /// still fills the cell exactly, which is why this only ever showed on the
    /// sixteen portrait frames of his own shoot.
    static func fitted(image: CGImage, in rect: CGRect) -> CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return rect }
        let scale = min(rect.width / iw, rect.height / ih)
        let w = (iw * scale).rounded(), h = (ih * scale).rounded()
        return CGRect(x: (rect.midX - w / 2).rounded(), y: (rect.midY - h / 2).rounded(),
                      width: w, height: h)
    }

    private func fitted(image: CGImage, in rect: CGRect) -> CGRect {
        Self.fitted(image: image, in: rect)
    }

    /// One mark, `side` points square from `corner`, on a disc of `backing`
    /// when it has one. Without one it takes a shadow, so a mark on a bright
    /// frame is still legible; the shape and the word carry the meaning, the
    /// colour only helps. The symbol keeps its own proportions inside the
    /// square — the fault's triangle is wider than it is tall.
    private func drawMark(_ name: String, at corner: CGPoint, side: CGFloat, colour: NSColor,
                          filled: Bool, backing: NSColor?) {
        let weight: NSFont.Weight = increaseContrast ? .bold : (filled ? .semibold : .medium)
        let config = NSImage.SymbolConfiguration(pointSize: side - 1, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let square = CGRect(origin: corner, size: CGSize(width: side, height: side))
        NSGraphicsContext.current?.saveGraphicsState()
        if let backing {
            backing.setFill()
            NSBezierPath(ovalIn: square.insetBy(dx: -1.5, dy: -1.5)).fill()
        } else {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            shadow.set()
        }
        image.isTemplate = true
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            colour.set()
            rect.fill(using: .sourceOver)
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        let scale = min(side / max(1, image.size.width), side / max(1, image.size.height))
        let w = image.size.width * scale, h = image.size.height * scale
        tinted.draw(in: CGRect(x: square.midX - w / 2, y: square.midY - h / 2, width: w, height: h))
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// The collection view's item: the thumbnail view and nothing else.
@MainActor
final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("frame")
    let thumb = FilmstripItemView()

    override func loadView() {
        view = thumb
    }

}
