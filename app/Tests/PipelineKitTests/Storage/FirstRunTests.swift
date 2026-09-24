import Foundation
import Testing
@testable import PipelineKit

/// §2.10 and §2.11 — first run with nothing installed, and the settings it
/// writes.
@Suite("First run, and Settings")
@MainActor
struct FirstRunTests {

    static func scratch(_ name: String = #function) -> SettingsStore {
        let d = UserDefaults(suiteName: "photopipeline.tests.\(name)")!
        for k in SettingsStore.Key.allCases { d.removeObject(forKey: k.rawValue) }
        return SettingsStore(defaults: d)
    }

    @Test("with nothing installed, every page still has something true to say")
    func nothingInstalled() {
        let world = FirstRunSheet.World.empty
        #expect(world.existingLibrary() == nil)
        #expect(world.editors().isEmpty)
        // Each page's sentence for that case exists and is not a placeholder.
        #expect(Strings.FirstRun.noLibraryYet.contains("Choose a folder"))
        #expect(Strings.FirstRun.modelLine.contains("1.7 GB"))
        #expect(Strings.FirstRun.noEditorFound.contains("Choose the one you will use"))
        #expect(FirstRunSheet.pages == 4)
    }

    @Test("a library already on the Mac is found, counted, and never moved")
    func anExistingLibrary() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-firstrun-\(UUID().uuidString)")
        let shoots = tmp.appendingPathComponent("shoots")
        try FileManager.default.createDirectory(at: shoots, withIntermediateDirectories: true)
        // Shoots as they are on his disk: one still holding its RAWs, one
        // delivered and cleared down to its cull. And a folder with nothing
        // whatever in it, which the studio's own mkdir used to leave behind
        // and which is not a shoot by any test.
        for (name, inside) in [("2026-09-13-dog", "raw"), ("2026-09-19", "cull")] {
            try FileManager.default.createDirectory(at: shoots.appendingPathComponent("\(name)/\(inside)"),
                                                    withIntermediateDirectories: true)
        }
        for name in [".DS_Store", "shoots"] {
            try FileManager.default.createDirectory(at: shoots.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let world = FirstRunSheet.World.real(libraryCandidate: tmp, editors: { [] })
        let found = try #require(world.existingLibrary())
        #expect(found.url.path == tmp.standardizedFileURL.path)
        #expect(found.shoots == 2, "a dotfile is not a shoot, and neither is an empty folder")
        #expect(Strings.FirstRun.foundShoots(2, "~/photos").contains("We found 2 shoots"))
        #expect(Strings.FirstRun.nothingIsMoved.contains("never moves"))
    }

    @Test("an empty library folder is not a library")
    func anEmptyFolder() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-firstrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("shoots"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(FirstRunSheet.World.real(libraryCandidate: tmp, editors: { [] }).existingLibrary() == nil)
        // And a folder that is not there at all.
        let nowhere = tmp.appendingPathComponent("nope")
        #expect(FirstRunSheet.World.real(libraryCandidate: nowhere, editors: { [] })
            .existingLibrary() == nil)
    }

    /// The folder listing it used to be was fooled by the engine's own small
    /// models, copied there at every start, and the welcome pages then said
    /// "already on this Mac" over a model that was not.
    @Test("whether the picture model is here is the engine's answer, and unknown until it gives one")
    func theModelIsTheEnginesAnswer() {
        #expect(PictureModel().ready == nil, "no engine, no answer")
        #expect(PictureModel(preview: false).ready == false)
        #expect(PictureModel(preview: true).ready == true)
        let app = AppModel(preview: Library(), state: .stopped, navigation: Navigation(selection: .allShoots))
        let m = PictureModel()
        m.attach(app)
        #expect(m.ready == nil, "a library that has not been read has not said")
        #expect(!m.canAsk, "and with no engine there is nothing to press")
    }

    @Test("a press that cannot reach the engine says so, where it was pressed")
    func aRefusedDownloadIsSaid() async {
        let m = PictureModel()
        await m.download(from: .settings)
        #expect(m.asked == .refused(Strings.Engine.stopped))
        #expect(!m.downloading)
        // Under the button that was pressed, and not under the other two.
        #expect(m.refusal(at: .settings) == Strings.Engine.stopped)
        #expect(m.refusal(at: .cullStep) == nil)
        #expect(m.refusal(at: .welcome) == nil)
    }

