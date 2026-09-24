import Foundation
import CoreGraphics

/// Where 1:1 points, and what it says about where it is pointing.
///
/// DESIGN.md §2.5.7: the zoom centres on the largest face, else the subject box
/// the engine reports, else the geometric centre. When the aim came from a face
/// the aim point is placed at **0.38 of the viewport height** rather than the
/// centre, because he is checking eyes.
///
/// The rule that matters more than the order: **a silent wrong aim is worse
/// than a stated fallback.** The zoom label always says which of the four it
/// used, so when it lands on an elbow he knows the frame carried no face rather
/// than wondering what the app thinks a face is.
public enum Aim {

    public enum Source: String, Equatable, Sendable {
        case face, subject, centre, held

        /// The zoom label in the control bar.
        public var label: String {
            switch self {
            case .face: return Strings.LightTable.aimFace
            case .subject: return Strings.LightTable.aimSubject
            case .centre: return Strings.LightTable.aimCentre
            case .held: return Strings.LightTable.aimHeld
            }
        }
    }

    public struct Point: Equatable, Sendable {
        /// Normalised frame units, origin top-left.
        public let point: CGPoint
        public let source: Source

        public init(point: CGPoint, source: Source) {
            self.point = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
            self.source = source
        }

        /// Where the aim sits in the viewport, as a share of its height. A face
        /// goes at 0.38 because he is checking eyes; everything else is centred.
        public var verticalPlacement: CGFloat { source == .face ? 0.38 : 0.5 }

        public var label: String { source.label }
    }

    public static let centre = Point(point: CGPoint(x: 0.5, y: 0.5), source: .centre)

    /// The aim for one frame.
    ///
    /// `held` is the previous frame's absolute normalised position, used when
    /// this frame carries neither a face nor a subject. It never jumps to
    /// centre mid-burst: through a 30-frame burst the eyes stay in the same
    /// place on the screen, and a frame with nothing to aim at holds still and
    /// says so.
    public static func resolve(_ row: Row?, held: CGPoint? = nil) -> Point {
        if let row {
            if let x = row.face_x, let y = row.face_y {
                return Point(point: CGPoint(x: x, y: y), source: .face)
            }
            if let s = row.subject, s.count == 4 {
                return Point(point: CGPoint(x: s[0] + s[2] / 2, y: s[1] + s[3] / 2), source: .subject)
            }
        }
        if let held { return Point(point: held, source: .held) }
        return centre
    }

    /// The whole label: `1:1 · on the face`, and at any other factor the
    /// percentage in front of it.
    public static func zoomLabel(percent: Int, aim: Point) -> String {
        percent == 100
            ? "\(Strings.LightTable.oneToOne) · \(aim.label)"
            : "\(percent)% · \(aim.label)"
    }
}
