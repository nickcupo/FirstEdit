import AppKit

/// What a scroll event means, in points, whatever device sent it.
///
/// A trackpad and a Magic Mouse send *precise* deltas already measured in
/// points, in a phase (`began`/`changed`/`ended`) with momentum after it. An
/// ordinary wheel mouse sends neither: its `scrollingDelta` counts LINES —
/// about one to three per notch — and its phase is `.none` for the whole of
/// its life.
///
/// Both went straight into the pan, so the same flick of his hand moved the
/// photograph by 900 points on the trackpad and by 3 on the mouse, and in the
/// fitted view — which only acted on `.began`/`.changed` — the mouse wheel did
/// nothing at all. He reported it as the app's sensitivity changing as he used
/// it. One place turns an event into points now, and one place decides when a
/// scroll has gone far enough to count as a step.
public enum ScrollInput {
    /// AppKit's own line height for a wheel notch. NSScrollView uses the same
    /// figure when it converts a line-based wheel into a distance.
    public static let lineHeight: CGFloat = 16

    /// A scroll's meaning in points, direction as the device reports it.
    public static func points(precise: Bool, deltaX: CGFloat, deltaY: CGFloat,
                              inverted: Bool) -> CGVector {
        let scale = precise ? 1 : lineHeight
        let sign: CGFloat = inverted ? -1 : 1
        return CGVector(dx: deltaX * scale * sign, dy: deltaY * scale * sign)
    }

    public static func points(_ e: NSEvent) -> CGVector {
        points(precise: e.hasPreciseScrollingDeltas,
               deltaX: e.scrollingDeltaX, deltaY: e.scrollingDeltaY,
               inverted: e.isDirectionInvertedFromDevice)
    }

    /// Whether this event is a device's own movement rather than the momentum
    /// macOS keeps sending after his fingers have left the trackpad. A frame is
    /// never stepped on momentum: one flick would run through a burst.
    public static func isMomentum(_ e: NSEvent) -> Bool { e.momentumPhase != [] }

    /// Turns a stream of scrolls into whole steps — one frame per notch on a
    /// wheel, one per decisive flick on a trackpad — so the two devices agree
    /// about what a step is.
    public struct Stepper {
        /// A wheel notch is one line, 16 pt, and it must count.
        public static let wheelThreshold: CGFloat = 16
        /// The same movement of his hand on a trackpad is hundreds of points:
        /// a gentle nudge is 40 or 50, so 16 pt made the strip bolt. One
        /// decisive flick is a step.
        public static let trackpadThreshold: CGFloat = 120
        /// A quarter of a second with nothing from the device is a new
        /// gesture. `reset()` used to be called on `phase == .began`, and a
        /// wheel mouse has `phase == .none` for the whole of its life, so it
        /// never got one: up to a threshold of stale carry survived from the
        /// last scroll and could double the first notch of the next.
        public static let gap: TimeInterval = 0.25

        private var carried: CGFloat = 0
        private var lastAt: TimeInterval = -.greatestFiniteMagnitude
        private var lastPrecise: Bool?
        /// The way this gesture last moved: −1, +1, or 0 before it has.
        private var heading: CGFloat = 0
        /// Whether this gesture has already taken a step. The first step of a
        /// gesture is a press of its own; every step after it is the same
        /// gesture still going, as a key still down is (`gestureSteps`).
        public private(set) var steppedThisGesture = false

        public init() {}

        /// The steps a scroll asks for now, as `steps` counts them, and
        /// whether the first of them is **the first of its gesture**.
        ///
        /// A gesture is what one wheel spin or one movement of his fingers
        /// makes: it ends at a quarter-second with nothing from the device,
        /// at a change of device, or where a trackpad says a new one began.
        /// Its first step is a press, as a tap of → is — it may cross into
        /// the next burst and record the one he is leaving. The steps after
        /// it are a key held down: they run through a burst and stop at its
        /// end with one bounce, because recording a burst is a claim about
        /// his work, not about a wheel still turning (§2.5.3, §7.4).
        ///
        /// `oncePerGesture` is the sideways swipe's rule: one frame for one
        /// firm swipe, however far the fingers went, as the swipe the system
        /// tracks gives.
        ///
        /// **A turn the other way starts from nothing.** What is carried
        /// belongs to the direction it was carried in: kept through a
        /// reversal, a fast spin toward him and one notch away stepped three
        /// more frames toward him, and a long swipe left then a quick one
        /// right stepped forward, as a fresh press that could record a
        /// burst. A wheel turned back is a new turn of the wheel, so its
        /// first step is a press; a trackpad says for itself when a new
        /// gesture begins, and fingers that turn back without lifting are
        /// the same gesture still going. Once a swipe has had its one frame,
        /// the rest of it is spent, not saved for the next.
        public mutating func gestureSteps(_ points: CGFloat, precise: Bool, at now: TimeInterval,
                                          began: Bool = false, oncePerGesture: Bool = false,
                                          limit: Int = 3) -> (count: Int, fresh: Bool) {
            let lapsed = lastPrecise != precise || now - lastAt > Self.gap
            if began || lapsed { heading = 0 }
            let turned = points != 0 && heading != 0 && (points < 0) != (heading < 0)
            if began || lapsed || (turned && !precise) { steppedThisGesture = false }
            if began || turned { carried = 0 }
            if points != 0 { heading = points < 0 ? -1 : 1 }
            if oncePerGesture && steppedThisGesture {
                lastPrecise = precise
                lastAt = now
                return (0, false)
            }
            let n = steps(points, precise: precise, at: now, limit: oncePerGesture ? 1 : limit)
            guard n != 0 else { return (0, false) }
            defer { steppedThisGesture = true }
            return (n, !steppedThisGesture)
        }

