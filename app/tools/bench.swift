#!/usr/bin/env swift
//
// The performance budgets of DESIGN.md §4.5, and what each one is measured by.
//
//   swift tools/bench.swift --library <scratch lib> [--app <FirstEdit>] [--runs 5]
//
// This file measures the budgets the foundation owns, which today is one:
//
//   Launch to first shoot list   ≤ 1.2 s warm
//
// It runs the real app's `--check` — which starts the real engine, waits for
// its port and asks one authenticated GET /api/shoots — and reports p50 and
// p95 over the runs. A p95 past the budget exits non-zero.
//
// The light table's own budgets need the library and a window, so they are
// measured where they can be run by anyone at any time — `swift test --filter
// BenchTests`, in Tests/PipelineKitTests/LightTable/BenchTests.swift. Three of
// them are live there now: the frame-to-frame swap from cache, a held K, and
// 200 arrow repeats. The rest are listed below with their budget and their
// signpost, so whoever lands them adds the measurement beside those rather
// than starting a third harness.
import Foundation

struct Budget {
    let name: String
    let target: String
    let signpost: String
    let measuredHere: Bool
}

let budgets = [
    Budget(name: "Launch to first shoot list", target: "≤ 1200 ms warm", signpost: "launch", measuredHere: true),
    Budget(name: "Frame to frame, already decoded", target: "≤ 16 ms p95", signpost: "swift test --filter BenchTests", measuredHere: false),
    Budget(name: "Frame to frame, thumb only", target: "≤ 120 ms", signpost: "frame.swap.cold", measuredHere: false),
    Budget(name: "First frame of a prefetched burst", target: "≤ 250 ms to sharp", signpost: "burst.open", measuredHere: false),
    Budget(name: "First frame of a cold burst", target: "thumb ≤ 150 ms, sharp ≤ 900 ms", signpost: "burst.open.cold", measuredHere: false),
    Budget(name: "1:1 tile after a pan to the edge", target: "≤ 200 ms, never a blank frame", signpost: "tile.fetch", measuredHere: false),
    Budget(name: "Arrow held for 200 frames", target: "no dropped frame, 0 verdicts written", signpost: "swift test --filter BenchTests", measuredHere: false),
    Budget(name: "K held for 2 s", target: "exactly 1 verdict written", signpost: "swift test --filter BenchTests", measuredHere: false),
    Budget(name: "Memory after 500 frames", target: "≤ 1.2 GB", signpost: "ImagePump.report()", measuredHere: false),
    Budget(name: "Sidebar or step change", target: "≤ 1 frame of jank", signpost: "step.change", measuredHere: false),
]

func argument(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let app = argument("--app") ?? here.deletingLastPathComponent().appendingPathComponent(".build/debug/FirstEdit").path
let runs = Int(argument("--runs") ?? "5") ?? 5
guard let library = argument("--library") ?? ProcessInfo.processInfo.environment["PHOTOS_ROOT"] else {
    print("bench: --library is required, and it must be a scratch clone.")
    exit(2)
}
guard FileManager.default.isExecutableFile(atPath: app) else {
    print("bench: no app at \(app). Build it first: swift build --product FirstEdit")
    exit(2)
}

func runOnce() -> (ms: Double, shoots: Int)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: app)
    p.arguments = ["--check"]
    var env = ProcessInfo.processInfo.environment
    env["PHOTOS_ROOT"] = library
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { print("bench: could not run the app: \(error)"); return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    var ms: Double?
    var shoots = 0
    for line in text.split(separator: "\n") {
        if line.hasPrefix("OK "), line.hasSuffix(" shoots") {
            shoots = Int(line.dropFirst(3).dropLast(7)) ?? 0
        }
        if line.hasPrefix("launch ") {
            let digits = line.dropFirst(7).filter { $0.isNumber }
            ms = Double(digits)
        }
    }
    guard let ms else { return nil }
    return (ms, shoots)
}

print("bench: \(app)")
print("       library \(library), \(runs) runs")
var samples: [Double] = []
var shoots = 0
for i in 1...max(1, runs) {
    guard let r = runOnce() else { print("bench: run \(i) failed"); exit(1) }
    samples.append(r.ms)
    shoots = r.shoots
    print(String(format: "  run %d: %.0f ms, %d shoots", i, r.ms, r.shoots))
}
samples.sort()
func percentile(_ p: Double) -> Double {
    let i = min(samples.count - 1, max(0, Int((Double(samples.count - 1) * p).rounded())))
    return samples[i]
}
let p50 = percentile(0.5), p95 = percentile(0.95)
let budget = 1200.0
print("")
print(String(format: "launch to first shoot list: p50 %.0f ms, p95 %.0f ms (budget %.0f ms, %d shoots)",
             p50, p95, budget, shoots))
print("")
print("the rest of §4.5, for the crew that lands the viewer:")
for b in budgets where !b.measuredHere {
    print("  \(b.name.padding(toLength: 36, withPad: " ", startingAt: 0))  \(b.target)   signpost \(b.signpost)")
}
if p95 > budget {
    print("")
    print("OVER BUDGET by \(Int(p95 - budget)) ms")
    exit(1)
}
