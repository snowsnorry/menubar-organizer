import Foundation

/// Editing state has no persistence or system effects. Only an explicit commit
/// publishes its value; cancellation always returns the last accepted document.
public struct LayoutDraft: Equatable, Sendable {
    public private(set) var committed: LayoutDocument
    public var value: LayoutDocument
    public var hasChanges: Bool { value != committed }

    public init(_ document: LayoutDocument = LayoutDocument()) {
        committed = document
        value = document
    }

    public mutating func accept(_ document: LayoutDocument) {
        committed = document
        value = document
    }

    public mutating func updateCommitted(_ document: LayoutDocument, preservingChanges: Bool) {
        committed = document
        if !preservingChanges {
            value = document
        } else {
            for (offset, discovered) in document.entries.enumerated() where !value.entries.contains(where: { $0.id == discovered.id }) {
                var entry = discovered
                // New icons of an edited app follow that app's draft visibility.
                if let sibling = value.entries.first(where: { $0.bundleID == entry.bundleID }) {
                    entry.group = sibling.group
                }
                let earlier = document.entries[..<offset].reversed().first { candidate in
                    value.entries.contains { $0.id == candidate.id && $0.group == entry.group }
                }
                let later = document.entries.dropFirst(offset + 1).first { candidate in
                    value.entries.contains { $0.id == candidate.id && $0.group == entry.group }
                }
                let index: Int
                if let earlier, let anchor = value.entries.firstIndex(where: { $0.id == earlier.id }) {
                    index = anchor + 1
                } else if let later, let anchor = value.entries.firstIndex(where: { $0.id == later.id }) {
                    index = anchor
                } else if entry.group == .visible {
                    index = value.entries.firstIndex(where: { $0.group == .hidden }) ?? value.entries.count
                } else {
                    index = value.entries.count
                }
                value.entries.insert(entry, at: index)
            }
        }
    }

    public mutating func cancel() { value = committed }
}