    /// After a fetch that failed, a cull started and every offer said
    /// "Downloading…" with no button for as long as it ran.
    @Test("the fetch reads as under way only until the engine has moved on from it")
    func downloadingEnds() throws {
        let fetch = { (running: Bool, id: Int) in
            try Fixture.decodeJob(running: running, fraction: 0.2, kind: "setup", shoot: "", id: id)
        }
        let cull = { (running: Bool, id: Int) in
            try Fixture.decodeJob(running: running, fraction: 0.2, kind: "cull", id: id)
        }
        // Pressed, and the poll has not seen it: the press is the answer.
        #expect(PictureModel.stillFetching(startedID: 7, last: nil))
        #expect(PictureModel.stillFetching(startedID: 7, last: try cull(false, 6)))
        // Its own record.
        #expect(PictureModel.stillFetching(startedID: 7, last: try fetch(true, 7)))
        #expect(!PictureModel.stillFetching(startedID: 7, last: try fetch(false, 7)))
        // Another job running, or a later one: one job runs at a time.
        #expect(!PictureModel.stillFetching(startedID: 7, last: try cull(true, 8)))
        #expect(!PictureModel.stillFetching(startedID: 7, last: try cull(false, 8)))
    }

    @Test("the retention field's unit agrees with its number")
    func oneDay() {
        #expect(Strings.Storage.daysWord(1) == "day")
        #expect(Strings.Storage.daysWord(0) == "days")
        #expect(Strings.Storage.daysWord(365) == "days")
    }

    @Test("the way back names the size and says what happens without it")
    func theOffer() {
        #expect(Strings.FirstRun.modelMissing.contains("1.7 GB"))
        #expect(Strings.FirstRun.modelMissing.contains("first cull fetches it"))
        #expect(!Strings.FirstRun.downloading.contains("Activity item"))
    }

    /// Settings ▸ Advanced ▸ Show the welcome pages again, then Skip, moved
    /// Open keepers in to the first editor installed, over the one he chose.
    @Test("the welcome pages keep the editor he chose, and write one only on a first run or when he picks it")
    func hisEditorIsKept() {
        let lab = FirstRunSheet.EditorChoice(id: "dxo", name: "DxO PhotoLab 10", url: nil)
        let lr = FirstRunSheet.EditorChoice(id: "lightroom", name: "Lightroom Classic", url: nil)
        // Shown: his pick, then his setting, then the first here, then PhotoLab.
        #expect(FirstRunSheet.shownEditor(picked: nil, saved: "lightroom", found: [lab]) == "lightroom")
        #expect(FirstRunSheet.shownEditor(picked: "dxo", saved: "lightroom", found: [lab]) == "dxo")
        #expect(FirstRunSheet.shownEditor(picked: nil, saved: nil, found: [lr, lab]) == "lightroom")
        #expect(FirstRunSheet.shownEditor(picked: nil, saved: "nothing-we-know", found: []) == "dxo")
        // Saved: never over his own choice unless he picks another.
        #expect(FirstRunSheet.editorToSave(picked: nil, saved: "lightroom", found: [lab]) == nil)
        #expect(FirstRunSheet.editorToSave(picked: "dxo", saved: "lightroom", found: [lab]) == "dxo")
        // A first run saves what it shows, so a Mac with only Lightroom does
        // not start its shoots on PhotoLab; and nothing before the look.
        #expect(FirstRunSheet.editorToSave(picked: nil, saved: nil, found: [lr]) == "lightroom")
        #expect(FirstRunSheet.editorToSave(picked: nil, saved: nil, found: nil) == nil)
    }

    /// His Mac has DxO PhotoLab 10, installed as DXOPhotoLab10.app: the
    /// welcome said no editor was found, and every Presets page said PhotoLab
    /// was not on this Mac.
    @Test("PhotoLab is found under the folder name its newer releases use")
    func photoLabTen() {
        #expect(Editors.isNamed("DXOPhotoLab10.app", "dxo"))
        #expect(Editors.isNamed("DxO PhotoLab 8.app", "dxo"))
        #expect(!Editors.isNamed("Photos.app", "dxo"))
        #expect(!Editors.isNamed("DXOPhotoLab10 notes.txt", "dxo"))
        #expect(Strings.FirstRun.keepersOpenIn("DxO PhotoLab 10") == "Keepers open in DxO PhotoLab 10.")
    }

