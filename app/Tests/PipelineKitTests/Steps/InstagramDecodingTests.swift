import Foundation
import Testing
@testable import PipelineKit

/// The Instagram routes' answers (DESIGN.md §2.17, §3.4). Real values out of
/// every fixture, and the identity fields throw when they are missing, so a
/// default can never stand in for a fact that went missing.
@Suite("Decoding the Instagram step's answers")
struct InstagramDecodingTests {

    static let fixtures = ["instagram", "instagram-empty", "instagram-planning", "instagram-shape"]

    @Test("every instagram fixture decodes")
    func everyFixture() throws {
        let names = Fixture.names.filter { $0.hasPrefix("instagram") || $0 == "job-instagram-plan" }
        #expect(Set(names).isSuperset(of: Self.fixtures + ["instagram-plan", "instagram-plan-waiting",
                                                            "instagram-crop", "job-instagram-plan"]))
        for n in Self.fixtures { _ = try Fixture.decode(InstagramStatus.self, n) }
        _ = try Fixture.decode(InstagramPlanAnswer.self, "instagram-plan")
        _ = try Fixture.decode(InstagramPlanAnswer.self, "instagram-plan-waiting")
        _ = try Fixture.decode(InstagramCropAnswer.self, "instagram-crop")
        _ = try Fixture.decode(Job.self, "job-instagram-plan")
    }

    @Test("GET /api/instagram: the wall, misses first, every state")
    func wall() throws {
        let s = try Fixture.decode(InstagramStatus.self, "instagram")
        #expect(s.shoot == "2026-09-19")
        #expect(s.ratio == "3:4" && s.landscape == "fit" && s.ratios == ["3:4", "4:5"])
        #expect(s.exported == 17 && s.frames.count == 17)
        #expect(s.planned == 14 && s.made == 3)
        #expect(s.grid_misses == 2 && s.unplanned == 3 && s.stale == 2)
        #expect(s.frames.prefix(2).allSatisfy { $0.gridMiss })
        #expect(s.frames.dropFirst(2).allSatisfy { !$0.gridMiss })
        #expect(s.planning == nil && s.waiting_for == nil)
        // His own window on a portrait.
        let adjusted = try #require(s.frames.first { $0.stem == "TSC06383" })
        #expect(adjusted.adjusted && adjusted.his && adjusted.mode_by == "run")
        #expect(adjusted.manual == InstagramManual(cx: 0.46, cy: 0.38, scale: 0.82))
        #expect(adjusted.cut?.rect == PixelRect(200, 94, 3280, 4373))
        #expect(adjusted.cut?.out == PixelSize(1080, 1440))
        #expect(adjusted.other?.shape == "4:5" && adjusted.other?.rect == PixelRect(200, 230, 3280, 4100))
        #expect(adjusted.auto == PixelRect(0, 0, 4000, 5333))
        #expect(adjusted.copy == nil && !adjusted.copy_current)
        // A landscape he cut himself.
        let cutByHim = try #require(s.frames.first { $0.stem == "TSC05816" })
        #expect(cutByHim.his && !cutByHim.adjusted && !cutByHim.isWhole && cutByHim.mode_by == "you")
        #expect(cutByHim.cut?.shape == "3:4" && cutByHim.cut?.kept == 0.5)
        // Made as shown, and made at the other shape.
        let current = try #require(s.frames.first { $0.stem == "TSC05901" })
        #expect(current.copy_current && current.copy?.out == PixelSize(1080, 1440))
        let otherShape = try #require(s.frames.first { $0.stem == "TSC05945" })
        #expect(otherShape.copy?.out == PixelSize(1080, 1350) && !otherShape.copy_current)
        // A landscape left whole, with the cut it was not given as the faint line.
        let whole = try #require(s.frames.first { $0.stem == "TSC05822" })
        #expect(whole.isWhole && whole.cut?.shape == "whole" && whole.cut?.out == PixelSize(1080, 720))
        #expect(whole.frame == PixelSize(6000, 4000) && whole.shape == "landscape")
        #expect(whole.other?.shape == "3:4" && whole.other?.rect == whole.auto)
        #expect(whole.subject?.kind == "face" && whole.subject?.faces?.count == 4)
        // The profile grid would lose this one's subject.
        let miss = try #require(s.frames.first)
        #expect(miss.stem == "TSC05824" && miss.isWhole && miss.cut?.grid_ok == false)
        let unplanned = try #require(s.frames.first { $0.stem == "TSC05845" })
        #expect(unplanned.state == .unplanned && unplanned.cut == nil && unplanned.frame == nil)
        #expect(unplanned.export_mtime > 0 && unplanned.file == "TSC05845_DxO.jpg")
        // Exported again: one made before, one never made.
        let staleMade = try #require(s.frames.first { $0.stem == "TSC05809" })
        #expect(staleMade.state == .stale && staleMade.made && !staleMade.isPlanned && !staleMade.copy_current)
        let stale = try #require(s.frames.first { $0.stem == "TSC05817" })
        #expect(stale.state == .stale && !stale.made && stale.cut != nil)
    }

    @Test("GET /api/instagram while a pass runs, and with nothing exported")
    func planningAndEmpty() throws {
        let p = try Fixture.decode(InstagramStatus.self, "instagram-planning")
        #expect(p.planning == InstagramProgress(id: 8, label: "working out the cuts: 1 of 6 photographs",
                                                 fraction: 0.167))
        #expect(p.unplanned == 5 && p.stale == 0 && p.planned == 11)
        #expect(p.frames.contains { $0.state == .unplanned } && p.frames.contains { $0.state == .planned })
        let e = try Fixture.decode(InstagramStatus.self, "instagram-empty")
        #expect(e.frames.isEmpty && e.exported == 0 && !e.folder_exists)
    }

    @Test("POST /api/instagram/plan: started, or waiting for his job")
    func plan() throws {
        let started = try Fixture.decode(InstagramPlanAnswer.self, "instagram-plan")
        #expect(started.ok && started.planning && started.id == 8 && started.count == 6)
        let waiting = try Fixture.decode(InstagramPlanAnswer.self, "instagram-plan-waiting")
        #expect(!waiting.planning && waiting.waiting_for?.title == "making 2 Instagram copies of 2026-09-19")
        #expect(waiting.waiting_for?.kind == "instagram")
    }

    @Test("GET /api/job while the cuts are worked out is the machine's own, with the engine's words")
    func planJob() throws {
        let j = try Fixture.decode(Job.self, "job-instagram-plan")
        #expect(j.running && j.background && j.kind == "instagram-plan")
        #expect(j.label == "working out the cuts: 1 of 6 photographs")
        #expect(j.id == 8 && j.shoot == "2026-09-19")
    }

    @Test("POST /api/instagram/crop: the frame as saved and made again")
    func crop() throws {
        let a = try Fixture.decode(InstagramCropAnswer.self, "instagram-crop")
        #expect(a.ok && a.remade)
        let f = try #require(a.frame)
        #expect(f.stem == "TSC05901" && f.adjusted)
        #expect(f.manual == InstagramManual(cx: 0.5, cy: 0.42, scale: 0.9))
        #expect(f.cut?.rect == PixelRect(200, 120, 3600, 4800))
        #expect(f.other?.rect == PixelRect(200, 270, 3600, 4500))
        #expect(f.cut?.kept == 0.72)
        #expect(f.copy_current)
    }

    @Test("POST /api/instagram/shape: the whole wall again, at the new shape")
    func shape() throws {
        let s = try Fixture.decode(InstagramStatus.self, "instagram-shape")
        #expect(s.ratio == "4:5")
        let f = try #require(s.frames.first { $0.stem == "TSC05901" })
        #expect(f.cut?.out == PixelSize(1080, 1350))
        #expect(f.other?.shape == "3:4")
        // Made at 3:4, so no longer the cut shown; the one made at 4:5 now is.
        #expect(!f.copy_current)
        #expect(s.frames.first { $0.stem == "TSC05945" }?.copy_current == true)
        // A cut he placed himself keeps its place in the new shape.
        #expect(s.frames.first { $0.stem == "TSC05816" }?.cut?.shape == "4:5")
    }

    @Test("a wall, a frame and a waiting job without their identity fields do not decode")
    func requiredFields() throws {
        #expect(throws: (any Error).self) {
            try Fixture.decodeJSON(InstagramStatus.self, #"{"frames": []}"#)
        }
        #expect(throws: (any Error).self) {
            try Fixture.decodeJSON(InstagramStatus.self, #"{"shoot": "x"}"#)
        }
        #expect(throws: (any Error).self) {
            try Fixture.decodeJSON(InstagramStatus.self, #"{"shoot": "x", "frames": [{"state": "planned"}]}"#)
        }
        #expect(throws: (any Error).self) {
            try Fixture.decodeJSON(InstagramStatus.self, #"{"shoot": "x", "frames": [{"stem": "TSC1"}]}"#)
        }
        #expect(throws: (any Error).self) {
            try Fixture.decodeJSON(InstagramStatus.self, #"{"shoot": "x", "frames": [{"stem": "TSC1", "state": "done"}]}"#)
        }
        #expect(throws: (any Error).self) {
            try Fixture.decodeJSON(InstagramPlanAnswer.self, #"{"ok": true, "waiting_for": {"kind": "cull"}}"#)
        }
        // The smallest frame the engine sends, unplanned, is fine.
        let s = try Fixture.decodeJSON(InstagramStatus.self,
                                       #"{"shoot": "x", "frames": [{"stem": "TSC1", "state": "unplanned", "frame": null}]}"#)
        #expect(s.frames.first?.state == .unplanned)
    }

    @Test("the picture route asks for the export, sized, with its version")
    func exportedRoute() {
        let tile = ImageRoute.exported(shoot: "2026-09-19", stem: "TSC05901", px: 400, version: 7)
        #expect(tile.path == "/exported/2026-09-19/TSC05901.jpg")
        #expect(tile.query == ["v": "7"])
        #expect(ImageRoute.exported(shoot: "s", stem: "a", px: 2400, version: 1).query == ["v": "1", "px": "2400"])
        #expect(ImageRoute.exported(shoot: "s", stem: "a", px: nil, version: 1).query == ["v": "1", "px": "full"])
        #expect(Routes.instagram("2026-09-19").query == ["name": "2026-09-19"])
        #expect(Routes.instagramShape.path == "/api/instagram/shape")
    }
}
