import SwiftUI

/// The one model the cull cannot work without (§2.10), and his press to fetch
/// it: whether the engine says it is here, and what came of asking.
///
/// Whether it is here is the **engine's** answer — `ready` on `/api/shoots`,
/// which asks the model cache itself. It used to be a listing of the support
/// folder's `models/`, where the engine copies its small bundled models at
/// every start, so once the engine had run a single time the welcome pages
/// said "already on this Mac" over a model that was not.
///
/// Nothing here starts anything on its own. `download()` is only ever called
/// from a button he pressed.
@MainActor @Observable
public final class PictureModel {
    public static let shared = PictureModel()

    public enum Asked: Equatable, Sendable {
        case notYet
        /// The engine took the request; the job is his to watch.
        case started
        /// The engine's sentence, or ours when it could not be reached.
        case refused(String)
    }

    public private(set) var asked: Asked = .notYet
    /// The pages that offer the model. A refusal is said under the button
    /// that was pressed, not under all three.
    public enum Place: Sendable { case welcome, cullStep, settings }
    private var askedFrom: Place?
    /// The job the engine had when it refused, so the sentence goes once that
    /// job has moved on and a press would be answered differently.
    private var refusedUnder: JobMark?
    struct JobMark: Equatable {
        let id: Int
        let running: Bool
        init?(_ j: Job?) {
            guard let j else { return nil }
            id = j.id; running = j.running
        }
    }
    private var app: AppModel?
    /// What a harness scene says the engine answered, with no engine.
    private let preview: Bool?
    /// The engine's number for the job his press started, so an earlier
    /// fetch's ending is not read as this one's.
    private var startedID = 0

    public init() { preview = nil }

    /// For the snapshot harness: an engine that has answered `ready`, and
    /// that a press can be sent to.
    public init(preview ready: Bool) { preview = ready }

    /// The app, once, at launch. The harness never attaches one, so every
    /// scene draws the case the pages are written for: nothing here yet.
    public func attach(_ app: AppModel) { self.app = app }

    /// `nil` until the engine has answered: "not here" and "not asked yet"
    /// are different things, and only one of them is worth a button.
    public var ready: Bool? {
        if let preview { return preview }
        guard let library = app?.library, library.loaded else { return nil }
        return library.ready
    }

    /// Whether there is an engine to ask at all.
    public var canAsk: Bool { preview != nil || app?.client != nil }

    /// The fetch he asked for is under way. The toolbar's item says how far
    /// it has got; this only keeps the button from being pressed twice. From
    /// the press until the job poll first sees it, the press is the answer;
    /// once it has ended and the model is still missing, the button is back.
    ///
    /// One job runs at a time, so another job running, or one the engine
    /// numbered after the fetch, means the fetch has ended. Reading only the
    /// fetch's own record said "Downloading…", with no button, on every page
    /// for as long as a cull ran after a fetch that had failed.
    public var downloading: Bool {
        guard asked == .started else { return false }
        return Self.stillFetching(startedID: startedID, last: app?.jobs.job)
    }

    static func stillFetching(startedID: Int, last j: Job?) -> Bool {
        guard let j else { return true }
        if j.kind == "setup", j.id >= startedID { return j.running }
        if j.running { return false }
        if startedID > 0, j.id > startedID { return false }
        return true
    }

    /// The refusal, under the button that was pressed and while it still
    /// holds: it stayed under every Download It, on every page, until the
    /// next press, long after the cull that caused it had ended.
    public func refusal(at place: Place) -> String? {
        guard case .refused(let why) = asked, askedFrom == nil || askedFrom == place else { return nil }
        guard let app, let under = refusedUnder else { return why }
        return JobMark(app.jobs.job) == under ? why : nil
    }

    /// `POST /api/setup`. A refusal is kept and drawn beside the button that
    /// asked — it was dropped, and the page went on saying it was on its way.
    public func download(from place: Place? = nil) async {
        askedFrom = place
        guard let app, let client = app.client else {
            refuse(Strings.Engine.stopped)
            return
        }
        do {
            let ok = try await client.post(Routes.setup, EmptyBody())
            if let e = ok.error, !e.isEmpty {
                refuse(e)
                return
            }
            startedID = ok.id
            asked = .started
            refusedUnder = nil
            // So the toolbar, the Dock and the end of it are seen, and the
            // library is read again when it is done, which is what turns this
            // offer off.
            app.jobs.watch()
        } catch let e as StudioError {
            refuse(e.sentence)
        } catch {
            refuse(Strings.API.offline)
        }
    }

    private func refuse(_ why: String) {
        asked = .refused(why)
        refusedUnder = JobMark(app?.jobs.job)
    }

    /// For the harness and the tests: a state to draw without an engine.
    public func pretend(_ a: Asked) { asked = a }
}

/// "The picture model is not on this Mac yet. [Download It]" — the way back
/// after Later or Skip on the welcome pages, where it used to be only those
/// pages. Draws nothing unless the engine has said the model is missing.
public struct PictureModelOffer: View {
    let model: PictureModel
    let place: PictureModel.Place

    public init(_ model: PictureModel = .shared, place: PictureModel.Place = .cullStep) {
        self.model = model
        self.place = place
    }

    public var body: some View {
        if model.ready == false {
            VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                Text(Strings.FirstRun.modelMissing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PictureModelButton(model: model, title: Strings.FirstRun.downloadIt, place: place)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pictureModel.offer")
        }
    }
}

/// The button and what came of pressing it, the same on every page that
/// offers the model: the welcome pages, the Cull step and Settings.
struct PictureModelButton: View {
    let model: PictureModel
    let title: String
    let place: PictureModel.Place
    var prominent = false
    /// Whether a prominent button is the page's Return yet.
    var takesReturn = true

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            if model.downloading {
                Label(Strings.FirstRun.downloading, systemImage: Symbols.update)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                button
            }
            if let why = model.refusal(at: place) {
                Label(why, systemImage: Symbols.refusal)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pictureModel.refused")
            }
        }
    }

    @ViewBuilder private var button: some View {
        let b = Button(title) { Task { await model.download(from: place) } }
            .disabled(!model.canAsk)
            .accessibilityIdentifier("pictureModel.download")
        if prominent && takesReturn {
            b.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else if prominent {
            b.buttonStyle(.borderedProminent)
        } else {
            b
        }
    }
}
