import Foundation
import CoreGraphics

/// Zoom and pan, in frame units rather than screen units (DESIGN.md §2.5.7).
///
/// **There is no modal loupe.** The viewer is the viewer, so the whole class of
/// bugs the old dialog carried goes with it — a wrapped button row, keys that
/// mean different things one screen apart.
///
/// The thing this type exists for is the last paragraph of §2.5.7: zoom and pan
/// are held **relative to the aim**, in normalised frame units. Moving to the
/// next frame re-resolves the aim from *that* frame's own face and re-applies
/// the same relative offset, so if he panned to the hands it stays on the hands,
/// and through a thirty-frame burst the eyes stay in the same place on the
/// screen. Nothing here knows what a view looks like; everything is a rectangle
/// of the photograph.
public struct ZoomModel: Equatable, Sendable {

    /// 100 % is one image pixel on one device pixel, worked out from the
    /// frame's real `dw`/`dh` and the screen's `backingScaleFactor` — so it is
    /// true on Retina and on a 27".
    public static let minimumFactor: Double = 0.10
    public static let maximumFactor: Double = 4.00
    /// A pinch that comes within this of a detent snaps to it and taps a
    /// `.alignment` haptic.
    public static let detentTolerance: Double = 0.03

    public enum State: Equatable, Sendable {
        case fit
        /// A ratio of native pixels: 1.0 is 100 %.
        case factor(Double)
    }

    public var state: State = .fit
    /// The pan, in normalised frame units, added to the aim point. Kept across
    /// frames; it is what "it stays on the hands" means.
    public var pan: CGVector = .zero

    public init(state: State = .fit, pan: CGVector = .zero) {
        self.state = state
        self.pan = pan
    }

    public var isFit: Bool { state == .fit }

    // MARK: - the factors

    /// The factor at which the whole frame fits the viewport.
    public static func fitFactor(framePixels: CGSize, viewport: CGSize, scale: CGFloat) -> Double {
        guard framePixels.width > 0, framePixels.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let w = Double(viewport.width * scale) / Double(framePixels.width)
        let h = Double(viewport.height * scale) / Double(framePixels.height)
        return min(w, h)
    }

    /// The factor this state means, for a frame in a viewport.
    public func factor(framePixels: CGSize, viewport: CGSize, scale: CGFloat) -> Double {
        switch state {
        case .fit: return Self.fitFactor(framePixels: framePixels, viewport: viewport, scale: scale)
        case .factor(let f): return f
        }
    }

    /// What the control bar prints: `1:1`, or a percentage.
    public func percent(framePixels: CGSize, viewport: CGSize, scale: CGFloat) -> Int {
        Int((factor(framePixels: framePixels, viewport: viewport, scale: scale) * 100).rounded())
    }

    // MARK: - moving between the two detents

    /// Z, ⌘0, smart zoom, double-click and force click all land here.
    public mutating func goToOneToOne() { state = .factor(1) }

    /// ⌘9, and a pinch that comes back past fit.
    public mutating func goToFit() {
        state = .fit
        pan = .zero
    }

    /// Fit ⇄ 100 %, for the double-click and the two-finger double-tap.
    public mutating func toggle(framePixels: CGSize, viewport: CGSize, scale: CGFloat) {
        let f = factor(framePixels: framePixels, viewport: viewport, scale: scale)
        if isFit || f < 1 { goToOneToOne() } else { goToFit() }
    }

    /// A pinch: continuous, anchored, with detents at Fit and 100 %.
    /// Returns whether it snapped, which is where the haptic is tapped.
    @discardableResult
    public mutating func magnify(by delta: Double, framePixels: CGSize, viewport: CGSize,
                                 scale: CGFloat) -> Bool {
        let fit = Self.fitFactor(framePixels: framePixels, viewport: viewport, scale: scale)
        let current = factor(framePixels: framePixels, viewport: viewport, scale: scale)
        var next = current * (1 + delta)
        next = min(Self.maximumFactor, max(Self.minimumFactor, next))

        for detent in [fit, 1.0] where abs(next - detent) / max(detent, 0.0001) < Self.detentTolerance {
            if detent == fit { goToFit() } else { state = .factor(1) }
            return true
        }
        // Coming back past fit is fit, not a number a hair under it.
        if next <= fit { goToFit(); return true }
        state = .factor(next)
        return false
    }

    /// ⌘+ / ⌘−, in the same steps as Preview.
    public mutating func step(_ direction: Int, framePixels: CGSize, viewport: CGSize, scale: CGFloat) {
        magnify(by: direction > 0 ? 0.25 : -0.2, framePixels: framePixels, viewport: viewport, scale: scale)
    }

    // MARK: - pan

    /// ⇧-arrow, a two-finger scroll, a drag. `by` is in points on screen.
    ///
    /// It stops at the picture's own edge. This only ever **added** before,
    /// and the clamp lived in `visibleRect`, which bounds the derived centre
    /// for drawing and writes nothing back — so a scroll that ran into the
    /// left edge kept growing `pan.dx` for as long as his fingers moved, and
    /// scrolling the other way spent that invisible surplus before a single
    /// pixel moved. The picture stuck, then jumped. And because the pan is
    /// deliberately carried to the next frame, the dead zone followed him
    /// through the burst.
    public mutating func pan(by points: CGVector, aim: Aim.Point, framePixels: CGSize,
                             viewport: CGSize, factor: Double, scale: CGFloat) {
        guard framePixels.width > 0, framePixels.height > 0, factor > 0 else { return }
        pan.dx -= Double(points.dx * scale) / (Double(framePixels.width) * factor)
        pan.dy -= Double(points.dy * scale) / (Double(framePixels.height) * factor)
        clampPan(aim: aim, framePixels: framePixels, viewport: viewport, scale: scale)
    }

