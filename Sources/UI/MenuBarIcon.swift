import AppKit

/// Menu bar status item glyphs drawn on an 18 × 18 pt grid as template images,
/// so macOS tints them for light, dark and highlighted menu bars.
public enum MenuBarIcon {
    @MainActor public static let locked: NSImage = makeImage(accessibilityDescription: L("KeeMac, locked"), draw: drawLocked)
    @MainActor public static let unlocked: NSImage = makeImage(accessibilityDescription: L("KeeMac, unlocked"), draw: drawUnlocked)

    private static func makeImage(accessibilityDescription: String, draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func drawLocked() {
        drawFrame()

        NSBezierPath(roundedRect: NSRect(x: 5.2, y: 4.2, width: 7.6, height: 12.4), xRadius: 1.2, yRadius: 1.2).fill()

        // Handle plate and lever are cut out of the door.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(roundedRect: NSRect(x: 10.0, y: 8.2, width: 1.5, height: 4.6), xRadius: 0.75, yRadius: 0.75).fill()
        NSBezierPath(roundedRect: NSRect(x: 7.6, y: 8.6, width: 3.9, height: 1.3), xRadius: 0.65, yRadius: 0.65).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    private static func drawUnlocked() {
        drawFrame()

        let door = polygon([(5.2, 3.6), (10.6, 5.0), (10.6, 15.4), (5.2, 16.6)])
        door.append(NSBezierPath(roundedRect: NSRect(x: 8.6, y: 8.8, width: 1.0, height: 2.6), xRadius: 0.5, yRadius: 0.5))
        door.windingRule = .evenOdd
        door.fill()
    }

    /// Door frame: an arch open at the bottom.
    private static func drawFrame() {
        let radius: CGFloat = 2.2
        let frame = NSBezierPath()
        frame.move(to: NSPoint(x: 3.2, y: 16.6))
        frame.line(to: NSPoint(x: 3.2, y: 2.2 + radius))
        appendArc(to: frame, center: NSPoint(x: 3.2 + radius, y: 2.2 + radius), radius: radius, from: 180, to: 90)
        frame.line(to: NSPoint(x: 14.8 - radius, y: 2.2))
        appendArc(to: frame, center: NSPoint(x: 14.8 - radius, y: 2.2 + radius), radius: radius, from: 90, to: 0)
        frame.line(to: NSPoint(x: 14.8, y: 16.6))
        frame.lineWidth = 1.5
        frame.lineJoinStyle = .round
        frame.stroke()
    }

    /// Appends an arc in a flipped (y-down) context; angles are measured counter-clockwise from +x as seen on screen.
    private static func appendArc(to path: NSBezierPath, center: NSPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) {
        let steps = 24
        for step in 1...steps {
            let angle = (start + (end - start) * CGFloat(step) / CGFloat(steps)) * .pi / 180
            path.line(to: NSPoint(x: center.x + radius * cos(angle), y: center.y - radius * sin(angle)))
        }
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: point.0, y: point.1))
        }
        path.close()
        return path
    }
}
