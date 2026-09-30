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
        .executable(name: "RollQuickLook", targets: ["RollQuickLook"]),
        .executable(name: "RollOpen", targets: ["RollOpen"]),
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
        //
        // It starts in NSExtensionMain, as Xcode's extensions do (-e), and has
        // no symbol called main: NSExtensionMain calls the executable's main
        // once the extension is up, so a main that called NSExtensionMain
        // itself went round until the stack ran out. Swift's top-level code is
        // renamed out of the way instead.
        .target(name: "RollPreview"),
        .executableTarget(name: "RollThumbnail", dependencies: ["RollPreview"],
                          swiftSettings: [.swiftLanguageMode(.v5),
                                          .unsafeFlags(["-Xfrontend", "-entry-point-function-name",
                                                        "-Xfrontend", "roll_thumbnail_unused_main"])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                                                         "-Xlinker", "-application_extension"])]),
        // A double-click on a .roll: "Open Packed Burst.app", a helper inside
        // FirstEdit.app that hands the kept frame to Preview, so opening one
        // never opens FirstEdit.
        .executableTarget(name: "RollOpen", dependencies: ["RollPreview"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // The space bar's preview, built the same way: RollQuickLook.appex.
        .executableTarget(name: "RollQuickLook", dependencies: ["RollPreview"],
                          swiftSettings: [.swiftLanguageMode(.v5),
                                          .unsafeFlags(["-Xfrontend", "-entry-point-function-name",
                                                        "-Xfrontend", "roll_quicklook_unused_main"])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                                                         "-Xlinker", "-application_extension"])]),
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
