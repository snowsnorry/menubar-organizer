import AppKit
import SwiftUI
import OrganizerCore

struct SettingsInspector: View {
    let item: RegistryItem
    let icon: NSImage?
    let canEdit: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let changeGroup: (ItemGroup) -> Void
    let moveEarlier: () -> Void
    let moveLater: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    ApplicationIcon(image: icon, size: 62)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.displayName)
                            .font(.system(size: 19, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text(item.entry.bundleID.hasPrefix("com.apple.") ? "inspector.system" : "inspector.application"))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 3)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("inspector.visibility")).font(.headline)
                    Picker(L10n.text("inspector.visibility"), selection: Binding(get: { item.entry.group }, set: { group in changeGroup(group) })) {
                        Text(L10n.text("group.visible")).tag(ItemGroup.visible)
                        Text(L10n.text("group.hidden")).tag(ItemGroup.hidden)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(!canEdit)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("inspector.order")).font(.headline)
                    HStack(spacing: 8) {
                        orderButton("chevron.up", label: "action.moveEarlier", enabled: canMoveEarlier, action: moveEarlier)
                        orderButton("chevron.down", label: "action.moveLater", enabled: canMoveLater, action: moveLater)
                    }
                }
                Text(L10n.text(item.entry.bundleID == ItemRegistry.organizerBundleID ? "inspector.organizer" :
                    item.id == ItemRegistry.timeMachinePositionID ? "inspector.timeMachine" : item.entry.bundleID.hasPrefix("com.apple.")
                    ? (item.canSetVisibility
                       ? (item.canReorder ? "inspector.systemEditable" : "inspector.systemHideable")
                       : item.canReorder ? "inspector.systemReorderable" : "inspector.systemReadOnly")
                    : "availability.\(item.availability.rawValue)"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inspector.availability")
                if item.linkedIconCount > 1 {
                    Text(L10n.text("inspector.linked"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if item.id.hasPrefix("app:") {
                    Text(L10n.text("inspector.applicationIdentity"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.entry.bundleID.hasPrefix("com.apple.") && item.entry.bundleID != ItemRegistry.organizerBundleID {
                    Text(L10n.text("inspector.visibilityScope"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func orderButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 27, height: 24)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .help(L10n.text(label))
        .accessibilityLabel(L10n.text(label))
    }
}
