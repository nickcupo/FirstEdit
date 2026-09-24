import SwiftUI
import AppKit

/// §2.10 — a sheet over the main window, 560 × 440, four pages, dismissible.
///
/// It works with **nothing installed**: no library, no picture model, no
/// extension. Every page states what is true and offers only what it can
/// honour. Not one page asks for a permission: the removable-volume prompt
/// comes the first time he opens a card, and the notification prompt the
/// first time a job is about to end while the window is not frontmost.
public struct FirstRunSheet: View {
    /// What the sheet is allowed to look at. Injected so a snapshot and a
    /// test never touch a real library, and so the sheet itself never reaches
    /// for a path nobody asked it to.
    public struct World: Sendable {
        /// A library already on this Mac, and how many shoots are in it.
        public var existingLibrary: @Sendable () -> (url: URL, shoots: Int)?
        /// Editors found on this Mac, in the order they should be offered.
        public var editors: @Sendable () -> [EditorChoice]
        /// Where shoots go if he chooses nothing, so page two can say so
        /// instead of leaving Continue's consequence to be found out.
        public var defaultLibrary: URL?

        public init(existingLibrary: @escaping @Sendable () -> (url: URL, shoots: Int)?,
                    editors: @escaping @Sendable () -> [EditorChoice],
                    defaultLibrary: URL? = nil) {
            self.existingLibrary = existingLibrary
            self.editors = editors
            self.defaultLibrary = defaultLibrary
        }

        /// Nothing installed, nothing found: the state the sheet has to work
        /// in, and the one the snapshots are taken in.
        public static let empty = World(existingLibrary: { nil }, editors: { [] })
    }

