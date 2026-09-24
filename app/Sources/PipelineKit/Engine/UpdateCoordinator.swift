import Foundation
import Observation

/// Updates stay as they are: the engine checks, verifies codesign and
/// notarization, and installs. Download and install are two separate explicit
/// actions. Install prints `QUIT`, which `EngineHost` sees and turns into a
/// clean termination. Sparkle is not adopted (DESIGN.md §3.3).
///
/// Presented natively: a plain sentence in the sidebar footer and in About —
/// never a banner that pushes content down — and, when he asks, a small sheet
/// with the answer and the two actions (`UpdateSheet`).
@MainActor @Observable
public final class UpdateCoordinator {
    public private(set) var info: UpdateInfo?
    /// What a check said instead of an answer - the engine's sentence, such
    /// as GitHub answering 404.
    public private(set) var refusal: String?
    /// What the engine said to Download or Install. Kept apart from the
    /// check's, so a refused Download leaves the version it is about, and the
    /// button, on the sheet.
    public private(set) var actionRefusal: String?
    public private(set) var busy = false
    /// The sheet with the answer (`UpdateSheet`). First Edit ▸ Check for
    /// Updates… and the sidebar's "Update to … available ›" open it. The menu
    /// item used to check and say nothing, whatever the answer, and the
    /// footer's › was a label that went nowhere (DESIGN.md §7.9).
    public var sheetShown = false
    /// A check he asked for is on its way.
    public private(set) var checking = false

    private var client: StudioClient?

    public init() {}

    public func attach(_ client: StudioClient?) { self.client = client }

    /// The one line the sidebar footer carries, or nil when there is nothing
    /// to say. Built only from what the engine reported.
    public var footer: String? {
        guard let info, info.newer == true, let latest = info.latest else { return nil }
        return Strings.App.updateAvailable(latest)
    }

    /// Without `force`, the engine answers from its last check and only looks
    /// again at whether a download has been staged; `force` asks GitHub.
    public func check(force: Bool = false) async {
        guard let client else {
            // The engine is down or still starting: say so rather than show
            // "Checking…" for ever.
            refusal = Strings.API.offline
            return
        }
        do {
            let u = try await client.get(Routes.update(force: force))
            info = u
            refusal = u.error
        } catch let e as StudioError {
            refusal = e.sentence
        } catch {}
    }

    /// First Edit ▸ Check for Updates…: ask GitHub now, and show him the
    /// answer whatever it is.
    public func checkNow() async {
        sheetShown = true
        checking = true
        actionRefusal = nil
        await check(force: true)
        checking = false
    }

    /// The footer's ›: the sheet, with what is already known brought up to
    /// date - a download that has finished since is ready to install.
    public func show() async {
        sheetShown = true
        actionRefusal = nil
        await check()
    }

    /// What the sheet says, from what the engine reported.
    public var answer: Answer {
        if checking { return .checking }
        if let refusal, !refusal.isEmpty { return .refused(refusal) }
        guard let info else { return .checking }
        if info.staged { return .staged(info.latest ?? "") }
        if info.newer == true, let latest = info.latest { return .available(latest, current: info.current) }
        return .upToDate(info.current)
    }

    public enum Answer: Equatable, Sendable {
        case checking
        case upToDate(String)
        /// A newer version, and the one he has.
        case available(String, current: String)
        /// Downloaded, checked and waiting to be installed.
        case staged(String)
        /// The engine's sentence, as it wrote it.
        case refused(String)
    }

    /// Starts the download, a job of the engine's (kind `update`). Returns
    /// whether it started, so the caller can watch it.
    @discardableResult
    public func download() async -> Bool { await post(Routes.updateDownload) }

    public func install() async { await post(Routes.updateInstall) }

    /// The download job came to an end. A build that arrived is ready to
    /// install, which the engine sees by looking at the folder; one that did
    /// not says why under the button that started it.
    public func downloadEnded(_ job: Job) async {
        switch job.outcome {
        case .refused: actionRefusal = job.refusalSentence
        case .failed: actionRefusal = Strings.Update.downloadFailed
        default: actionRefusal = nil
        }
        await check()
    }

    /// The engine's word for the download job.
    public static let jobKind = "update"

    /// For the snapshot harness and tests: a sheet with a known answer.
    public func preview(_ info: UpdateInfo?, refusal: String? = nil, actionRefusal: String? = nil) {
        self.info = info
        self.refusal = refusal
        self.actionRefusal = actionRefusal
        sheetShown = true
    }

    @discardableResult
    private func post(_ r: Route<OK>) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let ok = try await client.post(r, EmptyBody())
            actionRefusal = ok.error
            return ok.error == nil
        } catch let e as StudioError {
            actionRefusal = e.sentence
        } catch {}
        return false
    }
}
