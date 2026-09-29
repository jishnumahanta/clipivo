import AppKit
import Foundation
import Testing
@testable import ClipivoCore

/// Builds a library of sample clips for README screenshots. Runs only when `CLIPIVO_DEMO_LIBRARY`
/// names an empty directory; `scripts/demo-screenshots.sh` does this and captures the screenshots.
@Suite struct DemoLibrarySeeder {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPIVO_DEMO_LIBRARY"] != nil))
    func seedDemoLibrary() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIPIVO_DEMO_LIBRARY"]!, isDirectory: true)
        let library = try ClipLibrary(layout: StorageLayout(root: root), cipher: nil)
        let processor = CaptureProcessor(library: library)
        var policy = CapturePolicy()
        policy.sensitivePolicy = .save
        let start = Date().addingTimeInterval(-3 * 3600)
        var minute = 0.0

        func app(_ id: String, _ name: String) -> SourceApplication { SourceApplication(bundleID: id, name: name) }
        @discardableResult
        func add(_ snapshot: ClipboardSnapshot, gap: Double = 11) async throws -> Int64? {
            var snapshot = snapshot
            minute += gap
            snapshot.capturedAt = start.addingTimeInterval(minute * 60)
            if case .stored(let result, _) = try await processor.process(snapshot, policy: policy) { return result.clipID }
            return nil
        }

        let tagline = try await add(.text("Your clipboard remembers.", source: app("com.apple.Notes", "Notes")))
        try await add(.text("221B Baker Street, London NW1 6XE", source: app("com.apple.Maps", "Maps")))
        try await add(.text("+1 (555) 010-2030", source: app("com.apple.MobileSMS", "Messages")))
        let brief = try await add(.text("Launch plan: ship the beta to testers on Friday, collect feedback over the weekend, and fix the top three issues before the public release.", source: app("com.apple.Notes", "Notes")))
        try await add(.single([RepresentationType.png: Self.sampleImage()], source: app("com.apple.Preview", "Preview"),
                              hints: .init(imagePixelSize: (1600, 1000))))
        try await add(.text("hello@example.com", source: app("com.apple.mail", "Mail")))
        let color = try await add(.text("#7C3AED", source: app("com.figma.Desktop", "Figma")))
        let code = try await add(.text("""
            func greet(_ name: String) -> String {
                let greeting = "Hello, \\(name)!"
                return greeting.uppercased()
            }
            """, source: app("com.apple.dt.Xcode", "Xcode")))
        let link = try await add(.text("https://developer.apple.com/documentation/vision", source: app("com.apple.Safari", "Safari")))
        try await add(.text("Remember to renew the domain before the launch announcement goes out.", source: app("com.apple.reminders", "Reminders")), gap: 4)

        if let tagline { try await library.setPinned([tagline], pinned: true); try await library.setTitle(tagline, title: "Tagline") }
        let work = try await library.createSpace(name: "Launch", icon: "paperplane")
        try await library.addClips([brief, link, color, code].compactMap { $0 }, toSpace: work.id)
        _ = try await library.createSpace(name: "Design", icon: "paintpalette")
        try await library.addIgnoredApp(IgnoredApplication(bundleID: "com.apple.keychainaccess", name: "Keychain Access"))
        try await library.addIgnoredApp(IgnoredApplication(bundleID: "com.apple.Passwords", name: "Passwords"))
    }

    /// A 1600×1000 sample "screenshot": a card with a heading and a few lines of text, so OCR has
    /// something real to read.
    static func sampleImage() -> Data {
        let size = NSSize(width: 1600, height: 1000)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedRed: 0.93, green: 0.95, blue: 1, alpha: 1).setFill()
            rect.fill()
            let card = NSRect(x: 160, y: 140, width: 1280, height: 720)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: card, xRadius: 36, yRadius: 36).fill()
            NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 240, y: 230, width: 120, height: 120), xRadius: 28, yRadius: 28).fill()
            let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 76, weight: .bold), .foregroundColor: NSColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.darkGray]
            ("Weekly review" as NSString).draw(at: NSPoint(x: 400, y: 245), withAttributes: heading)
            for (i, line) in ["Beta build ready for testers", "Search inside screenshots", "Spaces for every project"].enumerated() {
                ("•  " + line as NSString).draw(at: NSPoint(x: 250, y: 440 + CGFloat(i) * 110), withAttributes: body)
            }
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}