    public struct EditorChoice: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let url: URL?
        public init(id: String, name: String, url: URL?) {
            self.id = id; self.name = name; self.url = url
        }
    }

    let world: World
    let settings: SettingsStore
    /// Whether the engine says the picture model is here, and his press to
    /// fetch it (page three). With no engine the button is off and says
    /// nothing it cannot do.
    let picture: PictureModel
    /// The folder he chose reaches the engine through the one restart, so
    /// the sidebar and the engine are on it together. Saving it alone left
    /// the engine serving the old library under the new one's name.
    let restarter: EngineRestart
    let finish: () -> Void

    @State private var page = 0
    @State private var folder: URL?
    @State private var foundShoots: Int?
    /// A folder he chose that holds other things and no shoot. Nothing is
    /// kept while this is said.
    @State private var refused: URL?
    @State private var editor: String?
    /// The folder the engine was last pointed at from these pages, so it is
    /// handed over once, as he leaves page two, and not again at Start.
    @State private var adopted: URL?
    /// The engine is restarting on the folder he chose; Continue waits.
    @State private var taking = false
    @State private var changingEditor = false
    /// Download Now takes Return only once page three has been up a moment,
    /// so the Return that left page two — or a second one right behind it —
    /// does not land on it and start a 1.7 GB fetch.
    @State private var armed = false
    /// Swallows Return's key repeats in this sheet: a held Return steps one
    /// page, not through the pages and on into Download Now.
    @State private var repeats: Any?
    /// What the one look at the disk found. Held here so that drawing a page
    /// never calls back into the file system. `nil` until it has answered.
    @State private var editorsLooked: [EditorChoice]?
    private var editorsFound: [EditorChoice] { editorsLooked ?? [] }

    public static let pages = 4

    public init(world: World = .empty, settings: SettingsStore = .shared,
                picture: PictureModel = .shared,
                restarter: EngineRestart = .shared,
                startingAt page: Int = 0,
                finish: @escaping () -> Void) {
        self.world = world
        self.settings = settings
        self.picture = picture
        self.restarter = restarter
        self.finish = finish
        _page = State(initialValue: page)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Tokens.Metric.windowMargin)
            // Chosen while a job of his runs, and he said to wait for it: the
            // pages say where the library goes and when.
            if let waiting = restarter.waiting {
                Text(waiting.sentence(current: nil))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Metric.windowMargin)
                    .padding(.bottom, Tokens.Metric.relatedGap)
                    .accessibilityIdentifier("firstRun.folderWaits")
            }
            Divider()
            footer
        }
        .frame(width: Tokens.Metric.firstRunSheet.width,
               height: Tokens.Metric.firstRunSheet.height)
        .task { await look() }
        .task(id: page) {
            armed = false
            try? await Task.sleep(for: Self.armAfter)
            if !Task.isCancelled { armed = true }
        }
        .onAppear {
            repeats = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                Self.isHeldReturn(e) ? nil : e
            }
        }
        .onDisappear {
            if let repeats { NSEvent.removeMonitor(repeats) }
            repeats = nil
        }
        .accessibilityIdentifier("firstRun.page\(page + 1)")
    }

    // MARK: pages

    @ViewBuilder private var content: some View {
        switch page {
        case 0: welcome
        case 1: whereTheyLive
        case 2: pictureModel
        default: editorPage
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            Text(Strings.FirstRun.welcome).font(.title)
            row(Symbols.stepIngest, Strings.FirstRun.cardTitle, Strings.FirstRun.cardLine)
            row(Symbols.stepCull, Strings.FirstRun.cullTitle, Strings.FirstRun.cullLine)
            row("folder", Strings.FirstRun.filesTitle, Strings.FirstRun.filesLine)
        }
    }

    private var whereTheyLive: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            Text(Strings.FirstRun.whereTitle).font(.title)
            Text(whereLine)
                .font(.callout)
                .foregroundStyle(foundShoots ?? 0 > 0 ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("firstRun.whereLine")
            HStack(spacing: Tokens.Metric.relatedGap) {
                if let f = folder {
                    PathRow(f).frame(height: 22)
                }
                Button(Strings.FirstRun.chooseFolder, action: choose)
                    .accessibilityIdentifier("firstRun.chooseFolder")
            }
            if let refused {
                Label(Strings.Settings.noShootsHere(refused.abbreviatedPath), systemImage: Symbols.refusal)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("firstRun.libraryRefused")
            }
            Text(Strings.FirstRun.nothingIsMoved)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// What page two says about the folder, which is always about the folder
    /// actually in play: the shoots found in it, the empty one he chose to
    /// start in, or where Continue will put them if he chooses nothing. It
    /// kept saying "Choose a folder" under a folder he had just chosen.
    private var whereLine: String {
        if let f = folder, let n = foundShoots, n > 0 {
            return Strings.FirstRun.foundShoots(n, f.abbreviatedPath)
        }
        if let f = folder {
            return Strings.Library.newLibrary(LibraryFolder.shelf(under: f).abbreviatedPath)
        }
        if let d = world.defaultLibrary {
            return Strings.FirstRun.willGoIn(LibraryFolder.shelf(under: d).abbreviatedPath)
        }
        return Strings.FirstRun.noLibraryYet
    }

    private var pictureModel: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            Text(Strings.FirstRun.modelTitle).font(.title)
            if picture.ready == true {
                Label(Strings.FirstRun.modelAlreadyHere, systemImage: Symbols.inUse)
                    .font(.callout)
            } else {
                Text(Strings.FirstRun.modelLine)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                // Download Now is this page's Return. Continue — which is
                // Later, said once — steps aside while the offer stands, so
                // the key his hand goes to fetches the model instead of
                // passing it by.
                PictureModelButton(model: picture, title: Strings.FirstRun.downloadNow, place: .welcome,
                                   prominent: offeringTheModel, takesReturn: armed)
            }
            Spacer(minLength: 0)
        }
    }

    /// Page three, the model not known to be here, and a press that can be
    /// sent: Download Now holds Return, not Continue.
    private var offeringTheModel: Bool {
        page == 2 && picture.ready != true && !picture.downloading && picture.canAsk
    }

    private var editorPage: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            Text(Strings.FirstRun.editorTitle).font(.title)
            if let only = onlyPhotoLab, !changingEditor {
                // One editor on the Mac, and it is the one the Presets step
                // was built for: said, not asked. A radio group with one
                // button in it was a question with nothing to decide.
                HStack(spacing: Tokens.Metric.relatedGap) {
                    EditorIcon(url: only.url)
                    Text(Strings.FirstRun.keepersOpenIn(only.name)).font(.callout)
                    Button(Strings.FirstRun.change) { changingEditor = true }
                        .accessibilityIdentifier("firstRun.changeEditor")
                }
            } else {
                if editorsFound.isEmpty {
                    Text(Strings.FirstRun.noEditorFound)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Every editor the Presets step writes for, with the ones on
                // this Mac marked and the first of them chosen. A real picker,
                // so Tab reaches it and arrow keys move through it the way
                // they do in every other Mac app.
                Picker(selection: Binding(get: { chosenEditor }, set: { editor = $0 })) {
                    ForEach(Editors.ids, id: \.self) { id in
                        let here = editorsFound.first { $0.id == id }
                        HStack(spacing: Tokens.Metric.relatedGap) {
                            // The slot is kept on a row with no icon, so the
                            // names line up once any editor has one.
                            EditorIcon(url: here?.url, reserve: !editorsFound.isEmpty)
                            Text(here?.name ?? Editors.name(id))
                            if here != nil {
                                Text(Strings.FirstRun.onThisMac).foregroundStyle(.secondary)
                            }
                        }
                        .tag(id)
                    }
                } label: {
                    Text(Strings.Settings.editor)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("firstRun.editors")
            }
            Text(Strings.FirstRun.editorLine).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var chosenEditor: String {
        Self.shownEditor(picked: editor, saved: settings.editor, found: editorsFound)
    }

    /// The editor page four shows chosen: his pick on it, else the one he
    /// already chose in Settings, else the first on this Mac, else PhotoLab.
    /// Preferring the first one found over his own choice meant Show the
    /// welcome pages again, then Skip, quietly moved Open keepers in to
    /// whatever editor was installed first.
    static func shownEditor(picked: String?, saved: String?, found: [EditorChoice]) -> String {
        if let picked { return picked }
        if let saved, Editors.ids.contains(saved) { return saved }
        return found.first?.id ?? "dxo"
    }

    /// What Start or Skip writes, or `nil` to leave the setting as it is: his
    /// pick on page four; on a first run with no editor chosen yet, the one
    /// the page shows chosen — pre-selected and saved are the same thing, or a
    /// Mac with only Lightroom shows it chosen while shoots start on
    /// PhotoLab; and nothing over a choice he has already made, or before the
    /// look at this Mac has answered.
    static func editorToSave(picked: String?, saved: String?, found: [EditorChoice]?) -> String? {
        if let picked { return picked }
        if let saved, Editors.ids.contains(saved) { return nil }
        guard let found else { return nil }
        return shownEditor(picked: nil, saved: nil, found: found)
    }

    /// How long page three is up before Download Now takes Return.
    static let armAfter: Duration = .milliseconds(300)

    /// A repeat of Return, or of the keypad's Enter, in a sheet.
    static func isHeldReturn(_ e: NSEvent) -> Bool {
        e.isARepeat && (e.keyCode == 36 || e.keyCode == 76) && e.window?.sheetParent != nil
    }

    /// PhotoLab, when it is the only editor found and the one shown chosen:
    /// a Mac with only PhotoLab, where he had chosen Lightroom in Settings,
    /// said "Keepers open in DxO PhotoLab" over his Lightroom.
    private var onlyPhotoLab: EditorChoice? {
        editorsFound.count == 1 && editorsFound[0].id == "dxo" && chosenEditor == "dxo"
            ? editorsFound[0] : nil
    }

    private func row(_ symbol: String, _ title: String, _ line: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(line).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.title2)
                .frame(width: 28)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
    }

    // MARK: moving through it

    /// The dots are drawn over the footer's centre rather than between two
    /// spacers: the sides change width from page to page — Back appears,
    /// Continue becomes Start — and the dots sat 23 pt left of centre on one
    /// page and 50 on the next. Skip is Esc, as a dismissible sheet's way
    /// out should be; on the last page, where it would do what Start does,
    /// it is not drawn and takes no click, but its place and its Esc are
    /// kept. It was only made transparent, so the empty corner of the footer
    /// was a button that finished the sheet. While the engine takes the
    /// folder from page two it waits with Back and Continue: Skip then
    /// started a second restart of the same folder.
    private var footer: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            let last = page == Self.pages - 1
            Button(Strings.FirstRun.skip) { done() }
                .buttonStyle(.link)
                .keyboardShortcut(.cancelAction)
                .disabled(taking)
                .opacity(last ? 0 : 1)
                .allowsHitTesting(!last)
                .accessibilityHidden(last)
                .accessibilityIdentifier("firstRun.skip")
            Spacer(minLength: Tokens.Metric.groupGap)
            // Continue waits while the engine takes the folder - a second or
            // two cold - and the spinner beside it says why it is dead.
            if taking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Strings.FirstRun.takingFolder)
                    .help(Strings.FirstRun.takingFolder)
            }
            if page > 0 {
                Button(Strings.FirstRun.back) { page -= 1 }
                    .disabled(taking)
            }
            continueButton
        }
        .overlay { Dots(page: page, of: Self.pages) }
        .padding(.horizontal, Tokens.Metric.windowMargin)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var continueButton: some View {
        let b = Button(page == Self.pages - 1 ? Strings.FirstRun.start : Strings.FirstRun.continueOn) {
            advance()
        }
        .disabled(taking)
        .accessibilityIdentifier("firstRun.continue")
        if offeringTheModel {
            b
        } else {
            b.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    /// Leaving page two hands the folder he chose to the engine, and page
    /// three is shown once the engine is on it. Handed over at Start, it
    /// came after page three's Download Now, so the restart asked about
    /// stopping the model's download on his way out of the welcome, and the
    /// fetch he had just started was for the engine about to be replaced.
    private func advance() {
        if page == 1, let folder = handOver {
            taking = true
            Task {
                let outcome = await restarter.restart(pointingAt: folder)
                taking = false
                // Cancel, in the question a job of his would raise, keeps
                // him on the page where he chose the folder.
                guard outcome != .cancelled else { return }
                adopted = folder
                page += 1
            }
        } else if page < Self.pages - 1 {
            page += 1
        } else {
            done()
        }
    }

    private var handOver: URL? { Self.handOver(chosen: folder, adopted: adopted) }

    /// The folder he chose, when the engine has not been handed it yet:
    /// once per folder, however many times he goes Back and on again.
    static func handOver(chosen: URL?, adopted: URL?) -> URL? {
        guard let chosen else { return nil }
        if let adopted, EngineRestart.same(adopted, chosen) { return nil }
        return chosen
    }

    private func done() {
        // Skip before page three: the folder has not been handed over yet.
        // Never a second time while the first hand-over is still under way.
        if !taking, let folder = handOver {
            Task { [restarter] in await restarter.restart(pointingAt: folder) }
        }
        if let e = Self.editorToSave(picked: editor, saved: settings.editor, found: editorsLooked) {
            settings.editor = e
        }
        settings.firstRunDone = true
        finish()
    }

    /// The one look at the disk, and only at the folders the caller named.
    ///
    /// It runs **off the main actor**: listing a directory is blocking I/O,
    /// and a page's body must never do it. What it finds is held in state, so
    /// the pages read an answer rather than asking the disk again on every
    /// layout pass. Whether the picture model is here is not looked for on
    /// the disk at all: it is the engine's answer, through `picture`.
    private func look() async {
        let w = world
        let seen = await Task.detached(priority: .userInitiated) {
            (library: w.existingLibrary(), editors: w.editors())
        }.value
        if folder == nil, let found = seen.library {
            folder = found.url
            foundShoots = found.shoots
        }
        editorsLooked = seen.editors
    }

    /// The one picker Settings and the empty sidebar use, so the three agree.
    private func choose() {
        switch LibraryFolderPicker.pick(startingAt: folder ?? world.defaultLibrary,
                                        prompt: Strings.FirstRun.chooseFolder) {
        case .cancelled:
            return
        case .chose(let r):
            // Either folder is a right answer, and the page says which one it
            // settled on and what it found there. Blanking the count and
            // saying "shoots will be made inside it" over a folder with seven
            // of them in it is how a first run taught him the wrong folder was
            // the right one.
            refused = nil
            folder = r.root
            foundShoots = r.shoots.count
        case .empty(let root):
            refused = nil
            folder = root
            foundShoots = 0
        case .noShoots(let url):
            refused = url
        }
    }
}

/// The app's own icon, when there is one to draw.
struct EditorIcon: View {
    let url: URL?
    var reserve = false
    var body: some View {
        if let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        } else if reserve {
            Color.clear.frame(width: 20, height: 20).accessibilityHidden(true)
        }
    }
}

