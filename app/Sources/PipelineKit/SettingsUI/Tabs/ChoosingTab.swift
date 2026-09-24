import SwiftUI

/// §2.11 Choosing — the surround, the Space key, and what the light table
/// does at the end of a burst.
struct ChoosingTab: View {
    let settings: SettingsStore
    /// The surround as the rest of the app sees it, so a change from View ▸
    /// Viewer Background shows here while this tab is open.
    @State private var live: LiveSettings
    @State private var spaceWhole: Bool
    @State private var goesOn: Bool
    @State private var reasonsStrip: Bool
    @State private var openStacks: Bool
    @State private var cullMarks: Bool

    init(settings: SettingsStore) {
        self.settings = settings
        _live = State(initialValue: settings === SettingsStore.shared ? .shared : LiveSettings(store: settings))
        _spaceWhole = State(initialValue: settings.spaceShowsWholePicture)
        _goesOn = State(initialValue: settings.afterLastFrameGoesOn)
        _reasonsStrip = State(initialValue: settings.reasonsStripAfterDrop)
        _openStacks = State(initialValue: settings.openLargeStacksInCompare)
        _cullMarks = State(initialValue: settings.showCullMarks)
    }

    var body: some View {
        Form {
            Section {
                Picker(Strings.Settings.viewerBackground,
                       selection: Binding(get: { live.viewerBackground }, set: { live.setViewerBackground($0) })) {
                    Text(Strings.Settings.neutralGrey).tag(ViewerBackground.neutralGrey)
                    Text(Strings.Settings.matchSystem).tag(ViewerBackground.matchSystem)
                    Text(Strings.Settings.black).tag(ViewerBackground.black)
                }
                .accessibilityIdentifier("settings.viewerBackground")
                Text(Strings.Settings.backgroundWhy)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker(Strings.Settings.spaceKey, selection: $spaceWhole) {
                    Text(Strings.Settings.spaceWhole).tag(true)
                    Text(Strings.Settings.spaceNextBurst).tag(false)
                }
                .onChange(of: spaceWhole) { _, v in settings.spaceShowsWholePicture = v }
                Picker(Strings.Settings.afterLastFrame, selection: $goesOn) {
                    Text(Strings.Settings.stayHere).tag(false)
                    Text(Strings.Settings.goOn).tag(true)
                }
                .onChange(of: goesOn) { _, v in settings.afterLastFrameGoesOn = v }
            }
            Section {
                Toggle(Strings.Settings.reasonsStrip, isOn: $reasonsStrip)
                    .onChange(of: reasonsStrip) { _, v in settings.reasonsStripAfterDrop = v }
                Toggle(Strings.Settings.openStacksInCompare, isOn: $openStacks)
                    .onChange(of: openStacks) { _, v in settings.openLargeStacksInCompare = v }
                Toggle(Strings.Settings.showCullMarks, isOn: $cullMarks)
                    .onChange(of: cullMarks) { _, v in settings.showCullMarks = v }
            }
        }
        .formStyle(.grouped)
    }
}
