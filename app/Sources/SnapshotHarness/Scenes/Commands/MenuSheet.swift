import SwiftUI
import AppKit
import PipelineKit

// A menu, drawn from the menu AppKit was actually given.
//
// Not a screenshot: `MenuBar.install()` builds the real `NSMenu` out of
// `CommandTable`, `NSMenu.update()` runs the real `validateMenuItem`, and this
// view walks the result. So what is in the picture is what is in the bar —
// the same titles, the same key equivalents, the same greyed rows, the same
// separator above the two that delete photographs.

struct MenuSheet: View {
    let title: String
    let menu: NSMenu
    var width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            MenuBody(menu: menu, width: width)
        }
    }
}

struct MenuBody: View {
    let menu: NSMenu
    var width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.items.filter { !$0.isHidden }.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Divider().padding(.vertical, 5).padding(.horizontal, 10)
                } else {
                    MenuRow(item: item)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}

struct MenuRow: View {
    let item: NSMenuItem

    var body: some View {
        HStack(spacing: 0) {
            Text(item.state == .on ? "✓" : " ")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, alignment: .leading)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 20)
            if item.submenu != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if let keys = display(item) {
                Text(keys)
                    .font(.system(size: 13))
                    .foregroundStyle(item.isEnabled ? .secondary : .tertiary)
            }
        }
        .foregroundStyle(item.isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .padding(.horizontal, 10)
        .padding(.vertical, 2.5)
    }

    /// What AppKit itself would print on the right of the row.
    private func display(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var out = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.function) { out += "🌐" }
        if m.contains(.control) { out += "⌃" }
        if m.contains(.option) { out += "⌥" }
        if m.contains(.shift) { out += "⇧" }
        if m.contains(.command) { out += "⌘" }
        guard let scalar = item.keyEquivalent.unicodeScalars.first else { return out }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: out += "←"
        case NSRightArrowFunctionKey: out += "→"
        case NSUpArrowFunctionKey: out += "↑"
        case NSDownArrowFunctionKey: out += "↓"
        case 32: out += "Space"
        default: out += item.keyEquivalent == "-" ? "−" : item.keyEquivalent.uppercased()
        }
        return out
    }
}

/// Several menus, side by side, the way he would see them one after another.
struct MenuWall: View {
    let menus: [(String, NSMenu, CGFloat)]

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(Array(menus.enumerated()), id: \.offset) { _, m in
                MenuSheet(title: m.0, menu: m.1, width: m.2)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MenuBarBackdrop())
    }
}

/// A quiet desktop behind the sheets, so the menus read as menus and the
/// picture is about them rather than about a wallpaper.
struct MenuBarBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(nsColor: .underPageBackgroundColor).opacity(0.85),
                                Color(nsColor: .underPageBackgroundColor)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(Color.primary.opacity(0.04))
            .ignoresSafeArea()
    }
}
