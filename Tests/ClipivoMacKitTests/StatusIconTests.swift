import AppKit
import Testing
@testable import ClipivoMacKit

@Suite("Status icon")
@MainActor
struct StatusIconTests {
    @Test func rendersAllStatesAsTemplates() throws {
        for state in [StatusIcon.State.normal, .paused, .attention] {
            let image = StatusIcon.image(state)
            #expect(image.isTemplate)
            #expect(!StatusIcon.image(state, style: .color).isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            #expect(rep.pixelsWide > 0)
        }
        if let dir = ProcessInfo.processInfo.environment["CLIPIVO_ICON_PREVIEW_DIR"] {
            for (name, state) in [("normal", StatusIcon.State.normal), ("paused", .paused), ("attention", .attention)] {
                let big = NSImage(size: NSSize(width: 144, height: 144), flipped: false) { rect in
                    NSColor.white.setFill(); rect.fill()
                    StatusIcon.image(state).draw(in: rect)
                    return true
                }
                let data = NSBitmapImageRep(data: big.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("status-\(name).png"))
            }
        }
    }
}
