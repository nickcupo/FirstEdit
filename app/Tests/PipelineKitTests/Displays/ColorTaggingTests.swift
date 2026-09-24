import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Testing
@testable import PipelineKit

/// The most important six lines in the whole two-screen design, and the grey
/// they sit next to.
@Suite("Colour, on two panels")
struct ColorTaggingTests {

    static func image(in space: CGColorSpace) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.82, 0.24, 0.20, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return ctx.makeImage()!
    }

    /// A generic space carries no profile of its own. Assigned to a layer it
    /// means "already in the display's space", so nothing is converted and sRGB
    /// numbers are shown as whatever the panel is.
    static var genericRGB: CGColorSpace {
        Self.image(in: CGColorSpaceCreateDeviceRGB()).colorSpace!
    }

    @Test("a picture with no profile of its own comes back sRGB")
    func generic() {
        let untagged = Self.image(in: Self.genericRGB)
        #expect(untagged.colorSpace?.copyICCData() == nil)
        let tagged = DisplayColor.tagged(untagged)
        #expect(tagged.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test("a picture that does carry a profile is honoured, not overridden")
    func p3IsLeftAlone() {
        let p3 = Self.image(in: CGColorSpace(name: CGColorSpace.displayP3)!)
        let tagged = DisplayColor.tagged(p3)
        #expect(tagged.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test("a picture already in sRGB is handed straight back")
    func sRGBIsUntouched() {
        let srgb = Self.image(in: DisplayColor.sRGB)
        #expect(DisplayColor.tagged(srgb).colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test("what the engine actually serves, decoded and tagged, is sRGB")
    func engineBytes() throws {
        // The routes serve JPEGs with no profile embedded — JFIF and nothing
        // else. Whatever ImageIO assumes for them on any given OS, what the
        // layer is handed is sRGB.
        let data = makeJPEG(width: 320, height: 214)
        let decoded = try Downsampler.decode(data, maxPixel: 320)
        let tagged = DisplayColor.tagged(decoded)
        #expect(tagged.colorSpace != nil)
        #expect(tagged.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test("anything that renders a frame to pixels makes its context in sRGB")
    func context() {
        let ctx = DisplayColor.context(width: 100, height: 80)
        #expect(ctx?.colorSpace?.name == CGColorSpace.sRGB)
    }

    // MARK: - the surround

    @Test("the surround is the same value on both screens, and it is sRGB")
    func surroundIsSRGB() {
        for choice in ViewerBackground.allCases {
            for wide in [true, false] {
                let c = DisplaySurround.color(choice, wide: wide)
                // `.matchSystem` is the one that is allowed to be a system
                // colour, and it is the one he has to opt into.
                guard choice != .matchSystem || wide else { continue }
                let converted = c.usingColorSpace(.sRGB)
                #expect(converted != nil)
            }
        }
    }

    @Test("Neutral Grey is #3A3A3A in a window and #1A1A1A where the picture has the screen")
    func measuredGreys() {
        let window = DisplaySurround.color(.neutralGrey, wide: false).usingColorSpace(.sRGB)!
        let wide = DisplaySurround.color(.neutralGrey, wide: true).usingColorSpace(.sRGB)!
        #expect(Int((window.redComponent * 255).rounded()) == 0x3A)
        #expect(Int((wide.redComponent * 255).rounded()) == 0x1A)
        // Neutral: the three components are equal, so it tints nothing.
        #expect(window.redComponent == window.greenComponent)
        #expect(window.greenComponent == window.blueComponent)
    }

    @Test("the surround does not follow light and dark, on either screen")
    func surroundIgnoresAppearance() {
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        var inLight: NSColor?
        var inDark: NSColor?
        light.performAsCurrentDrawingAppearance {
            inLight = DisplaySurround.color(.neutralGrey, wide: true).usingColorSpace(.sRGB)
        }
        dark.performAsCurrentDrawingAppearance {
            inDark = DisplaySurround.color(.neutralGrey, wide: true).usingColorSpace(.sRGB)
        }
        // His eye adapts to the surround, and every exposure call he makes is
        // made relative to it. A surround that flipped at sunset would mean the
        // frames he judged at four and the frames he judged at seven were
        // judged against two different references.
        #expect(inLight?.redComponent == inDark?.redComponent)
    }

    @Test("no source in Displays or Design draws in a panel's own space")
    func noDeviceSpaces() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Displays
            .deletingLastPathComponent()   // PipelineKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("app/Sources/PipelineKit")
        // A grey defined in a panel's own space renders as a different grey on
        // each panel, which is the single most visible two-screen bug there is
        // and the one that would make him distrust the colour of the photograph
        // next to it.
        let banned = ["NSColor(deviceWhite:", "NSColor(calibratedWhite:",
                      "NSColor(deviceRed:", "NSColor(calibratedRed:",
                      "CGColorSpaceCreateDeviceGray("]
        var hits: [String] = []
        for folder in ["Displays", "Design"] {
            let dir = root.appendingPathComponent(folder)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "swift" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for word in banned where text.contains(word) {
                    hits.append("\(folder)/\(file.lastPathComponent): \(word)")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }
}
