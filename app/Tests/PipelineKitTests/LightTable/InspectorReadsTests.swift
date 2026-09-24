import Foundation
import Testing
@testable import PipelineKit

/// Decision 4: the inspector loses its Keep and Drop buttons (DESIGN.md
/// §2.5.1). It says what was decided; the bar, the keys and the menu decide.
///
/// Read from the source, as the string catalog's test reads it: SwiftUI
/// builds no accessibility tree for a view nobody is listening to, so there
/// is no button to look for in a test, and the promise is about the code —
/// the inspector sends no verdict at all.
@Suite("The inspector reads, it does not decide")
struct InspectorReadsTests {

    static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PipelineKit/LightTable/FrameInspector.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    @Test("no Keep, Drop or Clear the Mark: it sends no verdict of any kind")
    func noVerdictButtons() {
        let code = Self.source
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("struct FrameInspector"), "the inspector's source was not read")
        for verdict in [".keep", ".drop", ".clearMark", ".reason(", ".keepOnly"] {
            #expect(!code.contains("perform(\(verdict)"), "the inspector presses \(verdict) itself")
        }
        #expect(!code.contains("Strings.Verdict.keep") && !code.contains("Strings.Verdict.drop"),
                "the inspector names Keep or Drop as a control")
        // The stack's Compare is a way to look, not to decide, and stays.
        #expect(code.contains("perform(.compare)"))
    }
}
