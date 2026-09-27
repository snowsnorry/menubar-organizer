import AppKit
import SwiftUI
import OrganizerCore

struct SettingsView: View {
    @Bindable var model: SettingsModel

    private var selected: RegistryItem? { model.items.first { $0.id == model.selectedID && !$0.isPinnedSystemItem } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.accessibilityGranted {
                permissionBanner
                Divider()
            }
            HStack(spacing: 0) {
                itemList
                    .frame(minWidth: 360, maxWidth: .infinity)
                Divider()
                inspector
                    .frame(width: 282)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("settings.title"))
                    .font(.system(size: 21, weight: .semibold))
                Text(L10n.text("settings.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let status = model.statusMessage, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.status")
                }
            }
            Spacer(minLength: 0)
            if model.isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("status.applying"))
            }
            Button {
                Task { await model.refresh(retryPendingRestore: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.text("action.refresh"))
            .accessibilityLabel(L10n.text("action.refresh"))
            .disabled(model.isBusy || model.isPreview)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.text("permission.explanation"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L10n.text("permission.open")) { model.requestAccessibility() }
        }
        .padding(16)
    }

    private var itemList: some View {
        Group {
            if model.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.accessibilityGranted ? "menubar.rectangle" : "lock")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(L10n.text(model.accessibilityGranted ? "empty.title" : "permission.title"))
                        .font(.headline)
                    Text(L10n.text(model.accessibilityGranted ? "empty.description" : "permission.description"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 310)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedID) {
                    ForEach(listRows) { row in
                        switch row {
                        case .header(let group):
                            Text(L10n.format(group == .visible ? "group.visible.count" : "group.hidden.count", items(in: group).count))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, group == .hidden ? 16 : 4)
                                .padding(.bottom, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowSeparator(.hidden)
                                .selectionDisabled()
                                .moveDisabled(true)
                                .accessibilityAddTraits(.isHeader)
                        case .item(let item):
                            SettingsItemRow(item: item, icon: model.icon(for: item),
                                            selected: model.selectedID == item.id)
                                .tag(item.id)
                                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                                .listRowSeparator(.visible)
                                .moveDisabled(!canReorder(item) && !canChangeVisibility(item))
                        }
                    }
                    .onMove(perform: reorder)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(L10n.text("list.label"))
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let selected {
            SettingsInspector(item: selected,
                              icon: model.icon(for: selected),
                              canEdit: canChangeVisibility(selected),
                              canMoveEarlier: canMove(selected, offset: -1),
                              canMoveLater: canMove(selected, offset: 1),
                              changeGroup: { group in
                                  let destination = model.layoutEntries.filter { $0.group == group && $0.bundleID != selected.entry.bundleID }
                                  Task { await model.move(id: selected.id, to: group, at: destination.count,
                                                          applyPosition: false) }
                              },
                              moveEarlier: { move(selected, offset: -1) },
                              moveLater: { move(selected, offset: 1) })
        } else {
            VStack(spacing: 10) {
                Text(L10n.text("selection.title")).font(.headline)
                Text(L10n.text("selection.description"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Text(L10n.text("settings.hideAfter"))
                    Stepper(value: Binding(get: { model.hideDelay }, set: { value in
                        Task { await model.setHideDelay(value) }
                    }), in: 1...60, step: 1) {
                        Text(L10n.format("duration.seconds", Int(model.hideDelay)))
                            .monospacedDigit()
                            .frame(minWidth: 32, alignment: .trailing)
                    }
                    .fixedSize()
                    .accessibilityLabel(L10n.text("settings.hideAfter"))
                    .disabled(model.isBusy)
                }
                Divider().frame(height: 30)
                Toggle(L10n.text("settings.launchAtLogin"), isOn: Binding(get: { model.launchAtLogin }, set: { value in
                    Task { await model.setLaunchAtLogin(value) }
                }))
                .toggleStyle(.switch)
                .fixedSize()
                .disabled(model.isBusy)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.text("action.cancel")) { model.cancelSettings() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy)
                Button(L10n.text("action.ok")) {
                    Task { _ = await model.confirmSettings() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
            }
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private enum ListRow: Identifiable {
        case header(ItemGroup)
        case item(RegistryItem)

        var id: String {
            switch self {
            case .header(let group): "section-header:\(group.rawValue)"
            case .item(let item): item.id
            }
        }
    }

    private var listRows: [ListRow] {
        ItemGroup.allCases.flatMap { group in
            [.header(group)] + items(in: group).map(ListRow.item)
        }
    }

    private func items(in group: ItemGroup) -> [RegistryItem] {
        model.items.filter { $0.entry.group == group && !$0.isPinnedSystemItem }
    }

    private func canReorder(_ item: RegistryItem) -> Bool {
        !model.isBusy && (model.isPreview || model.accessibilityGranted) && item.canReorder
    }

    private func canChangeVisibility(_ item: RegistryItem) -> Bool {
        !model.isBusy && (model.isPreview || model.accessibilityGranted) && item.canSetVisibility
    }

    private func canMove(_ item: RegistryItem, offset: Int) -> Bool {
        let entries = model.layoutEntries.filter { $0.group == item.entry.group }
        guard canReorder(item),
              let index = entries.firstIndex(where: { $0.id == item.id }) else { return false }
        let destination = index + offset
        guard entries.indices.contains(destination) else { return false }
        guard model.items.first(where: { $0.id == entries[destination].id })?.canReorder == true else { return false }
        let visible = items(in: item.entry.group)
        guard let sourceRow = visible.firstIndex(where: { $0.id == item.id }),
              let targetRow = visible.firstIndex(where: { $0.id == entries[destination].id }) else { return false }
        let between = visible[min(sourceRow, targetRow)...max(sourceRow, targetRow)]
        return !between.contains { $0.entry.bundleID.hasPrefix("com.apple.") && !$0.canReorder }
    }

    private func move(_ item: RegistryItem, offset: Int) {
        let entries = model.layoutEntries.filter { $0.group == item.entry.group }
        guard canMove(item, offset: offset),
              let index = entries.firstIndex(where: { $0.id == item.id }) else { return }
        Task { await model.move(id: item.id, to: item.entry.group, at: index + offset) }
    }

    private func reorder(from sourceOffsets: IndexSet, to destinationOffset: Int) {
        let rows = listRows
        guard sourceOffsets.count == 1, let sourceOffset = sourceOffsets.first,
              rows.indices.contains(sourceOffset),
              case .item(let source) = rows[sourceOffset],
              (canReorder(source) || canChangeVisibility(source)),
              (0...rows.count).contains(destinationOffset) else { return }

        var remainingRows = rows
        remainingRows.remove(at: sourceOffset)
        // onMove supplies the original insertion index, before removal.
        let insertion = max(1, destinationOffset - (sourceOffset < destinationOffset ? 1 : 0))
        let prefix = remainingRows.prefix(insertion)
        guard let group = prefix.reversed().compactMap({ row -> ItemGroup? in
            if case .header(let group) = row { return group }
            return nil
        }).first else { return }
        guard source.entry.group != group ? canChangeVisibility(source) : canReorder(source) else { return }
        // Changing groups changes visibility; it does not move the icon past
        // the intervening system rows. Only same-group reorders need this gate.
        if source.entry.group == group {
            let crossed = rows[min(sourceOffset, destinationOffset)..<max(sourceOffset, destinationOffset)]
            guard !crossed.contains(where: { row in
                if case .item(let item) = row { return !item.canReorder && item.entry.bundleID.hasPrefix("com.apple.") }
                return false
            }) else { return }
        }

        let precedingIDs = Set(prefix.compactMap { row -> String? in
            if case .item(let item) = row { return item.id }
            return nil
        })
        let remainingEntries = model.layoutEntries.filter {
            $0.group == group && (source.entry.group == group ? $0.id != source.id : $0.bundleID != source.entry.bundleID)
        }
        let index = remainingEntries.filter { precedingIDs.contains($0.id) }.count
        Task { await model.move(id: source.id, to: group, at: index) }
    }
}
