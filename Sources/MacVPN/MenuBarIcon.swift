import AppKit

/// 菜单栏的隧道图标，由 macOS 根据菜单栏外观着色。
@MainActor
enum MenuBarIcon {
    static let inactive = makeImage(connected: false)
    static let connected = makeImage(connected: true)

    private static func makeImage(connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: 9, y: 16.5))
            outline.line(to: NSPoint(x: 15.5, y: 12.75))
            outline.line(to: NSPoint(x: 15.5, y: 5.25))
            outline.line(to: NSPoint(x: 9, y: 1.5))
            outline.line(to: NSPoint(x: 2.5, y: 5.25))
            outline.line(to: NSPoint(x: 2.5, y: 12.75))
            outline.close()
            outline.lineJoinStyle = .round
            outline.lineWidth = 1.6
            NSColor.black.set()
            outline.stroke()

            let signal = NSBezierPath(ovalIn: NSRect(x: 6.4, y: 6.4, width: 5.2, height: 5.2))
            if connected {
                signal.fill()
            } else {
                signal.lineWidth = 1.25
                signal.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
