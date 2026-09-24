import Foundation
import Observation

/// The Settings rows whose value is the engine's, not the app's (DESIGN.md
/// §2.11, §3.8).
///
/// "Let go of archived RAWs after" was a number of Settings' own, written to
/// the defaults and read by nothing, while every shoot's Storage panel went on
/// saying the library's 365. There is one number now, the library's, and this
/// reads and writes it on the engine - the same one a shoot's "Use as
/// default" sets and archive.py reads for a shoot with none of its own.
@MainActor @Observable
public final class EngineSettings {
    public static let shared = EngineSettings()

    /// The library's number of days, as the engine last said it; `nil` until
    /// it has, or with no engine to ask.
    public private(set) var retainDays: Int?
    /// The engine's sentence when it refused a change, beside the row.
    public private(set) var refusal: String?

    /// The engine running now, handed over each time one starts
    /// (`AppModel.connected`).
    @ObservationIgnored private var client: StudioClient?

    public init(client: StudioClient? = nil) {
        self.client = client
    }

    /// For the harness and previews: an engine that has already answered.
    public init(previewRetainDays: Int?) {
        self.retainDays = previewRetainDays
    }

    /// Another engine: what the last one said is not this one's to show,
    /// and this one is asked at once - Settings ▸ Storage open over a
    /// restart went empty and grey until the tab was shown again.
    public func attach(_ client: StudioClient?) {
        guard client !== self.client else { return }
        self.client = client
        retainDays = nil
        refusal = nil
        if client != nil { Task { await load() } }
    }

    public func load() async {
        guard let c = client else { return }
        if let r = try? await c.get(Self.defaultRetain) { retainDays = r.days }
    }

    /// Set the library's number. What is shown afterwards is the engine's
    /// answer, so a refused change goes back to what the engine has.
    public func setRetainDays(_ days: Int) async {
        guard let c = client else { return }
        do {
            let r = try await c.post(Self.setDefaultRetain, RetainDefaultBody(days: days))
            if let e = r.error, !e.isEmpty {
                refusal = e
            } else {
                refusal = nil
                retainDays = r.days
            }
        } catch let e as StudioError {
            refusal = e.sentence
        } catch {
            refusal = Strings.API.offline
        }
        if refusal != nil { await load() }
    }

    /// Settings ▸ Learning's two switches, to the engine that is running, so
    /// a change counts without a restart. The engine is started on them too
    /// (`EngineHost.environment`).
    public func sendLearning(automatically: Bool, onlyWhenIdle: Bool) async {
        guard let c = client else { return }
        _ = try? await c.post(Self.learningSwitches,
                              LearningSwitchesBody(auto: automatically, idle_only: onlyWhenIdle))
    }

    static let learningSwitches = Route<OK>(.post, "/api/learned/settings")
    static let defaultRetain = Route<RetainDefault>(.get, "/api/storage/default-retain")
    static let setDefaultRetain = Route<RetainDefault>(.post, "/api/storage/default-retain")
}

/// `GET` and `POST /api/storage/default-retain`: the library's number of days.
public struct RetainDefault: FieldDecodable {
    public let days: Int
    /// Whether he has ever set it; the engine's year otherwise.
    public let set: Bool
    public let error: String?

    public init(fields f: Fields) throws {
        days = f.int("days", 365)
        set = f.bool("set")
        error = f.stringOrNil("error")
    }
}

public struct RetainDefaultBody: Encodable, Sendable {
    public let days: Int
}

/// `POST /api/learned/settings`.
public struct LearningSwitchesBody: Encodable, Sendable {
    public let auto: Bool
    public let idle_only: Bool
}
