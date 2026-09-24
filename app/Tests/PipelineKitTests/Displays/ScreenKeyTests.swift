import Foundation
import CoreGraphics
import Testing
@testable import PipelineKit

/// Every case here is a struct of numbers through `ScreenKey.make(...)`, so the
/// whole suite runs on a build machine with one display or none.
@Suite("Screen identity across a reconnect")
struct ScreenKeyTests {

    /// His external: a 27" panel on a third-party driver board, which reports
    /// the board's vendor and model and a serial of 0.
    static func board(displayID: CGDirectDisplayID = 3,
                      vendor: UInt32 = 0x1E6D, model: UInt32 = 0x5B11,
                      serial: UInt32 = 0,
                      mm: CGSize = CGSize(width: 597, height: 336),
                      points: CGSize = CGSize(width: 2560, height: 1440),
                      scale: CGFloat = 2,
                      unit: UInt32 = 1,
                      name: String = "External 5K Panel") -> ScreenKey {
        ScreenKey.make(displayID: displayID, isBuiltIn: false, vendor: vendor, model: model,
                       serial: serial, unit: unit, physicalMM: mm, points: points, scale: scale,
                       name: name)
    }

    static func builtIn(displayID: CGDirectDisplayID = 1,
                        points: CGSize = CGSize(width: 1512, height: 982),
                        scale: CGFloat = 2,
                        name: String = "Built-in Display") -> ScreenKey {
        ScreenKey.make(displayID: displayID, isBuiltIn: true, vendor: 0x610, model: 0xA050,
                       serial: 0, unit: 0, physicalMM: CGSize(width: 302, height: 196),
                       points: points, scale: scale, name: name)
    }

    @Test("the same panel re-enumerated with a different display id is the same screen")
    func idDoesNotMatter() {
        #expect(Self.board(displayID: 3) == Self.board(displayID: 724_912_386))
    }

    @Test("the built-in matches itself across a scale change, a lid close and a rearrangement")
    func builtInIsItself() {
        let a = Self.builtIn()
        #expect(a == Self.builtIn(scale: 1))
        #expect(a == Self.builtIn(points: CGSize(width: 1728, height: 1117)))
        #expect(a == Self.builtIn(displayID: 9))
        #expect(a.isBuiltIn)
        // And it is never mistaken for an external.
        #expect(a != Self.board())
    }

    @Test("serial 0: two identical boards are told apart by the panel's physical size")
    func serialZero() {
        let his = Self.board()
        let other = Self.board(mm: CGSize(width: 344, height: 193))
        #expect(his != other)
        // The same one, unplugged and plugged back in: a new display id, a new
        // place in the arrangement, the same key.
        #expect(his == Self.board(displayID: 88, unit: 4))
    }

    @Test("a panel that does report a serial identifies itself by it")
    func serialWins() {
        let a = Self.board(serial: 0xC0FFEE)
        #expect(a == Self.board(serial: 0xC0FFEE, mm: CGSize(width: 1, height: 1)))
        #expect(a != Self.board(serial: 0xBADBAD))
    }

    @Test("a resolution change is a new frame key and the same panel")
    func resolutionChange() {
        let at1440 = Self.board()
        let at2160 = Self.board(points: CGSize(width: 3840, height: 2160))
        // The frame saved for one arrangement is wrong for the other…
        #expect(at1440 != at2160)
        // …and the mode and the fill flag survive it.
        #expect(at1440.coarse == at2160.coarse)
    }

    @Test("a scale change is a new frame key and the same panel")
    func scaleChange() {
        let at2x = Self.board(scale: 2)
        let at1x = Self.board(scale: 1)
        #expect(at2x != at1x)
        #expect(at2x.coarse == at1x.coarse)
    }

    @Test("the name macOS shows him is never the identity")
    func nameIsNotIdentity() {
        #expect(Self.board(name: "External 5K Panel") == Self.board(name: "Écran externe"))
    }

