import Foundation
import Testing
@testable import ClipivoCore

@Suite struct UpdateCheckTests {
    private func json(_ releases: [(tag: String, url: String, draft: Bool)]) -> Data {
        let items = releases.map { #"{"tag_name":"\#($0.tag)","name":"Clipivo \#($0.tag)","html_url":"\#($0.url)","draft":\#($0.draft)}"# }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }
    private let page = "https://github.com/jishnumahanta/clipivo/releases/tag/"

    @Test func versionsCompareNumerically() {
        #expect(AppVersion("0.9.0")! < AppVersion("0.9.1")!)
        #expect(AppVersion("0.9.9")! < AppVersion("0.10.0")!)
        #expect(AppVersion("v1.0-beta")! == AppVersion("1.0.0")!)
        #expect(AppVersion("0.9.1-beta")! == AppVersion("0.9.1")!)
        #expect(AppVersion("1.2")! > AppVersion("1.1.9")!)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("beta") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func findsNewerRelease() throws {
        let data = json([("v0.9.1-beta", page + "v0.9.1-beta", false), ("v0.9.0-beta", page + "v0.9.0-beta", false)])
        let update = try #require(UpdateCheck.evaluate(releasesJSON: data, current: "0.9.0"))
        #expect(update.version == "0.9.1-beta")
        #expect(update.pageURL.absoluteString == page + "v0.9.1-beta")
    }

    @Test func noUpdateWhenCurrentOrOlder() {
        let data = json([("v0.9.0-beta", page + "v0.9.0-beta", false), ("v0.8.0", page + "v0.8.0", false)])
        #expect(UpdateCheck.evaluate(releasesJSON: data, current: "0.9.0") == nil)
        #expect(UpdateCheck.evaluate(releasesJSON: data, current: "1.0") == nil, "Never offers a downgrade")
    }

    @Test func ignoresDraftsAndBadTags() {
        let data = json([("v2.0", page + "v2.0", true), ("nightly", page + "nightly", false)])
        #expect(UpdateCheck.evaluate(releasesJSON: data, current: "0.9.0") == nil)
    }

    @Test func refusesUntrustedLinks() {
        for url in ["https://evil.example/clipivo.dmg", "http://github.com/jishnumahanta/clipivo/releases/tag/v9",
                    "https://github.com/someone-else/clipivo/releases/tag/v9", "https://github.com.evil.example/jishnumahanta/clipivo/releases",
                    "https://user@github.com/jishnumahanta/clipivo/releases/tag/v9", "https://github.com/jishnumahanta/clipivo-releases/x",
                    "javascript:alert(1)"] {
            #expect(UpdateCheck.evaluate(releasesJSON: json([("v9.0", url, false)]), current: "0.9.0") == nil, "\(url)")
        }
    }

    @Test func toleratesMalformedResponses() {
        for body in ["", "{}", "null", "[{\"tag_name\": 5}]", "<html>rate limited</html>", String(repeating: "[", count: 10_000)] {
            #expect(UpdateCheck.evaluate(releasesJSON: Data(body.utf8), current: "0.9.0") == nil)
        }
    }

    @Test func checksAtMostDaily() {
        let now = Date()
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "A clock set backwards doesn't block checks forever")
    }
}
