import SwiftUI

/// The library-wide Storage row in the sidebar: the whole disk, the whole
/// library, and where each shoot's photographs are.
///
/// It says what the engine says and nothing more. It has no destructive
/// action on it at all: everything that removes anything is on the shoot
/// whose photographs it would remove, so there is no way to delete from a
/// screen that is not looking at what would go.
public struct LibraryStorage: View {
    let app: AppModel
    @State private var line: LibraryLine?
    @State private var refusal: String?

    public init(app: AppModel) { self.app = app }

    /// For the harness and the tests.
    public init(app: AppModel, line: LibraryLine?) {
        self.app = app
        _line = State(initialValue: line)
    }

    public var body: some View {
        Form {
            if let refusal {
                Section { RefusalRow(refusal, owner: .storage) }
            }
            if let l = line {
                Section {
                    LabeledContent(Strings.Storage.free) { Text(l.free_text).countStyle() }
                    LabeledContent(Strings.Storage.reclaimable) {
                        Text(l.reclaimable_text).countStyle()
                    }
                    if !l.strays.isEmpty {
                        LabeledContent(Strings.Storage.strays) {
                            Text(l.strays_text).countStyle()
                        }
                        ForEach(l.strays) { s in
                            HStack {
                                Text(s.name).font(.footnote).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: Tokens.Metric.relatedGap)
                                Text(s.bytes_text).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    LabeledContent(Strings.Storage.libraryFolder) {
                        PathRow(URL(fileURLWithPath: l.root))
                    }
                }
            } else {
                Section { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            }
            shoots
        }
        .formStyle(.grouped)
        .columnForm()
        .task { await load() }
        .accessibilityIdentifier("storage.library")
    }

    @ViewBuilder private var shoots: some View {
        let rows = Self.bySize(app.library.shoots)
        Section(Strings.Storage.perShoot) {
            if rows.isEmpty {
                Text(Strings.Storage.noShoots).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    // To the panel he came here for, on Finish, brought into
                    // view: the row used to open the shoot's overview, and the
                    // panel was a sidebar click and a scroll away from there.
                    Button {
                        StorageArrival.ask(for: row.name)
                        app.navigation.selection = .step(shoot: row.name, step: "done")
                    } label: {
                        ShootStorageRow(row: row)
                    }
                    .buttonStyle(HoverRowStyle())
                    .accessibilityLabel(Self.spoken(row))
                    .accessibilityHint(Strings.Storage.openShoot)
                    .accessibilityIdentifier("storage.library.\(row.name)")
                }
            }
        }
    }

    /// Largest on this disk first, so the shoot to clear first is at the top;
    /// a shoot the engine gave no figure for keeps its place after them, in
    /// the library's own order.
    static func bySize(_ rows: [ShootRowOK]) -> [ShootRowOK] {
        rows.enumerated().sorted { a, b in
            switch (a.element.storage?.bytes_here, b.element.storage?.bytes_here) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    static func spoken(_ row: ShootRowOK) -> String {
        [row.name, row.storage?.bytes_here_text ?? "", row.storage?.phrase ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            line = try await client.get(Routes.storageLibrary())
            refusal = nil
        } catch let e as StudioError {
            refusal = e.sentence
        } catch {}
    }
}

/// One shoot on the library's Storage page: where its photographs are, what
/// it holds on this disk, the engine's phrase, and a chevron saying the row
/// goes somewhere.
struct ShootStorageRow: View {
    let row: ShootRowOK

    var body: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            StateGlyph(cells: row.storage?.cells ?? [], words: row.storage?.phrase ?? "")
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Tokens.Metric.relatedGap)
            // The engine's own figure and phrase, never one this page worked
            // out.
            if let size = row.storage?.bytes_here_text, !size.isEmpty {
                Text(size).countStyle()
            }
            Text(row.storage?.phrase ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// A plain row that shows it can be clicked: a quiet fill under the pointer,
/// a deeper one while pressed.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.05 : 0))
                }
                .padding(.horizontal, -6)
                .onHover { hovering = $0 }
        }
    }
}
