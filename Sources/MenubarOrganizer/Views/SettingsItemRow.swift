import AppKit
import SwiftUI
import OrganizerCore

struct SettingsItemRow: View {
    let item: RegistryItem
    let icon: NSImage?
    let selected: Bool

    var body: some View {
        content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(L10n.text("availability.\(item.availability.rawValue)"))
        .accessibilityHint(L10n.text(item.isUnsupportedInSettings ? "inspector.unsupported" :
            item.entry.bundleID == ItemRegistry.organizerBundleID ? "inspector.organizer" : item.entry.bundleID.hasPrefix("com.apple.")
            ? (item.canSetVisibility
               ? (item.canReorder ? "inspector.systemEditable" : "inspector.systemHideable")
               : item.canReorder ? "inspector.systemReorderable" : "inspector.systemReadOnly") : "row.hint"))
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .opacity(item.canReorder || item.canSetVisibility ? 1 : 0)
                .accessibilityHidden(true)
            ApplicationIcon(image: icon, size: 24)
            Text(item.displayName)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(item.displayName)
    }
}

struct ApplicationIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
