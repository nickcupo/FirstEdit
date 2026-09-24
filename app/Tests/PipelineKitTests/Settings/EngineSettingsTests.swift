import Foundation
import Testing
@testable import PipelineKit

/// §2.11 — the Settings rows whose value is the engine's.
@Suite("Settings rows the engine holds")
@MainActor
struct EngineSettingsTests {

    @Test("the let-go days are the library's number, as the engine says it")
    func retainDecodes() throws {
        let r = try Fixture.decodeJSON(RetainDefault.self, #"{"days": 90, "set": true}"#)
        #expect(r.days == 90 && r.set && r.error == nil)
        let never = try Fixture.decodeJSON(RetainDefault.self, #"{"days": 365, "set": false}"#)
        #expect(never.days == 365 && !never.set)
        let no = try Fixture.decodeJSON(RetainDefault.self, #"{"error": "give a number of days"}"#)
        #expect(no.error == "give a number of days")
        #expect(EngineSettings.defaultRetain.path == "/api/storage/default-retain")
        #expect(EngineSettings.setDefaultRetain.path == EngineSettings.defaultRetain.path)
    }

    @Test("Settings keeps no number of its own: the copy nothing read is gone")
    func noSecondNumber() {
        #expect(!SettingsStore.Key.allCases.map(\.rawValue).contains("storage.retentionDays"))
    }

    @Test("another engine's number is not shown for this one")
    func anotherEngine() {
        let e = EngineSettings(previewRetainDays: 90)
        #expect(e.retainDays == 90)
        e.attach(StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:1/")!, key: "k")))
        #expect(e.retainDays == nil)
    }

    @Test("both Learning switches reach the engine: in its environment at start, and by a POST when changed")
    func learningSwitches() throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "photopipeline.tests.learnSwitches")!)
        for k in SettingsStore.Key.allCases { settings.defaults.removeObject(forKey: k.rawValue) }
        let launch = EngineLaunch(origin: .checkout, python: URL(fileURLWithPath: "/usr/bin/python3"),
                                  script: URL(fileURLWithPath: "/tmp/studio.py"),
                                  resources: URL(fileURLWithPath: "/tmp"))
        func env() -> [String: String] {
            EngineHost.environment(for: launch, base: [:], support: URL(fileURLWithPath: "/tmp/support"),
                                   bundle: .main, settings: settings, key: "k")
        }
        #expect(env()["PIPELINE_LEARN_AUTO"] == "1" && env()["PIPELINE_LEARN_IDLE_ONLY"] == "1", "both on by default")
        settings.learnAutomatically = false
        settings.learnOnlyWhenIdle = false
        #expect(env()["PIPELINE_LEARN_AUTO"] == "0" && env()["PIPELINE_LEARN_IDLE_ONLY"] == "0")
        #expect(EngineSettings.learningSwitches.path == "/api/learned/settings")
        let body = try JSONEncoder().encode(LearningSwitchesBody(auto: false, idle_only: true))
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        #expect(sent == ["auto": false, "idle_only": true])
    }
}
