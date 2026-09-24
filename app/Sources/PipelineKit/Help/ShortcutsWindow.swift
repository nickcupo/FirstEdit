import SwiftUI
import AppKit

// Help ▸ Keyboard Shortcuts (⌘/, and `?` from the light table).
//
// A real window, not a modal: he can leave it open on the second screen and
// keep culling. It is built from `CommandTable` through `ShortcutsCatalog`,
// so it cannot drift from the menus or from the keys under his hand.

public struct ShortcutsView: View {
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    public init() {}

    private var groups: [(ShortcutGroup, [ShortcutRow])] {
        ShortcutsCatalog.grouped(matching: query)
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if groups.isEmpty {
                ContentUnavailableView {
                    Label(Words.Shortcuts.nothingFound, systemImage: "magnifyingglass")
                } description: {
                    Text(Words.Shortcuts.tryAnother)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        // Esc clears the search, and with nothing typed closes the window, so
        // a look opened with ? costs one key to put away, not ⌘W or a click.
        .background {
            Button("") { escape() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear { searchFocused = true }
    }

    private func escape() {
        if query.isEmpty {
            ShortcutsWindow.close()
        } else {
            query = ""
        }
    }

    private var searchBar: some View {
        HStack(spacing: Tokens.Metric.groupGap) {
            Text(Words.Shortcuts.title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Tokens.Metric.groupGap)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(Words.Shortcuts.search, text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel(Words.Shortcuts.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Words.Shortcuts.search)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .frame(width: 220)
        }
        .padding(.horizontal, Tokens.Metric.windowMargin)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var list: some View {
        List {
            ForEach(groups, id: \.0) { group, rows in
                Section {
                    ForEach(rows) { row in
                        ShortcutRowView(row: row)
                            .listRowInsets(EdgeInsets(top: 3, leading: Tokens.Metric.relatedGap,
                                                      bottom: 3, trailing: Tokens.Metric.relatedGap))
                    }
                } header: {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .environment(\.defaultMinListRowHeight, 22)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Words.Shortcuts.footer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Tokens.Metric.groupGap)
            Button(Words.Shortcuts.print) { ShortcutsPrinter.print(groups: groups) }
                .accessibilityLabel(Words.Shortcuts.print)
        }
        .padding(.horizontal, Tokens.Metric.windowMargin)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

struct ShortcutRowView: View {
    let row: ShortcutRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            Text(row.title)
                .font(.body)
                .lineLimit(1)
            ContrastReader { increased in
                // Under Increase Contrast the quietest text in the window is
                // the first thing that has to come forward.
                Text(row.menu)
                    .font(.footnote)
                    .foregroundStyle(increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: Tokens.Metric.relatedGap)
            if let keys = row.keys {
                if let alternate = row.alternate {
                    Text(alternate)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                KeyCap(text: keys)
            } else {
                // The key column is left blank, but its slot is kept, so a
                // row with no key is as tall as the rows around it rather
                // than a run of them closing up under Viewer Background.
                ZStack(alignment: .trailing) {
                    KeyCap(text: " ").hidden()
                    if let note = row.note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.menu)")
        .accessibilityValue(row.keys ?? row.note ?? "")
        .accessibilityIdentifier("shortcut.\(row.id.rawValue)")
    }
}

/// One key, drawn as a key: enough shape to scan a column of them quickly,
/// no more. It takes the system's own control colours, so it is right in both
/// appearances and thickens under Increase Contrast.
struct KeyCap: View {
    let text: String

    var body: some View {
        ContrastReader { increased in
            Text(text)
                .font(.system(.body, design: .default))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .frame(minWidth: 30)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: increased ? .controlBackgroundColor : .quaternarySystemFill))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(increased ? 0.75 : 0.16),
                                      lineWidth: increased ? 2 : 1)
                }
                .accessibilityHidden(true)
        }
    }
}

// MARK: - the window

@MainActor
public enum ShortcutsWindow {
    private static var controller: NSWindowController?

    /// Opens it, or brings the one that is already open to the front. Never a
    /// sheet and never modal: he can leave it up beside the light table.
    public static func show() {
        if let c = controller, let w = c.window {
            w.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: false)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = Words.Shortcuts.title
        // The header inside the window carries the name, so the title bar
        // does not say it twice.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: ShortcutsView())
        window.isReleasedWhenClosed = false
        // Where he left it — on the second screen, as often as not — and
        // centred only the first time. `center()` after the autosave name put
        // it back in the middle of the main screen at every launch.
        if !window.setFrameUsingName("shortcuts") { window.center() }
        window.setFrameAutosaveName("shortcuts")
        let c = NSWindowController(window: window)
        controller = c
        c.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Esc with nothing typed. Its place is remembered by the autosave name.
    static func close() {
        controller?.window?.performClose(nil)
    }

    /// For the harness and the tests: the view with no window around it.
    public static func view() -> some View { ShortcutsView() }
}

// MARK: - printing

@MainActor
enum ShortcutsPrinter {
    static func print(groups: [(ShortcutGroup, [ShortcutRow])]) {
        let page = NSPrintInfo.shared.paperSize
        let margin: CGFloat = 54
        let width = page.width - margin * 2
        let view = NSHostingView(rootView: PrintableShortcuts(groups: groups).frame(width: width))
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.fittingSize.height)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = Words.Shortcuts.title
        operation.run()
    }
}

struct PrintableShortcuts: View {
    let groups: [(ShortcutGroup, [ShortcutRow])]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            Text(Words.Shortcuts.title).font(.title)
            ForEach(groups, id: \.0) { group, rows in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.headline).padding(.top, 6)
                    ForEach(rows) { row in
                        HStack {
                            Text(row.title)
                            Spacer()
                            Text(row.keys ?? row.note ?? "")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(2)
        .environment(\.colorScheme, .light)
    }
}
