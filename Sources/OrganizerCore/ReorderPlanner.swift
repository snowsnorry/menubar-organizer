import Foundation

public enum ItemMovePlacement: Equatable, Sendable { case before, after }

public struct ReorderMove: Equatable, Sendable {
    public let id: String
    public let targetID: String
    public let placement: ItemMovePlacement

    public init(id: String, targetID: String, placement: ItemMovePlacement) {
        self.id = id; self.targetID = targetID; self.placement = placement
    }
}

public enum ReorderPlanningError: Error, Equatable { case incompatibleIdentities }

public enum ReorderPlanner {
    /// Keeps a longest common subsequence in place. Every other item moves once,
    /// giving the minimum n-LIS insertions. Ties retain the earliest observed
    /// subsequence, making the plan deterministic without relying on Set order.
    public static func plan(from current: [String], to desired: [String]) throws -> [ReorderMove] {
        guard Set(current).count == current.count, Set(desired).count == desired.count,
              Set(current) == Set(desired) else { throw ReorderPlanningError.incompatibleIdentities }
        guard !current.isEmpty else { return [] }
        let ranks = Dictionary(uniqueKeysWithValues: desired.enumerated().map { ($0.element, $0.offset) })
        let sequence = current.map { ranks[$0]! }
        var lengths = Array(repeating: 1, count: current.count)
        var predecessors = Array<Int?>(repeating: nil, count: current.count)
        var best = 0
        for index in sequence.indices {
            for previous in 0..<index where sequence[previous] < sequence[index] {
                if lengths[previous] + 1 > lengths[index] {
                    lengths[index] = lengths[previous] + 1
                    predecessors[index] = previous
                }
            }
            if lengths[index] > lengths[best] { best = index }
        }
        var kept: Set<String> = []
        var cursor: Int? = best
        while let index = cursor {
            kept.insert(current[index])
            cursor = predecessors[index]
        }
        var moves: [ReorderMove] = []
        for index in desired.indices where !kept.contains(desired[index]) {
            if let next = desired[(index + 1)...].first(where: { kept.contains($0) }) {
                moves.append(ReorderMove(id: desired[index], targetID: next, placement: .before))
            } else {
                // A nonempty LIS guarantees a preceding kept/in-position item.
                moves.append(ReorderMove(id: desired[index], targetID: desired[index - 1], placement: .after))
            }
        }
        return moves
    }
}
