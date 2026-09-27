import Foundation
import CoreGraphics

/// Coordinates for a bidirectional insertion. Native code must freshly hit-test
/// both exact endpoints before posting events; geometry alone grants no access.
public struct MenuBarMoveGeometry: Equatable, Sendable {
    public let source: CGPoint
    public let destination: CGPoint
    public let corridor: CGRect

    /// Geometry eligibility only: native code must freshly validate its AX frame.
    /// Unknown, inaccessible third-party and off-row items remain barriers.
    public func canCrossSystemItem(frame: CGRect, bundleID: String?) -> Bool {
        guard bundleID?.hasPrefix("com.apple.") == true,
              [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }),
              frame.width > 0, frame.height > 0,
              abs(frame.midY - source.y) <= 1,
              frame.minX > min(destination.x, source.x), frame.maxX < max(destination.x, source.x) else { return false }
        return true
    }

    public init?(sourceFrame: CGRect, targetFrame: CGRect, placement: ItemMovePlacement = .before) {
        func valid(_ frame: CGRect) -> Bool {
            [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
             frame.maxX, frame.maxY].allSatisfy { $0.isFinite && abs($0) < 1_000_000 } &&
                frame.size.width > 0 && frame.size.height > 0
        }
        guard valid(sourceFrame), valid(targetFrame),
              sourceFrame.midX != targetFrame.midX,
              abs(sourceFrame.midY - targetFrame.midY) <= 1 else { return nil }
        source = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        let fraction: CGFloat = placement == .before ? 0.25 : 0.75
        destination = CGPoint(x: targetFrame.minX + targetFrame.width * fraction, y: targetFrame.midY)
        let row = sourceFrame.union(targetFrame)
        corridor = CGRect(x: min(destination.x, source.x) - 1, y: row.minY,
                          width: abs(source.x - destination.x) + 2, height: row.height)
    }
}