    /// The wall `visibleRect` draws behind, written back into the pan itself,
    /// so what is stored and what is shown are the same thing.
    public mutating func clampPan(aim: Aim.Point, framePixels: CGSize, viewport: CGSize,
                                  scale: CGFloat) {
        let box = window(framePixels: framePixels, viewport: viewport, scale: scale)
        guard box.w > 0, box.h > 0 else { return }
        let lift = (0.5 - Double(aim.verticalPlacement)) * box.h
        var cx = Double(aim.point.x) + pan.dx
        var cy = Double(aim.point.y) + pan.dy + lift
        cx = box.w >= 1 ? 0.5 : min(1 - box.w / 2, max(box.w / 2, cx))
        cy = box.h >= 1 ? 0.5 : min(1 - box.h / 2, max(box.h / 2, cy))
        pan = CGVector(dx: cx - Double(aim.point.x), dy: cy - lift - Double(aim.point.y))
    }

    /// What share of the frame the viewport covers, on each axis.
    private func window(framePixels: CGSize, viewport: CGSize, scale: CGFloat) -> (w: Double, h: Double) {
        let f = factor(framePixels: framePixels, viewport: viewport, scale: scale)
        guard framePixels.width > 0, framePixels.height > 0, f > 0 else { return (0, 0) }
        return (min(1, Double(viewport.width * scale) / (Double(framePixels.width) * f)),
                min(1, Double(viewport.height * scale) / (Double(framePixels.height) * f)))
    }

    /// Keep one point of the photograph under one place in the viewport while
    /// the zoom changes — which is what "anchored under the fingers" in
    /// §2.5.8 means, and what a pinch was not doing: `magnify(with:)` passed
    /// only the delta and never touched the pan, so the picture slid away
    /// from his fingers as he zoomed. `spot` is where in the viewport that
    /// point is, 0…1 from the top-left.
    public mutating func anchor(_ point: CGPoint, at spot: CGPoint, aim: Aim.Point,
                                framePixels: CGSize, viewport: CGSize, scale: CGFloat) {
        let box = window(framePixels: framePixels, viewport: viewport, scale: scale)
        guard box.w > 0, box.h > 0 else { return }
        let lift = (0.5 - Double(aim.verticalPlacement)) * box.h
        let cx = Double(point.x) + box.w * (0.5 - Double(spot.x))
        let cy = Double(point.y) + box.h * (0.5 - Double(spot.y))
        pan = CGVector(dx: cx - Double(aim.point.x), dy: cy - lift - Double(aim.point.y))
        clampPan(aim: aim, framePixels: framePixels, viewport: viewport, scale: scale)
    }

    // MARK: - what is actually on screen

    /// The rectangle of the photograph the viewport shows, in normalised frame
    /// units. Clamped so the picture can never be panned off its own edge, and
    /// centred on the axis where the whole frame already fits.
    public func visibleRect(aim: Aim.Point, framePixels: CGSize, viewport: CGSize,
                            scale: CGFloat) -> CGRect {
        let f = factor(framePixels: framePixels, viewport: viewport, scale: scale)
        guard framePixels.width > 0, framePixels.height > 0, f > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        // The same bound `clampPan` writes back, kept here because this is
        // also asked about a pan that has not been through it — ⌘+ and ⌘−
        // change the factor without moving the pan.
        let w = min(1, Double(viewport.width * scale) / (Double(framePixels.width) * f))
        let h = min(1, Double(viewport.height * scale) / (Double(framePixels.height) * f))

        // The aim sits at 0.38 of the viewport's height when it came from a
        // face, because he is checking eyes; centred otherwise.
        let place = Double(aim.verticalPlacement)
        var cx = Double(aim.point.x) + pan.dx
        var cy = Double(aim.point.y) + pan.dy + (0.5 - place) * h

        if w >= 1 { cx = 0.5 } else { cx = min(1 - w / 2, max(w / 2, cx)) }
        if h >= 1 { cy = 0.5 } else { cy = min(1 - h / 2, max(h / 2, cy)) }
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// The pan that would put `point` where the visible rect's centre is now —
    /// how a click, a force click or a pinch anchors where he asked.
    public mutating func anchor(on point: CGPoint, aim: Aim.Point) {
        pan = CGVector(dx: Double(point.x - aim.point.x), dy: Double(point.y - aim.point.y))
    }

    // MARK: - carrying it to the next frame

    /// Moving frames keeps the factor and the relative pan, and the caller
    /// re-resolves the aim from the new frame's own face. A frame with nothing
    /// to aim at is handed the previous absolute position as `held`, so the
    /// picture does not jump to centre in the middle of a burst.
    public func heldPosition(aim: Aim.Point) -> CGPoint {
        CGPoint(x: min(1, max(0, Double(aim.point.x) + pan.dx)),
                y: min(1, max(0, Double(aim.point.y) + pan.dy)))
    }

    /// The same view of the next frame: the factor and the offset survive, and
    /// the aim is resolved again from that frame.
    public func carriedForward() -> ZoomModel { self }
}