        public static func threshold(precise: Bool) -> CGFloat {
            precise ? trackpadThreshold : wheelThreshold
        }

        /// How many steps to act on now, at most `limit`, and in which
        /// direction.
        ///
        /// Everything left over is **carried**: both the remainder under the
        /// threshold, so slow scrolling still arrives, and the steps past the
        /// limit, so one large event moves the picture the same distance as
        /// the same movement delivered in small ones. The caller used to take
        /// `min(abs(steps), 3)` and throw the surplus away, which made the
        /// gain depend on how fast he scrolled.
        public mutating func steps(_ points: CGFloat, precise: Bool,
                                   at now: TimeInterval, limit: Int = 3) -> Int {
            if lastPrecise != precise || now - lastAt > Self.gap { carried = 0 }
            lastPrecise = precise
            lastAt = now
            let threshold = Self.threshold(precise: precise)
            carried += points
            guard abs(carried) >= threshold else { return 0 }
            let whole = Int((carried / threshold).rounded(.towardZero))
            let taken = max(-limit, min(limit, whole))
            carried -= CGFloat(taken) * threshold
            return taken
        }

        /// Between gestures: a new flick does not inherit the last one's tail.
        public mutating func reset() {
            carried = 0
            lastAt = -.greatestFiniteMagnitude
            lastPrecise = nil
            heading = 0
            steppedThisGesture = false
        }
    }

    /// What a scroll over the fitted photograph does (DESIGN.md §2.5.8).
    ///
    /// **Frame by frame, as ← and → are.** A wheel notch, or a two-finger
    /// scroll up or down, is the next or the previous frame, on across the
    /// end of a burst into the next — recording the one he leaves exactly as
    /// → does — and back across the start into the one before. It used to
    /// jump to the next frame the cull put forward and stop at the end of the
    /// burst: on his four-frame bursts most notches found nothing ahead and
    /// only shook the picture, which is the likeliest "the mouse moves
    /// weird". With ⌥ held it is still the cull's picks (↓ ↑).
    ///
    /// Sideways, when the swipe the system tracks cannot run — Swipe between
    /// pages off, a neighbour not decoded yet, a one-frame burst, a tilt
    /// wheel — one firm swipe or one notch is one frame, the way the picture
    /// moves under the fingers: pushed left, the next frame. It used to be
    /// dropped without a word.
    public struct FrameScroll {
        public struct Step: Equatable, Sendable {
            public let action: KeyMap.Action
            /// A step after the first of its gesture: spent as a held key is.
            public let held: Bool
        }

        private var upDown = Stepper()
        private var across = Stepper()

        public init() {}

        /// One scroll event's steps. `down` is the device's own direction,
        /// negative toward him — a wheel rolled toward him, fingers drawn
        /// down — and `across` is the picture's, negative pushed left: both
        /// negative going forward. `option` is ⌥.
        public mutating func steps(down: CGFloat, across dx: CGFloat, precise: Bool, began: Bool,
                                   option: Bool, at now: TimeInterval) -> [Step] {
            let sideways = abs(dx) > abs(down)
            let (n, fresh) = sideways
                ? across.gestureSteps(dx, precise: precise, at: now, began: began, oncePerGesture: precise)
                : upDown.gestureSteps(down, precise: precise, at: now, began: began)
            guard n != 0 else { return [] }
            let forward = n < 0
            let action: KeyMap.Action = option ? (forward ? .nextPick : .previousPick)
                                               : (forward ? .nextFrame : .previousFrame)
            return (0..<abs(n)).map { Step(action: action, held: !(fresh && $0 == 0)) }
        }
    }
}
