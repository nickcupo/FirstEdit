import SwiftUI

/// §2.11 Storage — the retention lock, and the default for new shoots.
///
/// Nothing on this tab deletes anything, and nothing on it schedules a
/// deletion. The sentence under the lock says so, because a number that looks
/// like a timer is a number he would read as one. Nothing on it copies
/// anything either: "Copy new shoots to iCloud" is gone, since nothing read
/// it, and a copy up is his press of Copy the RAWs to iCloud, which works the
/// night of the shoot (§2.8).
///
/// The number is the library's, on the engine (`EngineSettings`): the one a
/// shoot's Storage panel sets with "Use as default" and shows for a shoot with
/// none of its own. This tab had a number of its own that nothing read.
struct StorageTab: View {
    let settings: SettingsStore
    @State private var engine: EngineSettings

    /// What the field shows: the engine's number once it has said it.
    @State private var days: Int?

    init(settings: SettingsStore, engine: EngineSettings = .shared) {
        self.settings = settings
        _engine = State(initialValue: engine)
        _days = State(initialValue: engine.retainDays)
    }

    var body: some View {
        Form {
            Section {
                // One row on one baseline: as a LabeledContent the label sat a
                // few points above the number in the field beside it.
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
                    Text(Strings.Settings.retentionDays)
                    Spacer(minLength: Tokens.Metric.groupGap)
                    // The field's empty label took the width its frame asked
                    // for inside the form, and the field drew 38 pt wide, too
                    // narrow for the largest number it takes. Hidden, it is 70.
                    TextField("", value: $days, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(width: 70)
                        // Until the engine has said its number there is none
                        // to change: a guess here would be a second number.
                        .disabled(engine.retainDays == nil)
                        .accessibilityLabel(Strings.Settings.retentionDays)
                        .accessibilityIdentifier("settings.retentionDays")
                        .onChange(of: days) { _, v in
                            guard let v, v != engine.retainDays else { return }
                            Task { await engine.setRetainDays(max(0, min(36500, v))) }
                        }
                    // The unit, not the number again: the field already
                    // says 365, and "365 [365] 365 days" said it twice.
                    Text(Strings.Storage.daysWord(days ?? engine.retainDays ?? 365)).foregroundStyle(.secondary)
                }
                if let r = engine.refusal {
                    RefusalRow(r, owner: .storage)
                }
                Text(Strings.Settings.retentionIsALock)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .task {
                await engine.load()
                days = engine.retainDays
            }
            .onChange(of: engine.retainDays) { _, v in days = v }
        }
        .formStyle(.grouped)
    }
}
