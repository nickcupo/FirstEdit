import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// Settings ▸ Choosing ▸ "Show the cull's marks in the filmstrip" was written
/// and never read: he turned it off and the marks stayed (§2.11).
@Suite("Show the cull's marks, as the filmstrip reads it", .serialized)
@MainActor
struct FilmstripCullMarksSettingTests {

    static func scratch(_ name: String = #function) -> SettingsStore {
        let d = UserDefaults(suiteName: "photopipeline.tests.cullMarks.\(name)")!
        for k in SettingsStore.Key.allCases { d.removeObject(forKey: k.rawValue) }
        return SettingsStore(defaults: d)
    }

    @Test("off, no thumbnail carries the cull's mark or its fault; on again, they are back without a press")
    func followsTheSetting() throws {
        let m = try ViewerTests.modelAllSeen()
        let store = Self.scratch()
        m.settings = store
        #expect(store.showCullMarks, "on by default")
        store.showCullMarks = false
        let (w, thumbs) = try FilmstripMarksTests.thumbs(m)
        defer { w.close() }
        #expect(!thumbs.isEmpty)
        for (thumb, _) in thumbs {
            #expect(!thumb.marks.showCull)
            #expect(thumb.marks.fault == nil && thumb.marks.faultCaption == nil)
        }
        // His own marks are his, whatever this says.
        #expect(thumbs.contains { $0.0.marks.agreed || $0.0.marks.his != .unmarked })

        // Settings is changed while the strip is on screen: it is drawn
        // again at once, not at his next key.
        store.showCullMarks = true
        for _ in 0..<100 where !thumbs.allSatisfy({ $0.0.marks.showCull }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(thumbs.allSatisfy { $0.0.marks.showCull })
    }

    @Test("a thumbnail told not to show the cull's mark draws nothing top-right")
    func drawsNothingThere() throws {
        func topRightInk(_ show: Bool) throws -> Int {
            let v = FilmstripItemView(frame: NSRect(x: 0, y: 0, width: 90, height: FilmstripItemView.itemHeight))
            v.appearance = NSAppearance(named: .aqua)
            var marks = FilmstripItemView.Marks()
            marks.cullRating = 5
            marks.number = "0412"
            marks.showCull = show
            v.marks = marks
            let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            var ink = 0
            for x in (rep.pixelsWide * 3 / 4)..<rep.pixelsWide {
                for y in 0..<(rep.pixelsHigh / 3) {
                    if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1, c.brightnessComponent > 0.8 { ink += 1 }
                }
            }
            return ink
        }
        #expect(try topRightInk(true) > 0)
        #expect(try topRightInk(false) == 0)
    }
}
