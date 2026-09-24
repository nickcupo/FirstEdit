import Foundation
import Testing
@testable import PipelineKit

/// The card row's eject is ⌘E's, on the card ⌘E means.
@Suite("The memory card row ejects the card ⌘E would")
@MainActor
struct CardRowTests {

    @Test("the card on screen, else the first; none with no card in")
    func whichCard() {
        let cards = ["/Volumes/EOS_DIGITAL", "/Volumes/Untitled"]
        #expect(SidebarView.cardForEject(.card("/Volumes/Untitled"), cards: cards) == "/Volumes/Untitled")
        #expect(SidebarView.cardForEject(.allShoots, cards: cards) == "/Volumes/EOS_DIGITAL")
        #expect(SidebarView.cardForEject(nil, cards: cards) == "/Volumes/EOS_DIGITAL")
        // A card page left open after that card came out is not a card to eject.
        #expect(SidebarView.cardForEject(.card("/Volumes/Gone"), cards: cards) == "/Volumes/EOS_DIGITAL")
        #expect(SidebarView.cardForEject(.allShoots, cards: []) == nil)
    }

    @Test("not while a copy is running off a card or waiting on the list")
    func notWhileCopying() {
        let copy = Job(running: true, stopped: false, kind: "ingest", shoot: "2026-09-23")
        #expect(CardWatcher.copyNeedsTheCard(job: copy, running: true, waiting: []))
        let cull = Job(running: true, stopped: false, kind: "cull", shoot: "2026-09-19")
        #expect(!CardWatcher.copyNeedsTheCard(job: cull, running: true, waiting: []))
    }
}
