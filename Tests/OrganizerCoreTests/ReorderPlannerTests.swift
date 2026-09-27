import XCTest
@testable import OrganizerCore

final class ReorderPlannerTests: XCTestCase {
    private func applying(_ moves: [ReorderMove], to input: [String]) throws -> [String] {
        var result = input
        for move in moves {
            XCTAssertNotEqual(move.id, move.targetID)
            let source = try XCTUnwrap(result.firstIndex(of: move.id))
            result.remove(at: source)
            let target = try XCTUnwrap(result.firstIndex(of: move.targetID))
            result.insert(move.id, at: target + (move.placement == .after ? 1 : 0))
        }
        return result
    }

    private func permutations(_ values: [String]) -> [[String]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index -> [[String]] in
            var remaining = values
            let first = remaining.remove(at: index)
            return permutations(remaining).map { [first] + $0 }
        }
    }

    // Independent common-subsequence DP supplies the insertion lower bound.
    private func longestCommonSubsequence(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for value in lhs {
            var next = previous
            for (index, other) in rhs.enumerated() {
                next[index + 1] = value == other ? previous[index] + 1 : max(previous[index + 1], next[index])
            }
            previous = next
        }
        return previous.last!
    }

    func testExhaustivePermutationsThroughSixItemsReachDesiredOrderWithMinimumMoves() throws {
        for count in 0...6 {
            let desired = (0..<count).map(String.init)
            for current in permutations(desired) {
                let moves = try ReorderPlanner.plan(from: current, to: desired)
                XCTAssertEqual(try applying(moves, to: current), desired, "Input: \(current)")
                XCTAssertEqual(moves.count, count - longestCommonSubsequence(current, desired))
                XCTAssertEqual(Set(moves.map(\.id)).count, moves.count)
                XCTAssertEqual(try ReorderPlanner.plan(from: current, to: desired), moves)
            }
        }
    }

    func testFirstToLastRotationMovesOnlyFirstItemAfterLast() throws {
        XCTAssertEqual(try ReorderPlanner.plan(from: ["a", "b", "c", "d"], to: ["b", "c", "d", "a"]),
                       [ReorderMove(id: "a", targetID: "d", placement: .after)])
    }

    func testLastToFirstRotationMovesOnlyLastItemBeforeFirst() throws {
        XCTAssertEqual(try ReorderPlanner.plan(from: ["a", "b", "c", "d"], to: ["d", "a", "b", "c"]),
                       [ReorderMove(id: "d", targetID: "a", placement: .before)])
    }

    func testRejectsMissingExtraAndDuplicateIdentities() {
        for (current, desired) in [(["a"], ["b"]), (["a"], ["a", "b"]),
                                   (["a", "a"], ["a", "a"]), (["a", "b"], ["a", "a"])] {
            XCTAssertThrowsError(try ReorderPlanner.plan(from: current, to: desired))
        }
    }
}