    @Test("degenerate numbers still yield a stable key rather than a crash")
    func degenerate() {
        let zeroed = ScreenKey.make(displayID: 0, isBuiltIn: false, vendor: 0, model: 0, serial: 0,
                                    unit: 0, physicalMM: .zero, points: .zero, scale: 0, name: "")
        #expect(!zeroed.raw.isEmpty)
        #expect(zeroed == ScreenKey.make(displayID: 0, isBuiltIn: false, vendor: 0, model: 0,
                                          serial: 0, unit: 0, physicalMM: .zero, points: .zero,
                                          scale: 0, name: ""))
        // Two 0 × 0 mm boards are still told apart, by unit number and name.
        let other = ScreenKey.make(displayID: 0, isBuiltIn: false, vendor: 0, model: 0, serial: 0,
                                   unit: 2, physicalMM: .zero, points: .zero, scale: 0, name: "")
        #expect(zeroed != other)
    }

    @Test("a key is safe in a window's frame autosave name and a defaults key")
    func sanitised() {
        let key = Self.board(name: "Nick's 27\" / panel")
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        #expect(key.sanitised.allSatisfy { allowed.contains($0) })
        #expect(!key.sanitised.isEmpty)
    }

    @Test("it survives a round trip through the defaults dictionary")
    func codable() throws {
        let key = Self.board()
        let data = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(ScreenKey.self, from: data) == key)
    }
}

@Suite("Which screen the picture opens on")
struct ScreenSetTests {

    static func info(_ key: ScreenKey, points: CGSize, builtIn: Bool, origin: CGPoint = .zero,
                     scale: CGFloat = 2, name: String = "Panel") -> ScreenInfo {
        let frame = CGRect(origin: origin, size: points)
        return ScreenInfo(key: key, name: name, frame: frame,
                          visibleFrame: frame.insetBy(dx: 0, dy: 12),
                          backingScale: scale, colorSpaceName: "sRGB IEC61966-2.1",
                          isBuiltIn: builtIn, isAsleep: false, hasMenuBar: builtIn)
    }

    static let laptop = info(ScreenKeyTests.builtIn(), points: CGSize(width: 1512, height: 982),
                             builtIn: true, name: "Built-in Display")
    static let external = info(ScreenKeyTests.board(), points: CGSize(width: 2560, height: 1440),
                               builtIn: false, origin: CGPoint(x: 1512, y: 0),
                               name: "External 5K Panel")

    @Test("the screen it was last open on wins, when it is attached")
    func prefers() {
        let set = ScreenSet(screens: [Self.laptop, Self.external])
        #expect(set.best(preferring: Self.laptop.key)?.key == Self.laptop.key)
        #expect(set.best(preferring: Self.external.key)?.key == Self.external.key)
    }

    @Test("otherwise the largest screen that is not the built-in")
    func largestExternal() {
        let small = Self.info(ScreenKeyTests.board(mm: CGSize(width: 300, height: 200)),
                              points: CGSize(width: 1280, height: 720), builtIn: false)
        let set = ScreenSet(screens: [Self.laptop, small, Self.external])
        #expect(set.best()?.key == Self.external.key)
        // A screen it has never been used on is not preferred into existence.
        #expect(set.best(preferring: ScreenKeyTests.board(serial: 7))?.key == Self.external.key)
    }

    @Test("two identical panels are told apart by the one the pointer is on")
    func pointerBreaksTheTie() {
        let a = Self.info(ScreenKeyTests.board(mm: CGSize(width: 597, height: 336)),
                          points: CGSize(width: 2560, height: 1440), builtIn: false,
                          origin: CGPoint(x: 0, y: 0))
        let b = Self.info(ScreenKeyTests.board(mm: CGSize(width: 598, height: 336)),
                          points: CGSize(width: 2560, height: 1440), builtIn: false,
                          origin: CGPoint(x: 2560, y: 0))
        let set = ScreenSet(screens: [a, b], pointer: CGPoint(x: 3000, y: 100))
        #expect(set.best()?.key == b.key)
    }

    @Test("with one display it opens on the built-in rather than nowhere")
    func oneDisplay() {
        let set = ScreenSet(screens: [Self.laptop])
        #expect(set.best()?.key == Self.laptop.key)
        #expect(set.externals.isEmpty)
    }

    @Test("the panel's own pixels are what the These Screens panel prints")
    func realPixels() {
        #expect(Self.external.realPixels == CGSize(width: 5120, height: 2880))
        let at1x = Self.info(ScreenKeyTests.board(scale: 1),
                             points: CGSize(width: 2560, height: 1440), builtIn: false, scale: 1)
        // The case worth catching: the board is driving the panel at 1×, so the
        // big screen has fewer real pixels than the Self.laptop.
        #expect(at1x.realPixels == CGSize(width: 2560, height: 1440))
    }
}
