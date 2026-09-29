import Foundation
import Testing
import Darwin
@testable import ClipivoCore

/// Large-history tests. 10k and 50k always run; 100k+ runs with `CLIPIVO_STRESS=1`
/// (`CLIPIVO_STRESS=1 swift test -c release --filter Stress`).
@Suite("Stress", .serialized)
struct StressTests {
    static let words = ["supabase", "deploy", "invoice", "kubernetes", "migration", "swift", "react", "client", "design",
                        "meeting", "budget", "roadmap", "screenshot", "python", "docker", "release", "analytics", "notes"]

    static func makeClip(_ i: Int) -> PreparedClip {
        var rng = SplitMix(seed: UInt64(i))
        let count = 6 + Int(rng.next() % 30)
        let text = (0..<count).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ") + " #\(i)"
        let app = ["com.google.Chrome", "com.microsoft.VSCode", "com.apple.Safari", "com.apple.Notes", "com.tinyspeck.slackmacgap"][i % 5]
        return PreparedClip(kind: i % 7 == 0 ? .code : .text, autoTitle: nil, metadata: .empty, searchableText: text, plainText: text,
                            representations: [ClipRepresentation(type: RepresentationType.plainText, data: Data(text.utf8))],
                            contentHash: "stress-\(i)", sourceApp: SourceApplication(bundleID: app, name: app),
                            createdAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(i) * 60))
    }

    static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    func populate(_ library: ClipLibrary, count: Int) async throws {
        var start = 0
        while start < count {
            let end = min(start + 2_000, count)
            try await library.storeBatch((start..<end).map(Self.makeClip))
            start = end
        }
    }

    func measure(_ body: () async throws -> Void) async rethrows -> Double {
        let start = Date()
        try await body()
        return Date().timeIntervalSince(start) * 1000
    }

    func runScenario(count: Int, searchBudgetMS: Double) async throws {
        let t = try TemporaryLibrary()
        let memoryBefore = Self.residentMemoryMB()
        let insertMS = try await measure { try await populate(t.library, count: count) }
        #expect(try await t.library.totalCount() == count)

        var timings: [String: Double] = [:]
        timings["first page"] = try await measure { _ = try await t.library.fetch(ClipQuery(limit: 100)) }
        timings["deep page"] = try await measure { _ = try await t.library.fetch(ClipQuery(limit: 100, offset: count / 2)) }
        for term in ["supabase", "pabas", "deploy invoice", "kubernetes migration swift", "#12", "zzzz-no-match"] {
            timings["search \(term)"] = try await measure { _ = try await t.library.fetch(ClipQuery(text: term, limit: 100)) }
        }
        timings["filter app"] = try await measure { _ = try await t.library.fetch(ClipQuery(text: "app:vscode", limit: 100)) }
        timings["filter type"] = try await measure { _ = try await t.library.fetch(ClipQuery(kinds: [.code], limit: 100)) }
        timings["count"] = try await measure { _ = try await t.library.count(ClipQuery(text: "supabase")) }
        timings["source apps"] = try await measure { _ = try await t.library.sourceApps() }

        let found = try await t.library.fetch(ClipQuery(text: "#\(count - 1)", limit: 5))
        #expect(found.contains { $0.previewText.hasSuffix("#\(count - 1)") })

        let memoryAfter = Self.residentMemoryMB()
        print("[stress \(count)] insert \(Int(insertMS)) ms, memory +\(Int(memoryAfter - memoryBefore)) MB")
        for (name, ms) in timings.sorted(by: { $0.key < $1.key }) { print("[stress \(count)]   \(name): \(String(format: "%.1f", ms)) ms") }

        for (name, ms) in timings where name != "count" && name != "source apps" {
            #expect(ms < searchBudgetMS, "\(name) took \(ms) ms with \(count) clips")
        }
        // The library never materialises the whole history in memory.
        #expect(memoryAfter - memoryBefore < 300, "memory grew \(memoryAfter - memoryBefore) MB")
    }

    @Test func tenThousandClips() async throws {
        try await runScenario(count: 10_000, searchBudgetMS: 250)
    }

    @Test func fiftyThousandClips() async throws {
        try await runScenario(count: 50_000, searchBudgetMS: 500)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPIVO_STRESS"] == "1"))
    func hundredThousandClips() async throws {
        try await runScenario(count: 100_000, searchBudgetMS: 600)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPIVO_STRESS"] == "1"))
    func fiveHundredThousandMetadataRecords() async throws {
        try await runScenario(count: 500_000, searchBudgetMS: 2_000)
    }

    @Test func largeImagesAndPayloads() async throws {
        let t = try TemporaryLibrary()
        let big = largePayload(40 * 1024 * 1024) // 40 MB image-sized payload
        let id = try #require(t.storedID(try await t.processor.process(.single([RepresentationType.png: big]), policy: .testDefault)))
        let content = try await t.library.content(id: id)
        #expect(content.data(for: RepresentationType.png)?.count == big.count)
        let hugeText = String(repeating: "log line with supabase token-free content\n", count: 250_000) // ~10 MB
        let textID = try #require(t.storedID(try await t.capture(hugeText)))
        let summary = try #require(try await t.library.summary(id: textID))
        #expect(summary.previewText.count <= ClipLibrary.previewLength)
        #expect(try await t.library.fullPlainText(textID)?.count == hugeText.count)
        #expect(try await t.library.fetch(ClipQuery(text: "supabase")).contains { $0.id == textID })
    }
}

/// Deterministic PRNG so stress data is reproducible.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