/// Where he is, without a number in the way. VoiceOver gets the number.
struct Dots: View {
    let page: Int
    let of: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<of, id: \.self) { i in
                Circle()
                    .fill(i == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Strings.FirstRun.page(page + 1, of: of))
    }
}

extension URL {
    /// `~/photos` rather than `/Users/someone/photos`: his home is not
    /// something a screen has to show back to him.
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

// MARK: - what the app itself looks at

extension FirstRunSheet.World {
    /// The real one. It looks at exactly two things: the folder named here,
    /// and the applications installed — what LaunchServices knows, and the
    /// names in the Applications folders.
    ///
    /// `libraryCandidate` is passed in rather than written here so that
    /// nothing but the app itself ever points this at a real library. The
    /// editors are a question, not an answer: asked in the sheet's one look,
    /// off the main actor, where a list made here was LaunchServices and
    /// three folder listings on the main thread as the sheet was built.
    public static func real(libraryCandidate: URL,
                            editors: @escaping @Sendable () -> [FirstRunSheet.EditorChoice] = { defaultEditors() }) -> Self {
        FirstRunSheet.World(
            // The same rule the Settings control and the engine use, so the
            // count on this page is the count in the sidebar a minute later.
            // Counting the names in `shoots/` instead meant an empty folder in
            // there — `shoots/shoots`, which the studio used to make itself —
            // was counted as a shoot on the one screen whose whole job is to
            // say what is already on his disk.
            existingLibrary: {
                guard let r = LibraryFolder.resolve(libraryCandidate) else { return nil }
                return (r.root, r.shoots.count)
            },
            editors: editors,
            defaultLibrary: libraryCandidate)
    }

    /// The editors this app can write for, found by the one lookup the
    /// Presets step uses (`Editors.find`), so this page and every shoot's
    /// Presets page cannot disagree about what is installed. It had a list of
    /// its own that stopped at PhotoLab 8 and said "No editor found" on a Mac
    /// with 10, and it offered Capture One, which nothing writes for: a choice
    /// the next page would quietly ignore.
    public static func defaultEditors() -> [FirstRunSheet.EditorChoice] {
        Editors.ids.compactMap { id in
            guard let url = Editors.find(id) else { return nil }
            return FirstRunSheet.EditorChoice(id: id, name: editorName(url, id: id), url: url)
        }
    }

    /// The editor's name as the Finder and the Dock show it. PhotoLab 10's
    /// bundle gives its display name as "DXOPhotoLab10" and keeps "DxO
    /// PhotoLab 10" for its localised one, so reading the bundle's key put
    /// "Keepers open in DXOPhotoLab10." on the page.
    static func editorName(_ url: URL, id: String) -> String {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name.isEmpty ? Editors.name(id) : name
    }
}
