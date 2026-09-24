import Foundation
import CoreGraphics
@testable import PipelineKit

/// A light table that is only numbers, so every rule the director keeps is
/// asserted on a build machine with no display attached.
@MainActor
final class FakeLightTable: LightTable {
    var shoot: String
    var lightTableMode: LightTableMode = .single
    var currentStem: String?
    var currentCaption: FrameCaption?
    var zoomState: ZoomState = .fit
    var compareTiles: [CompareTile] = []
    var compareFocus = 0
    var burstIdentifier = "burst-1"
    var burstCells: [BurstCell] = []
    var cursorInBurst = 0

    init(shoot: String, stem: String? = nil) {
        self.shoot = shoot
        self.currentStem = stem
        if let stem {
            currentCaption = FrameCaption(shoot: shoot, shortStem: ShootSession.shortStem(stem),
                                          indexInBurst: 1, framesInBurst: 7, burstNumber: 3,
                                          burstsInShoot: 19, his: .unmarked)
        }
    }

    func go(to stem: String, index: Int, of count: Int, burst: Int, his: VerdictValue.His = .unmarked) {
        currentStem = stem
        cursorInBurst = index - 1
        currentCaption = FrameCaption(shoot: shoot, shortStem: ShootSession.shortStem(stem),
                                      indexInBurst: index, framesInBurst: count, burstNumber: burst,
                                      burstsInShoot: 19, his: his)
    }
}

/// Every gesture the picture window can send, counted.
@MainActor
final class RecordingInput: PictureInput {
    var zoomToggles = 0
    var pinches: [CGFloat] = []
    var smartZooms = 0
    var peeks: [Bool] = []
    var pans: [CGSize] = []
    var steps: [Bool] = []
    var focused: [Int] = []
    var cursorMoves: [String] = []
    var verdicts: [(DisplayAction, String)] = []

    func toggleFitOneToOne(atFramePoint point: CGPoint) { zoomToggles += 1 }
    func pinch(scaleBy factor: CGFloat, atFramePoint point: CGPoint) { pinches.append(factor) }
    func smartZoom(atFramePoint point: CGPoint) { smartZooms += 1 }
    func peek(_ on: Bool, atFramePoint point: CGPoint) { peeks.append(on) }
    func pan(byFramePoints delta: CGSize) { pans.append(delta) }
    func step(forward: Bool) { steps.append(forward) }
    func focusTile(_ index: Int) { focused.append(index) }
    func moveCursor(toStem stem: String) { cursorMoves.append(stem) }
    func verdict(_ action: DisplayAction, onStem stem: String) { verdicts.append((action, stem)) }
}

/// Building blocks for the two screens in front of him.
@MainActor
enum Fake {
    static let laptopKey = ScreenKey.make(displayID: 1, isBuiltIn: true, vendor: 0x610,
                                          model: 0xA050, serial: 0, unit: 0,
                                          physicalMM: CGSize(width: 302, height: 196),
                                          points: CGSize(width: 1512, height: 982), scale: 2,
                                          name: "Built-in Display")
    static let externalKey = ScreenKey.make(displayID: 3, isBuiltIn: false, vendor: 0x1E6D,
                                            model: 0x5B11, serial: 0, unit: 1,
                                            physicalMM: CGSize(width: 597, height: 336),
                                            points: CGSize(width: 2560, height: 1440), scale: 2,
                                            name: "External 5K Panel")
    /// A projector at someone's house: a screen it has never been opened on.
    static let projectorKey = ScreenKey.make(displayID: 9, isBuiltIn: false, vendor: 0x4444,
                                             model: 0x1, serial: 77, unit: 5,
                                             physicalMM: CGSize(width: 2000, height: 1200),
                                             points: CGSize(width: 1920, height: 1080), scale: 1,
                                             name: "EPSON")

    static func info(_ key: ScreenKey, _ name: String, _ size: CGSize, builtIn: Bool,
                     origin: CGPoint = .zero, scale: CGFloat = 2, asleep: Bool = false) -> ScreenInfo {
        let frame = CGRect(origin: origin, size: size)
        return ScreenInfo(key: key, name: name, frame: frame,
                          visibleFrame: frame.insetBy(dx: 0, dy: 12), backingScale: scale,
                          colorSpaceName: "sRGB IEC61966-2.1", isBuiltIn: builtIn,
                          isAsleep: asleep, hasMenuBar: builtIn)
    }

    static var laptop: ScreenInfo {
        info(laptopKey, "Built-in Display", CGSize(width: 1512, height: 982), builtIn: true)
    }
    static var external: ScreenInfo {
        info(externalKey, "External 5K Panel", CGSize(width: 2560, height: 1440), builtIn: false,
             origin: CGPoint(x: 1512, y: 0))
    }
    static var projector: ScreenInfo {
        info(projectorKey, "EPSON", CGSize(width: 1920, height: 1080), builtIn: false,
             origin: CGPoint(x: -1920, y: 0), scale: 1)
    }

    static var docked: ScreenSet { ScreenSet(screens: [laptop, external]) }
    static var undocked: ScreenSet { ScreenSet(screens: [laptop]) }

    /// Defaults nothing else shares, so one test cannot read another's memory.
    static func settings() -> SettingsStore {
        let name = "displays.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }

    /// A director with a window that records instead of drawing.
    static func director(_ set: ScreenSet = Fake.docked,
                         settings: SettingsStore? = nil,
                         watcher: ScreenWatcher? = nil) -> (DisplayDirector, ScreenWatcher) {
        let w = watcher ?? ScreenWatcher(fixed: set)
        let d = DisplayDirector(settings: settings ?? Fake.settings(), screens: w)
        d.makeWindow = { info, _ in NullPicture(screenKey: info.key) }
        d.installPresentationWatch = { _ in "watch" }
        d.removePresentationWatch = { _ in }
        return (d, w)
    }

    static func shootSession() throws -> ShootSession {
        let r = try Fixture.decode(ShootResponse.self, "shoot")
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let pump = ImagePump(budget: .base, loader: { _ in Data() })
        return ShootSession(response: r, ext: nil, client: client, pump: pump,
                            queue: VerdictQueue(sender: { _ in .success(RatingResult(ok: true, key_note: "")) }))
    }
}
