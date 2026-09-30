// swift-tools-version: 6.0
//
// The Mac app, as a package. No Xcode project, so the repository root stays
// Python and build.sh stays a shell script.
//
// Nothing here names a file. SwiftPM takes every source under a target's own
// directory, so a crew adding LightTable/StageView.swift or
// Scenes/Steps/CullStep.swift never edits this file — which removes the one
// merge conflict every crew was otherwise guaranteed to hit.
//
// There are no dependencies and there will not be any: the app ships a signed
// bundle around a bundled interpreter, and a third-party package is one more
// thing to audit, notarize and explain in NOTICES.
import PackageDescription

let package = Package(
    name: "FirstEdit",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FirstEdit", targets: ["FirstEdit"]),
        .library(name: "PipelineKit", targets: ["PipelineKit"]),
        .executable(name: "SnapshotHarness", targets: ["SnapshotHarness"]),
        .executable(name: "RollThumbnail", targets: ["RollThumbnail"]),
    ],
    targets: [
        // Thin on purpose: the app target is an entry point and a delegate.
        // Everything worth testing lives in the library, which a test target
        // and a snapshot harness can both import.
        .executableTarget(name: "FirstEdit", dependencies: ["PipelineKit"]),
        .target(name: "PipelineKit"),
        .executableTarget(name: "SnapshotHarness", dependencies: ["PipelineKit"]),
        // Finder's thumbnails for packed bursts. RollPreview reads a .roll and
        // nothing else, so the extension that links it stays small: it runs
        // inside Finder's thumbnailer, not beside the engine. RollThumbnail is
        // the extension's binary; app/build.sh puts it in
        // Contents/PlugIns/RollThumbnail.appex. Swift 5 mode for it alone:
        // QuickLook's callbacks are not annotated for Swift 6 yet.
        .target(name: "RollPreview"),
        .executableTarget(name: "RollThumbnail", dependencies: ["RollPreview"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PipelineKitTests",
            dependencies: ["PipelineKit", "RollPreview"],
            // Captured from the real server by tools/capture-fixtures.sh.
            // Copied rather than processed: they are bytes the decoder has to
            // survive, and a resource step that rewrote them would be testing
            // the wrong thing.
            resources: [.copy("Fixtures")]
        ),
    ]
)
