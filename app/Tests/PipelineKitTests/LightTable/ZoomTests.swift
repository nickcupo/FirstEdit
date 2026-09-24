import Foundation
import Testing
import CoreGraphics
@testable import PipelineKit

/// §2.5.7: what 100 % means, where it points, and why it stays there.
@Suite("Zoom and aim")
struct ZoomTests {

    /// A 24 MP a6500 frame, and the default viewer box on a Retina screen.
    static let frame = CGSize(width: 6024, height: 4024)
    static let viewport = CGSize(width: 1084, height: 542)
    static let scale: CGFloat = 2

    @Test("100 % is one image pixel on one device pixel, on Retina and on a 27-inch")
    func oneToOne() {
        var z = ZoomModel()
        z.goToOneToOne()
        #expect(z.percent(framePixels: Self.frame, viewport: Self.viewport, scale: 2) == 100)
        #expect(z.percent(framePixels: Self.frame, viewport: Self.viewport, scale: 1) == 100)
        // At 1:1 the viewport shows exactly its own device pixels of the frame.
        let r = z.visibleRect(aim: Aim.centre, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        #expect(abs(r.width - (1084 * 2) / 6024) < 0.001)
        #expect(abs(r.height - (542 * 2) / 4024) < 0.001)
    }

    @Test("Fit shows the whole frame and nothing more")
    func fit() {
        let z = ZoomModel()
        #expect(z.isFit)
        let r = z.visibleRect(aim: Aim.centre, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        // 3:2 in a 2:1 box is height-bound: the whole height, less than the
        // whole width, and never past either edge.
        #expect(abs(r.height - 1) < 0.001)
        #expect(r.width <= 1.001)
        #expect(r.minX >= -0.001 && r.maxX <= 1.001)
    }

    @Test("zoom is 10 % to 400 % and a pinch cannot leave it")
    func range() {
        var z = ZoomModel()
        for _ in 0..<60 { _ = z.magnify(by: 0.5, framePixels: Self.frame, viewport: Self.viewport, scale: 2) }
        #expect(z.factor(framePixels: Self.frame, viewport: Self.viewport, scale: 2) <= ZoomModel.maximumFactor)
        for _ in 0..<60 { _ = z.magnify(by: -0.3, framePixels: Self.frame, viewport: Self.viewport, scale: 2) }
        #expect(z.isFit, "coming back past fit is fit, not a number a hair under it")
    }

    @Test("there are detents at Fit and at 100 %, and each one reports itself for the haptic")
    func detents() {
        var z = ZoomModel()
        z.state = .factor(0.97)
        let snapped = z.magnify(by: 0.02, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        #expect(snapped)
        #expect(z.factor(framePixels: Self.frame, viewport: Self.viewport, scale: 2) == 1)

        let fit = ZoomModel.fitFactor(framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        z.state = .factor(fit * 1.01)
        let backToFit = z.magnify(by: 0.005, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        #expect(backToFit)
        #expect(z.isFit)
    }

    // MARK: - aim

    @Test("the aim is the face, then the subject, then the centre — and it says which")
    func aim() throws {
        func row(_ fields: [String: JSONValue]) -> Row {
            var f = fields
            f["file"] = .string("x.ARW"); f["stem"] = .string("x"); f["rating"] = .string("3")
            return try! Row(fields: Fields(f))
        }
        let face = Aim.resolve(row(["face_x": .number(0.42), "face_y": .number(0.31)]))
        #expect(face.source == .face)
        #expect(face.point == CGPoint(x: 0.42, y: 0.31))
        #expect(face.label == "on the face")
        // He is checking eyes, so a face sits at 0.38 of the viewport's height.
        #expect(face.verticalPlacement == 0.38)

        let subject = Aim.resolve(row(["subject": .array([.number(0.1), .number(0.2),
                                                          .number(0.4), .number(0.4)])]))
        #expect(subject.source == .subject)
        #expect(abs(subject.point.x - 0.3) < 0.0001 && abs(subject.point.y - 0.4) < 0.0001)
        #expect(subject.label == "no face found, on the subject")
        #expect(subject.verticalPlacement == 0.5)

        let centre = Aim.resolve(row([:]))
        #expect(centre.source == .centre)
        #expect(centre.point == CGPoint(x: 0.5, y: 0.5))
        #expect(centre.label == "centered")

        // A frame with nothing to aim at holds the previous place rather than
        // jumping to the middle of the picture halfway through a burst.
        let held = Aim.resolve(row([:]), held: CGPoint(x: 0.7, y: 0.2))
        #expect(held.source == .held)
        #expect(held.point == CGPoint(x: 0.7, y: 0.2))
        #expect(held.label == "held in place")

        #expect(Aim.zoomLabel(percent: 100, aim: face) == "1:1 · on the face")
        #expect(Aim.zoomLabel(percent: 250, aim: centre) == "250% · centered")
    }

    @Test("the pan is kept relative to the aim, so the eyes stay in the same place")
    func panIsRelative() {
        var z = ZoomModel()
        z.goToOneToOne()
        // He pans off the face onto the hands.
        z.pan(by: CGVector(dx: -100, dy: -60), aim: Aim.centre, framePixels: Self.frame,
              viewport: Self.viewport, factor: 1, scale: 2)
        let offset = z.pan

        // The next frame's face is somewhere else. The same relative offset is
        // applied to that frame's own aim, so what he panned to is still there.
        let first = Aim.Point(point: CGPoint(x: 0.42, y: 0.31), source: .face)
        let second = Aim.Point(point: CGPoint(x: 0.52, y: 0.29), source: .face)
        let a = z.visibleRect(aim: first, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        let b = z.visibleRect(aim: second, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        #expect(z.pan == offset, "moving frames does not change the offset")
        #expect(abs((b.midX - second.point.x) - (a.midX - first.point.x)) < 0.0001)
        #expect(abs((b.midY - second.point.y) - (a.midY - first.point.y)) < 0.0001)
    }

    @Test("the picture can never be panned off its own edge")
    func clamped() {
        var z = ZoomModel()
        z.goToOneToOne()
        for _ in 0..<200 {
            z.pan(by: CGVector(dx: -500, dy: -500), aim: Aim.centre, framePixels: Self.frame,
                  viewport: Self.viewport, factor: 1, scale: 2)
        }
        let r = z.visibleRect(aim: Aim.centre, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        #expect(r.minX >= -0.0001 && r.maxX <= 1.0001)
        #expect(r.minY >= -0.0001 && r.maxY <= 1.0001)
    }

    // MARK: - the tile

    @Test("the 1:1 tile is 1.6 × the viewport and is cut again only near its edge")
    func tiles() {
        let viewportPixels = CGSize(width: 1084 * 2, height: 542 * 2)
        let box = TileFetcher.tile(aim: CGPoint(x: 0.5, y: 0.5), viewportPixels: viewportPixels)
        #expect(box.px == min(TileFetcher.maximumTilePixels,
                              Int((Double(viewportPixels.width) * 1.6).rounded(.up))))
        let cover = TileFetcher.coverage(of: box, framePixels: ZoomTests.frame)
        var z = ZoomModel()
        z.goToOneToOne()
        let here = z.visibleRect(aim: Aim.centre, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        #expect(!TileFetcher.needsNewTile(viewport: here, tile: cover), "a small pan is local work")

        z.pan(by: CGVector(dx: -900, dy: 0), aim: Aim.centre, framePixels: Self.frame,
              viewport: Self.viewport, factor: 1, scale: 2)
        let far = z.visibleRect(aim: Aim.centre, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        #expect(TileFetcher.needsNewTile(viewport: far, tile: cover), "a pan to the edge asks for a new cut")
    }
}

@Suite("A scroll means the same thing whatever sent it")
struct ScrollInputTests {
    @Test("a wheel's lines and a trackpad's points end up in the same units")
    func unitsAgree() {
        // A trackpad flick: precise, already points.
        let pad = ScrollInput.points(precise: true, deltaX: 0, deltaY: 120, inverted: false)
        #expect(pad.dy == 120)
        // One notch of a wheel: a single line, which is 16 pt of movement, not 1.
        let wheel = ScrollInput.points(precise: false, deltaX: 0, deltaY: 1, inverted: false)
        #expect(wheel.dy == ScrollInput.lineHeight)
        // Natural scrolling turned off inverts the device's own report.
        #expect(ScrollInput.points(precise: true, deltaX: 0, deltaY: 10, inverted: true).dy == -10)
    }

    @Test("one notch is one step, and a slow scroll still arrives")
    func stepsAreWholeFrames() {
        var s = ScrollInput.Stepper()
        var t = 100.0
        func wheel(_ points: CGFloat) -> Int { t += 0.05; return s.steps(points, precise: false, at: t) }
        #expect(wheel(ScrollInput.lineHeight) == 1)          // a notch
        #expect(wheel(-ScrollInput.lineHeight) == -1)        // the other way
        #expect(wheel(4) == 0)                               // a nudge is not a step
        #expect(wheel(4) == 0)
        #expect(wheel(8) == 1)                               // but four nudges are
        s.reset()
        #expect(wheel(8) == 0)                               // a new gesture starts clean
    }

    /// A wheel mouse has `phase == .none` for the whole of its life, so the
    /// old `reset()` on `phase == .began` never reached it and up to a
    /// threshold of carry survived from the last scroll.
    @Test("a wheel mouse forgets its carry after a gap, without a phase to tell it to")
    func aGapIsANewGesture() {
        var s = ScrollInput.Stepper()
        #expect(s.steps(12, precise: false, at: 100.0) == 0)       // 12 pt carried
        #expect(s.steps(12, precise: false, at: 100.1) == 1)       // still one gesture
        #expect(s.steps(12, precise: false, at: 200.0) == 0)       // a minute later: clean
        #expect(s.steps(12, precise: false, at: 200.1) == 1)
    }

    @Test("a trackpad flick does not run through a burst, and its surplus is carried not lost")
    func aFlickIsNotFive() {
        var s = ScrollInput.Stepper()
        // A trackpad reports the same movement of his hand in hundreds of
        // points, so it has its own distance: one decisive flick is one step.
        #expect(s.steps(ScrollInput.Stepper.trackpadThreshold, precise: true, at: 1.0) == 1)
        // A long flick is clamped to three, and what is past the clamp stays
        // in the carry rather than being thrown away - so the same movement
        // delivered in one event and in ten moves the same distance.
        var big = ScrollInput.Stepper()
        let far = ScrollInput.Stepper.trackpadThreshold * 6
        #expect(big.steps(far, precise: true, at: 1.0) == 3)
        #expect(big.steps(0, precise: true, at: 1.05) == 3)
        var small = ScrollInput.Stepper()
        var moved = 0
        var t = 1.0
        for _ in 0..<6 {
            t += 0.05
            moved += small.steps(ScrollInput.Stepper.trackpadThreshold, precise: true, at: t)
        }
        #expect(moved == 6)
    }

    @Test("changing device starts a new gesture rather than inheriting the other's carry")
    func deviceChangeResets() {
        var s = ScrollInput.Stepper()
        #expect(s.steps(100, precise: true, at: 1.0) == 0)     // most of a trackpad flick
        #expect(s.steps(ScrollInput.lineHeight, precise: false, at: 1.01) == 1)  // one wheel notch, no more
    }
}

/// The two things a pointer does to a zoomed photograph.
@Suite("Pan and pinch under the pointer")
struct PointerZoomTests {
    static let frame = CGSize(width: 6024, height: 4024)
    static let viewport = CGSize(width: 1084, height: 542)

    /// The bug: `pan(by:)` only ever added, and the clamp lived in the derived
    /// rect and was never written back. Scrolling into an edge grew the offset
    /// invisibly, and scrolling back spent that surplus before a single pixel
    /// moved — the picture stuck, then jumped.
    @Test("scrolling into an edge and straight back moves the picture at once")
    func noDeadZone() {
        var z = ZoomModel()
        z.goToOneToOne()
        // Ten hard scrolls into the left edge.
        for _ in 0..<10 {
            z.pan(by: CGVector(dx: 600, dy: 0), aim: Aim.centre, framePixels: Self.frame,
                  viewport: Self.viewport, factor: 1, scale: 2)
        }
        let atTheWall = z.visibleRect(aim: Aim.centre, framePixels: Self.frame,
                                      viewport: Self.viewport, scale: 2)
        #expect(abs(atTheWall.minX) < 0.0001, "it is against the edge")

        // One ordinary scroll the other way has to move it.
        z.pan(by: CGVector(dx: -40, dy: 0), aim: Aim.centre, framePixels: Self.frame,
              viewport: Self.viewport, factor: 1, scale: 2)
        let after = z.visibleRect(aim: Aim.centre, framePixels: Self.frame,
                                  viewport: Self.viewport, scale: 2)
        #expect(after.minX > atTheWall.minX + 0.005,
                "40 pt of scroll off the wall moved \((after.minX - atTheWall.minX) * 6024) px")
    }

    @Test("the dead zone does not follow him to the next frame either")
    func noDeadZoneCarriedForward() {
        var z = ZoomModel()
        z.goToOneToOne()
        for _ in 0..<10 {
            z.pan(by: CGVector(dx: 0, dy: 600), aim: Aim.centre, framePixels: Self.frame,
                  viewport: Self.viewport, factor: 1, scale: 2)
        }
        // Carried to the next frame, whose face is elsewhere.
        let next = Aim.Point(point: CGPoint(x: 0.4, y: 0.6), source: .face)
        let carried = z.carriedForward()
        let r = carried.visibleRect(aim: next, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        #expect(r.minY >= -0.0001 && r.maxY <= 1.0001)
    }

    /// §2.5.8: "continuous zoom 10 %–400 % **anchored under the fingers**".
    /// `magnify(with:)` passed only the delta and never touched the pan, so
    /// the photograph slid away from his fingers as he zoomed.
    @Test("a pinch keeps the same part of the photograph under the pointer")
    func pinchIsAnchored() {
        var z = ZoomModel()
        z.goToOneToOne()
        // A point three quarters across and a third down the viewport, and
        // whatever of the photograph is under it.
        let spot = CGPoint(x: 0.75, y: 0.33)
        let before = z.visibleRect(aim: Aim.centre, framePixels: Self.frame,
                                   viewport: Self.viewport, scale: 2)
        let under = CGPoint(x: before.minX + Double(spot.x) * before.width,
                            y: before.minY + Double(spot.y) * before.height)

        z.magnify(by: 0.6, framePixels: Self.frame, viewport: Self.viewport, scale: 2)
        z.anchor(under, at: spot, aim: Aim.centre, framePixels: Self.frame,
                 viewport: Self.viewport, scale: 2)

        let after = z.visibleRect(aim: Aim.centre, framePixels: Self.frame,
                                  viewport: Self.viewport, scale: 2)
        let nowUnder = CGPoint(x: after.minX + Double(spot.x) * after.width,
                               y: after.minY + Double(spot.y) * after.height)
        #expect(abs(nowUnder.x - under.x) < 0.001, "it slid \((nowUnder.x - under.x) * 6024) px sideways")
        #expect(abs(nowUnder.y - under.y) < 0.001, "it slid \((nowUnder.y - under.y) * 4024) px up or down")
    }
}

/// §2.5.10. A click that wobbles must land on the burst under the pointer.
@Suite("The burst scrubber's index")
struct BurstScrubberIndexTests {
    @Test("the segment under a point, with the 1 pt between them counted")
    func indexAtX() {
        // 155 bursts at the 8 pt minimum: the strip scrolls, and the index is
        // read in the strip's own space rather than the gesture's.
        #expect(BurstScrubber.index(atX: 0, width: 8, count: 155) == 0)
        #expect(BurstScrubber.index(atX: 8, width: 8, count: 155) == 0)
        #expect(BurstScrubber.index(atX: 9, width: 8, count: 155) == 1)
        #expect(BurstScrubber.index(atX: 9 * 40, width: 8, count: 155) == 40)
    }

    @Test("a point past either end is the first or the last burst, never a crash")
    func clamped() {
        #expect(BurstScrubber.index(atX: -50, width: 8, count: 19) == 0)
        #expect(BurstScrubber.index(atX: 100_000, width: 8, count: 19) == 18)
        #expect(BurstScrubber.index(atX: 10, width: 8, count: 0) == 0)
    }
}
