import AppKit

@MainActor
enum MenuBarControlIcon {
    static let collapsed = makeImage(filled: true)
    static let expanded = makeImage(filled: false)

    private static func makeImage(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { _ in
            NSColor.black.set()
            for index in 0..<3 {
                let bounds = NSRect(x: CGFloat(index) * 7, y: 6.5, width: 5, height: 5)
                if filled {
                    NSBezierPath(ovalIn: bounds).fill()
                } else {
                    // Inset the stroke so both states have the same outer diameter.
                    let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.625, dy: 0.625))
                    ring.lineWidth = 1.25
                    ring.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
