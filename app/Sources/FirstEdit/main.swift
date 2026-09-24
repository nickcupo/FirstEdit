// The Mac app. Thin on purpose: everything worth testing is in PipelineKit.
//
//   FirstEdit                     the app
//   FirstEdit --check             start the engine, list the shoots, stop (DESIGN.md §4.4)
//   FirstEdit --check --deep      and fetch one thumb, one /full and one /crop
//   FirstEdit --smoke             the visible app, reports its sidebar and quits
//   FirstEdit --smoke-offscreen   the real shell offscreen, with strict scratch isolation
import AppKit
import PipelineKit

let arguments = CommandLine.arguments
let offscreen = arguments.contains("--smoke-offscreen")
if offscreen {
    do { try OffscreenSmoke.prepare() }
    catch { print("FAIL offscreen isolation: \(error.localizedDescription)"); exit(2) }
}

if arguments.contains("--check") {
    let deep = arguments.contains("--deep")
    // Never a second engine on the folder the old app has open.
    if let refused = FirstLaunch.headlessCheckRefusal(environment: ProcessInfo.processInfo.environment,
                                                       oldAppRunning: FirstLaunch.oldAppIsRunning) {
        print(refused)
        exit(1)
    }
    // A headless run: no window, no Dock icon. The engine is started, asked
    // once, and stopped; the exit status is the answer.
    Task {
        let code = await HeadlessCheck.run(deep: deep)
        exit(code)
    }
    dispatchMain()
}

if offscreen {
    OffscreenSmoke.run()
    exit(0)
}

// Before the first scene reads a setting and before AppDelegate names the
// support folder or starts the engine: on the first launch under this name,
// the old app's settings and its folder come across; while the old app is
// still open, this says so and quits, and nothing is moved.
FirstLaunch.atLaunch()

AppDelegate.smoke = arguments.contains("--smoke")
if AppDelegate.smoke {
    // Line buffered, so a run that hangs still shows how far it got.
    setvbuf(stdout, nil, _IOLBF, 0)
}
FirstEditApp.main()
