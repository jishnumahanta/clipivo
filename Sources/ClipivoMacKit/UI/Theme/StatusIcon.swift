import AppKit

/// Clipivo's menu bar icon, drawn in code as a silhouette of the app logo: a clipboard sheet with a
/// clip tab on top and two sheets fanned out behind it to the lower right. SF Symbols may not be
/// used as logos, so they are only used inside the UI.
enum StatusIcon {
    enum State { case normal, paused, attention }
    enum Style { case monochrome, color }

    static func image(_ state: State, style: Style = .monochrome) -> NSImage {
        style == .color ? colorImage(state) : templateImage(state)
    }

    /// Template image: macOS tints it to match the menu bar (light, dark, highlighted).
    private static func templateImage(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Back sheets, fanned to the lower right like the logo.
            for (dx, dy, alpha) in [(4.2, 3.4, 0.45), (2.2, 1.8, 0.7)] as [(CGFloat, CGFloat, CGFloat)] {
                let sheet = NSBezierPath(roundedRect: NSRect(x: 2.5 + dx, y: 3.2 + dy, width: 9.6, height: 11.4), xRadius: 2.2, yRadius: 2.2)
                sheet.lineWidth = 1.2
                NSColor.black.withAlphaComponent(alpha).setStroke()
                sheet.stroke()
            }

            // Erase what's behind the front sheet so the stack reads clearly.
            let front = NSRect(x: 2.5, y: 3.2, width: 9.6, height: 11.4)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -0.9, dy: -0.9), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            NSColor.black.setStroke()
            let sheet = NSBezierPath(roundedRect: front, xRadius: 2.2, yRadius: 2.2)
            sheet.lineWidth = 1.4
            sheet.stroke()

            // Clip tab across the top edge, with the logo's round hole.
            let clip = NSBezierPath(roundedRect: NSRect(x: 4.6, y: 1.4, width: 5.4, height: 3.6), xRadius: 1.4, yRadius: 1.4)
            clip.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 6.6, y: 2.2, width: 1.4, height: 1.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            switch state {
            case .normal:
                break // A blank sheet, like the logo.
            case .paused:
                NSBezierPath(roundedRect: NSRect(x: 5.0, y: 7.4, width: 1.6, height: 5.2), xRadius: 0.6, yRadius: 0.6).fill()
                NSBezierPath(roundedRect: NSRect(x: 8.0, y: 7.4, width: 1.6, height: 5.2), xRadius: 0.6, yRadius: 0.6).fill()
            case .attention:
                NSBezierPath(roundedRect: NSRect(x: 6.5, y: 6.8, width: 1.6, height: 4.4), xRadius: 0.6, yRadius: 0.6).fill()
                NSBezierPath(ovalIn: NSRect(x: 6.5, y: 12.0, width: 1.6, height: 1.6)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The full-color app logo, with a small status badge when paused or needing attention.
    private static func colorImage(_ state: State) -> NSImage {
        let logo = NSApplication.shared.applicationIconImage ?? templateImage(state)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // The icon artwork has a transparent margin; scale up slightly so it fills the menu bar slot.
            logo.draw(in: rect.insetBy(dx: -1.5, dy: -1.5), from: .zero, operation: .sourceOver, fraction: state == .paused ? 0.45 : 1)
            if state != .normal {
                let badge = NSRect(x: 11.5, y: 0.5, width: 6.5, height: 6.5)
                (state == .paused ? NSColor.systemGray : NSColor.systemOrange).setFill()
                NSBezierPath(ovalIn: badge).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