    /// PhotoLab 10's bundle says "DXOPhotoLab10" as its display name, and the
    /// page said "Keepers open in DXOPhotoLab10." The name is the Finder's.
    @Test("an editor is named as the Finder names it, not by its bundle's display-name key")
    func editorNamedAsTheFinderDoes() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let app = tmp.appendingPathComponent("Some Editor 3.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleDisplayName": "SOMEEDITOR3", "CFBundleName": "Some Editor 3",
                                   "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        #expect(FirstRunSheet.World.editorName(app, id: "dxo") == "Some Editor 3")
    }

    @Test("first run writes what he chose, and the flag that stops it asking again")
    func whatFirstRunWrites() {
        let store = Self.scratch("whatFirstRunWrites")
        #expect(!store.firstRunDone)
        #expect(store.libraryFolder == nil)
        store.libraryFolder = URL(fileURLWithPath: "/scratch/photos")
        store.editor = "dxo"
        store.firstRunDone = true
        #expect(store.libraryFolder?.path == "/scratch/photos")
        #expect(store.editor == "dxo")
        #expect(store.firstRunDone)
    }

    @Test("Advanced hands back no tips: none was ever drawn, so the button is gone")
    func noTipsButton() throws {
        let tab = try String(contentsOf: StringCatalogTests.app
            .appendingPathComponent("Sources/PipelineKit/SettingsUI/Tabs/AdvancedTab.swift"), encoding: .utf8)
        #expect(!tab.contains("showTipsAgain"))
        #expect(!tab.contains("TipStore"))
    }

    @Test("Settings has five tabs and each one has a name and a symbol")
    func fiveTabs() {
        #expect(SettingsView.Tab.allCases.count == 5)
        for tab in SettingsView.Tab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.symbol.isEmpty)
        }
    }

    @Test("the Choosing defaults are the ones §2.11 fixes")
    func choosingDefaults() {
        let store = Self.scratch("choosingDefaults")
        #expect(store.viewerBackground == .neutralGrey)
        #expect(store.spaceShowsWholePicture)
        #expect(store.afterLastFrameGoesOn, "after the last frame of a burst: go to the next burst")
        #expect(store.reasonsStripAfterDrop)
        #expect(!store.openLargeStacksInCompare)
        #expect(store.showCullMarks)
    }

    @Test("the Learning defaults are on, and the sentence under them is the promise")
    func learningDefaults() {
        let store = Self.scratch("learningDefaults")
        #expect(store.learnAutomatically)
        #expect(store.learnOnlyWhenIdle)
        #expect(Strings.Settings.learningIsChecked
            .contains("checked against every photograph you kept"))
    }

    @Test("nothing in Settings schedules a deletion, and the Storage tab says so")
    func nothingIsScheduled() {
        #expect(Strings.Settings.retentionIsALock.hasPrefix("Nothing is scheduled"))
        #expect(Strings.Settings.retentionIsALock.contains("Let Go of the Archived RAWs…"),
                "it names the button it holds back, where it said 'the button on a shoot'")
        #expect(Strings.Storage.retentionIsALock.contains("Nothing is scheduled"))
    }

    @Test("Advanced says whether an extension is there and never names anything it contributes")
    func theExtensionRow() {
        #expect(Strings.Settings.extensionNotFound.contains("complete without one"))
        #expect(Strings.Settings.extensionFound == "Found")
        let store = Self.scratch("theExtensionRow")
        #expect(!store.webInspector, "off by default (NAT-17)")
    }
}

/// §2.10 — the folder chosen on page two reaches the engine as he leaves that
/// page, before page three's Download Now, and only once.
@Suite("First run hands the folder over once")
@MainActor
struct FirstRunHandOverTests {
    @Test("a chosen folder is handed over, the same one again is not, and a new choice is")
    func once() {
        let a = URL(fileURLWithPath: "/scratch/photos")
        let b = URL(fileURLWithPath: "/Volumes/Archive/photos")
        #expect(FirstRunSheet.handOver(chosen: nil, adopted: nil) == nil)
        #expect(FirstRunSheet.handOver(chosen: a, adopted: nil) == a)
        #expect(FirstRunSheet.handOver(chosen: a, adopted: a) == nil)
        #expect(FirstRunSheet.handOver(chosen: URL(fileURLWithPath: "/scratch/photos/"), adopted: a) == nil)
        #expect(FirstRunSheet.handOver(chosen: b, adopted: a) == b)
    }
}
