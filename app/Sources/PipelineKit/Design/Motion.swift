import SwiftUI
import AppKit

/// §2.14. No animation ever delays input: a key pressed mid-animation acts on
/// the final state, which is the caller's job — these only say how long.
public enum Motion {
    /// Read live, so turning Reduce Motion on mid-session takes effect at once.
    public static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Under Reduce Motion everything becomes a 100 ms crossfade.
    private static func pick(_ a: Animation) -> Animation {
        reduced ? .easeInOut(duration: 0.1) : a
    }

    /// Verdict badge: 150 ms spring in, no bounce out.
    public static var badge: Animation { pick(.spring(duration: 0.15, bounce: 0)) }
    /// Zoom: 180 ms spring, interruptible.
    public static var zoom: Animation { pick(.spring(duration: 0.18, bounce: 0)) }
    /// Full Image in and out.
    public static var fullImage: Animation { pick(.easeInOut(duration: 0.2)) }
    /// Compare open and close.
    public static var compare: Animation { pick(.easeInOut(duration: 0.22)) }
    /// A step change.
    public static var step: Animation { pick(.easeInOut(duration: 0.12)) }
    /// Stack expansion in the filmstrip, on width only.
    public static var stackExpand: Animation { pick(.easeOut(duration: 0.18)) }

    /// A progress bar filling between two polls of the engine.
    ///
    /// It has to be the **poll's own interval**: the fraction only moves when
    /// a poll brings a new one, so a 200 ms ramp on a value that changes every
    /// 1.2 s lurched a sixth of the way and then sat dead for a second, four
    /// times over in four different bars. `.linear` is also the one curve
    /// macOS's own controls never use. Given the interval, this fills steadily
    /// and arrives just as the next figure does.
    public static func progress(over interval: Duration) -> Animation? {
        guard !reduced else { return nil }
        let seconds = Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
        return .smooth(duration: max(0.1, seconds))
    }

    /// The rubber-band bounce at the end of a burst: 8 pt over 120 ms, or a
    /// static flash under Reduce Motion.
    public static let rubberBand: CGFloat = 8
    public static let rubberBandDuration: TimeInterval = 0.12

    /// Frame to frame by key: none, ever.
    public static let frameChange: Animation? = nil
}
