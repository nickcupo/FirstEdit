import Synchronization
import SwiftUI

/// A refusal, where the action was taken.
///
/// One plain sentence under the control that raised it, in the alarm colour,
/// with a Details disclosure for the technical text. Never a system alert,
/// never a global banner, never a traceback (DESIGN.md principle 8). It is
/// tagged with its owner, and only that owner clears it.
public struct RefusalRow: View {
    public let message: String
    public let owner: RefusalOwner
    public let detail: String?
    @State private var showDetail = false

    public init(_ message: String, owner: RefusalOwner) {
        self.init(message, owner: owner, detail: nil)
    }

    public init(_ message: String, owner: RefusalOwner, detail: String?) {
        self.message = message
        self.owner = owner
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Label {
                Text(message.asSentence)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: Symbols.refusal)
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.callout)
            .foregroundStyle(Tokens.Palette.alarm)

            if let detail, !detail.isEmpty {
                DisclosureGroup(Strings.Shell.details, isExpanded: $showDetail) {
                    Text(detail)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("refusal.\(owner.id)")
    }
}

extension String {
    /// The engine's words as a sentence he reads: first letter up, a full
    /// stop at the end. The engine answers in fragments — "cull the shoot
    /// first", "a job is already running" — which read as a log, not as
    /// something said to him.
    ///
    /// A first word that is a name is left exactly as written: anything with
    /// a digit, a dot, a dash or a slash in it (a dated shoot, a file, a
    /// path); a word with a capital after its first letter (iCloud, macOS,
    /// which read "ICloud"); and the name of a shoot in his library
    /// (`ShootNames`), so "lounge already exists", about the shoot he called lounge
    /// on the card page, does not read "Lounge already exists." A sentence that
    /// already ends is not given a second ending.
    public var asSentence: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        let firstWord = String(trimmed.prefix { !$0.isWhitespace })
        let isAName = firstWord.contains { !$0.isLetter }
            || firstWord.dropFirst().contains { $0.isUppercase }
            || ShootNames.contains(firstWord.trimmingCharacters(in: .punctuationCharacters))
        var out = isAName ? trimmed : trimmed.capitalizedFirst
        if !".!?…:)\"”'".contains(last) { out += "." }
        return out
    }
}

/// The names of the shoots in the library as last read, so a sentence that
/// starts with one keeps it as he typed it. Written by `Library` whenever it
/// reads the list; read by `String.asSentence` from any view.
public enum ShootNames {
    private static let names = Mutex<Set<String>>([])

    public static func contains(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return names.withLock { $0.contains(word) }
    }

    static func set(_ new: some Sequence<String>) {
        let s = Set(new)
        names.withLock { $0 = s }
    }
}

extension RefusalBoard {
    /// The row for one owner, or nothing.
    @MainActor @ViewBuilder
    public func row(_ owner: RefusalOwner) -> some View {
        if let m = self[owner] { RefusalRow(m, owner: owner) }
    }
}
