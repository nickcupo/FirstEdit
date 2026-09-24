import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// §2.5.2: below 1100 pt of content the caption and the tally take a lane of
/// the bar's own, above the cluster. They used to go onto the photograph, as
/// a chip the width of the viewer across its bottom edge — past both sides of
/// a portrait frame, and over the feet at the bottom of every frame.
@Suite("The control bar's captions", .serialized)
@MainActor
struct ControlBarLaneTests {

    /// How tall the bar makes itself when it is offered a column `width`
    /// wide, which is how the light table's stack of bands hands it out.
    static func height(at width: CGFloat, inHUD: Bool = false) throws -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: ControlBar(model: try ViewerTests.model(), inHUD: inHUD))
        return host.sizeThatFits(in: NSSize(width: width, height: 1_000)).height
    }

    @Test("at 1100 pt and up the bar is its 56 pt; below, it is 56 and the 24 pt lane")
    func laneOnlyWhenNarrow() throws {
        #expect(try Self.height(at: 1100) == Tokens.Metric.controlBar)
        #expect(try Self.height(at: 1440) == Tokens.Metric.controlBar)
        #expect(try Self.height(at: 900) == Tokens.Metric.controlBar + ControlBarLayout.captionLane)
        #expect(try Self.height(at: 620) == Tokens.Metric.controlBar + ControlBarLayout.captionLane)
    }

    /// The HUD hands the bar 793 pt and carries the caption in its own pill.
    /// Given the lane there, it said the caption twice and stood 24 pt taller
    /// over the feet of the frame.
    @Test("the Full Image HUD's bar is the cluster alone: no lane, at any width")
    func hudHasNoLane() throws {
        let hud = ControlBarLayout.width + Tokens.Metric.windowMargin * 2
        #expect(try Self.height(at: hud, inHUD: true) == Tokens.Metric.controlBar)
        #expect(try Self.height(at: 900, inHUD: true) == Tokens.Metric.controlBar)
        #expect(try Self.height(at: hud) == Tokens.Metric.controlBar + ControlBarLayout.captionLane,
                "the light table's own bar at that width does have it")
    }

    /// At 1100 the tally started 8 pt after Next Burst and read as part of it;
    /// at 1920 the caption and the tally sat some 550 pt from the controls.
    @Test("beside the cluster the caption ends 16 pt before it and the tally starts 16 pt after it, never far")
    func sideCaptionsStayBesideTheCluster() {
        for width in [1100.0, 1280, 1440, 1728, 1920, 2560] as [CGFloat] {
            let l = ControlBarLayout(contentWidth: width)
            #expect(l.showsSideCaptions)
            #expect(l.frame(.undo).minX - l.leadingCaption.maxX == Tokens.Metric.groupGap, "at \(width)")
            #expect(l.trailingTally.minX - l.frame(.nextBurst).maxX == Tokens.Metric.groupGap, "at \(width)")
            #expect(l.leadingCaption.minX >= Tokens.Metric.barMargin, "at \(width)")
            #expect(l.trailingTally.maxX <= width - Tokens.Metric.barMargin, "at \(width)")
            #expect(l.leadingCaption.width <= ControlBarLayout.sideCaptionWidth)
            #expect(l.trailingTally.width <= ControlBarLayout.sideCaptionWidth)
        }
        // At 1100 each has the whole of its side.
        let l = ControlBarLayout(contentWidth: 1100)
        #expect(l.leadingCaption.minX == Tokens.Metric.barMargin)
        #expect(l.trailingTally.maxX == 1100 - Tokens.Metric.barMargin)
    }

    @Test("the caption beside the cluster names the frame and the burst, and leaves the position to the frame label")
    func captionNamesTheBurst() {
        let text = Strings.LightTable.barCaption("07179", burst: 265)
        #expect(text.contains("07179") && text.contains("265"))
        #expect(!text.contains(" of "))
    }
}
