import SwiftUI

/// The answer to Check for Updates…, and the two actions of §7.9 - Download,
/// then Install and Relaunch - each his own press.
///
/// The download is a job of the engine's: it shows in the toolbar and in the
/// Activity window like any other, and the sheet can be closed while it runs.
/// When it ends the sheet looks again, so Install is offered without another
/// trip to the menu.
///
/// Install waits while anything of his is running: the installer quits the
/// app to swap it, and an app replaced under a running cull loses the cull.
public struct UpdateSheet: View {
    @Bindable var updates: UpdateCoordinator
    let jobs: JobModel

    public init(updates: UpdateCoordinator, jobs: JobModel) {
        self.updates = updates
        self.jobs = jobs
    }

    /// The download, while it runs.
    private var download: Job? {
        guard let j = jobs.job, j.running, j.kind == UpdateCoordinator.jobKind else { return nil }
        return j
    }

    /// Something of his is running, which Install would cut short. The
    /// machine's own homework is not: it is picked up again after the relaunch.
    private var hisWorkRunning: Bool { jobs.isRunning && !jobs.isBackgroundOnly && download == nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            Label(Strings.Update.title, systemImage: Symbols.update)
                .font(.headline)
            Text(sentence)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("update.sentence")
            if download == nil, case .refused(let why) = updates.answer {
                // The engine's own sentence, as it wrote it, under ours.
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let d = download {
                ProgressView(value: d.fraction)
                    .accessibilityLabel(Strings.Update.downloading(updates.info?.latest ?? ""))
            }
            if case .staged = updates.answer, hisWorkRunning {
                Text(Strings.Update.waitForTheJob)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = updates.actionRefusal, !why.isEmpty {
                RefusalRow(why, owner: .update)
            }
            HStack {
                Spacer()
                buttons
            }
            .padding(.top, Tokens.Metric.relatedGap)
        }
        .padding(Tokens.Metric.windowMargin)
        .frame(width: 420)
        .accessibilityIdentifier("update.sheet")
        .onChange(of: download?.id) { was, now in
            // The download ended while the sheet was up: look again, so the
            // next thing to press is Install rather than the menu. The list
            // may have started its next piece already, so the ended job is
            // found by its number.
            guard let was, now == nil else { return }
            let ended = jobs.job.flatMap { $0.id == was ? $0 : nil }
                ?? jobs.history.last { $0.job.id == was }?.job
            guard let ended else { return }
            Task { await updates.downloadEnded(ended) }
        }
    }

    private var sentence: String {
        if download != nil { return Strings.Update.downloading(updates.info?.latest ?? "") }
        switch updates.answer {
        case .checking: return Strings.Update.checking
        case .upToDate(let v): return Strings.Update.upToDate(v)
        case .available(let v, let current): return Strings.Update.available(v, current: current)
        case .staged(let v): return Strings.Update.staged(v)
        case .refused: return Strings.Update.couldNotCheck
        }
    }

    @ViewBuilder private var buttons: some View {
        if download != nil {
            // It goes on in the toolbar; the sheet is not what keeps it going.
            Button(Strings.Update.close) { updates.sheetShown = false }
                .keyboardShortcut(.defaultAction)
        } else {
            switch updates.answer {
            case .available:
                Button(Strings.Update.later) { updates.sheetShown = false }
                    .keyboardShortcut(.cancelAction)
                Button(Strings.Update.download) {
                    Task { if await updates.download() { jobs.watch() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(updates.busy)
            case .staged:
                Button(Strings.Update.later) { updates.sheetShown = false }
                    .keyboardShortcut(.cancelAction)
                Button(Strings.Update.install) { Task { await updates.install() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(updates.busy || hisWorkRunning)
            case .checking:
                Button(Strings.Update.close) { updates.sheetShown = false }
                    .keyboardShortcut(.cancelAction)
            case .upToDate, .refused:
                Button(Strings.Update.ok) { updates.sheetShown = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

extension RefusalOwner {
    /// What the engine said to Download or Install, on the update sheet.
    public static let update = RefusalOwner("update")
}
