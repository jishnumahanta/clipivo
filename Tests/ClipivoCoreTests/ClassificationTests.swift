import Foundation
import Testing
@testable import ClipivoCore

@Suite("Classification")
struct ClassificationTests {
    func kind(_ text: String) -> ClipKind {
        ContentClassifier.classify(.text(text)).kind
    }

    @Test func plainText() {
        #expect(kind("Remember to buy milk and eggs on the way home.") == .text)
    }

    @Test func richTextKeepsRichKind() {
        let snapshot = ClipboardSnapshot.single([
            RepresentationType.plainText: Data("Hello world, this is formatted".utf8),
            RepresentationType.rtf: Data("{\\rtf1 Hello}".utf8),
        ])
        #expect(ContentClassifier.classify(snapshot).kind == .richText)
    }

    @Test(arguments: ["https://supabase.com/docs/guides/auth", "http://localhost:3000/api", "ssh://git@github.com/org/repo"])
    func urls(_ value: String) {
        #expect(kind(value) == .url)
    }

    @Test func urlMetadata() {
        let c = ContentClassifier.classify(.text("https://www.example.com/path/page"))
        #expect(c.metadata.urlHost == "www.example.com")
        #expect(c.autoTitle == "example.com/path/page")
        #expect(c.urlString == "https://www.example.com/path/page")
    }

    @Test(arguments: ["#FF0000", "#f00", "rgb(255, 0, 0)", "rgba(255,0,0,1)", "hsl(0, 100%, 50%)"])
    func colors(_ value: String) {
        let c = ContentClassifier.classify(.text(value))
        #expect(c.kind == .color)
        #expect(c.metadata.colorHex == "#FF0000")
    }

    @Test func colorParserAlphaAndConversions() {
        let color = ColorParser.parse("rgba(0, 128, 255, 0.5)")
        #expect(color?.hex == "#0080FF80")
        #expect(ColorParser.parse("#00ff00")?.rgbString == "rgb(0, 255, 0)")
        #expect(ColorParser.parse("#ff0000")?.hslString == "hsl(0, 100%, 50%)")
        #expect(ColorParser.parse("#GGGGGG") == nil)
        #expect(ColorParser.parse("rgb(300, 0, 0)") == nil)
    }

    @Test func email() {
        #expect(kind("jane.doe@example.org") == .email)
    }

    @Test func phone() {
        #expect(kind("+91 98765 43210") == .phone)
        #expect(kind("(555) 123-4567") == .phone)
    }

    @Test func oneTimeCode() {
        #expect(kind("482913") == .otp)
        #expect(kind("2024") != .otp) // a year, not a code
    }

    @Test func address() {
        #expect(kind("1600 Amphitheatre Parkway\nMountain View, CA 94043") == .address)
        #expect(kind("221 Baker Street\nLondon NW1 6XE") == .address)
    }

    @Test func files() {
        let snapshot = ClipboardSnapshot(items: [
            [ClipRepresentation(itemIndex: 0, type: RepresentationType.fileURL, data: Data("file:///Users/me/Documents/report.pdf".utf8))],
            [ClipRepresentation(itemIndex: 1, type: RepresentationType.fileURL, data: Data("file:///Users/me/Documents/notes.txt".utf8))],
        ], sourceApp: nil)
        let c = ContentClassifier.classify(snapshot)
        #expect(c.kind == .file)
        #expect(c.metadata.fileCount == 2)
        #expect(c.autoTitle == "report.pdf and 1 more")
        #expect(c.searchableText.contains("/Users/me/Documents/notes.txt"))
    }

    @Test func folder() {
        let snapshot = ClipboardSnapshot.single([RepresentationType.fileURL: Data("file:///Users/me/Projects/".utf8)],
                                                hints: .init(directoryPaths: ["/Users/me/Projects"]))
        #expect(ContentClassifier.classify(snapshot).kind == .folder)
    }

    @Test func imageAndScreenshot() {
        let browserCopy = ClipboardSnapshot.single([RepresentationType.png: tinyPNG, RepresentationType.tiff: Data([1, 2, 3]),
                                                    RepresentationType.html: Data("<img>".utf8)])
        #expect(ContentClassifier.classify(browserCopy).kind == .image)

        let screenshot = ClipboardSnapshot.single([RepresentationType.png: tinyPNG])
        #expect(ContentClassifier.classify(screenshot).kind == .screenshot)

        let fromTool = ClipboardSnapshot.single([RepresentationType.tiff: Data([1]), RepresentationType.png: tinyPNG],
                                                source: SourceApplication(bundleID: "pl.maketheweb.cleanshotx", name: "CleanShot X"))
        #expect(ContentClassifier.classify(fromTool).kind == .screenshot)
    }

    @Test func pdf() {
        let snapshot = ClipboardSnapshot.single([RepresentationType.pdf: Data("%PDF-1.4".utf8)], hints: .init(pdfPageCount: 3))
        let c = ContentClassifier.classify(snapshot)
        #expect(c.kind == .pdf)
        #expect(c.autoTitle == "PDF, 3 pages")
    }

    @Test func nativeColorObject() {
        let snapshot = ClipboardSnapshot.single([RepresentationType.color: Data([0])], hints: .init(colorHex: "#336699"))
        let c = ContentClassifier.classify(snapshot)
        #expect(c.kind == .color)
        #expect(c.metadata.colorHex == "#336699")
    }

    @Test func credentialWinsOverCode() {
        #expect(kind("export OPENAI_API_KEY=" + FakeSecrets.openAIProject) == .credential)
    }
}

@Suite("Code detection")
struct CodeDetectionTests {
    @Test(arguments: [
        ("import SwiftUI\n\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}", "swift"),
        ("def greet(name):\n    print(f\"Hello {name}\")\n\nif __name__ == \"__main__\":\n    greet(\"x\")", "python"),
        ("const items = data.map((item) => item.id);\nconsole.log(items);", "javascript"),
        ("interface User {\n  id: string;\n  age: number;\n}\nexport const u: User = { id: 'a', age: 1 };", "typescript"),
        ("SELECT id, name FROM users WHERE created_at > now() - interval '7 days' ORDER BY id;", "sql"),
        ("{\"name\": \"clipivo\", \"version\": 1, \"tags\": [\"a\", \"b\"]}", "json"),
        ("#!/bin/bash\nset -euo pipefail\nfor f in *.txt; do\n  echo \"$f\"\ndone", "bash"),
        ("package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"hi\")\n}", "go"),
        ("fn main() {\n    let mut v = Vec::new();\n    v.push(1);\n    println!(\"{:?}\", v);\n}", "rust"),
        ("#include <iostream>\nint main() {\n  std::cout << \"hi\" << std::endl;\n}", "cpp"),
        ("<?php\nfunction hello($name) {\n  echo \"Hi \" . $name;\n}", "php"),
        (".button {\n  color: red;\n  padding: 4px 8px;\n}\n@media (max-width: 600px) { .button { display: none; } }", "css"),
        ("<!DOCTYPE html>\n<html><body><div class=\"x\">Hi</div></body></html>", "html"),
        ("npm install --save-dev typescript", "bash"),
    ])
    func detectsLanguage(_ sample: (String, String)) {
        let result = CodeDetector.detect(sample.0)
        #expect(result?.language == sample.1, "expected \(sample.1) got \(String(describing: result))")
    }

    @Test(arguments: [
        "Select the file from the list and press continue to proceed with the upload.",
        "Thanks for your message! I'll get back to you by Friday.",
        "The meeting is at 3pm (in the big room).",
        "hello",
    ])
    func proseIsNotCode(_ text: String) {
        #expect(CodeDetector.detect(text) == nil)
    }
}

@Suite("Sensitive content")
struct SensitiveContentTests {
    func findings(_ text: String) -> [SensitiveContentDetector.Finding] {
        SensitiveContentDetector.analyze(text: text).findings
    }

    @Test func privateKey() {
        #expect(findings("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----").contains(.privateKey))
    }

    @Test func jwt() {
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(findings(token).contains(.jwt))
    }

    @Test(arguments: [
        FakeSecrets.awsKeyID,
        FakeSecrets.githubToken,
        FakeSecrets.stripeLive,
        FakeSecrets.slackBot,
        FakeSecrets.googleAPI,
    ])
    func apiKeys(_ key: String) {
        #expect(findings(key).contains(.apiKey))
    }

    @Test func envSecret() {
        #expect(findings("DATABASE_PASSWORD=hunter2hunter2").contains(.envSecret))
        #expect(findings("export STRIPE_SECRET_KEY=\"abc123def456\"").contains(.envSecret))
    }

    @Test func creditCards() {
        #expect(findings("4111 1111 1111 1111").contains(.creditCard))
        #expect(findings("5555-5555-5555-4444").contains(.creditCard))
        #expect(!findings("4111 1111 1111 1112").contains(.creditCard)) // fails Luhn
        #expect(!findings("Order 1234567890123 shipped").contains(.creditCard))
    }

    @Test func secretURLs() {
        #expect(findings("postgres://admin:s3cretpass@db.example.com:5432/app").contains(.secretURL))
        #expect(findings("https://api.example.com/v1/data?access_token=abcdef1234567890").contains(.secretURL))
        #expect(!findings("https://example.com/docs?page=2").contains(.secretURL))
    }

    @Test func passwordLike() {
        #expect(findings("Tr0ub4dor&3xK!").contains(.password))
        #expect(!findings("myVariableName").contains(.password))
        #expect(!findings("hello world how are you").contains(.password))
        #expect(!findings("ESP-MATRIX-0010").contains(.password))   // serial numbers are not passwords
        #expect(!findings("build_2024.10-RC1").contains(.password))
        #expect(SensitiveContentDetector.analyze(text: "Tr0ub4dor&3xK!").level == .possible)
    }

    @Test func concealedMarkerAndPasswordManagers() {
        let marked = SensitiveContentDetector.analyze(text: "anything", declaredTypes: [RepresentationType.concealed])
        #expect(marked.findings.contains(.passwordManager))
        #expect(marked.level == .likely)
        let fromManager = SensitiveContentDetector.analyze(text: "x", sourceBundleID: "com.1password.1password")
        #expect(fromManager.findings.contains(.passwordManager))
    }

    @Test func ordinaryTextIsClean() {
        let report = SensitiveContentDetector.analyze(text: "Let's meet tomorrow at 10 to discuss the supabase migration.")
        #expect(report.level == .none)
    }

    @Test func luhn() {
        #expect(SensitiveContentDetector.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        #expect(!SensitiveContentDetector.luhn([1, 2, 3, 4]))
    }
}

@Suite("Search syntax")
struct SearchSyntaxTests {
    @Test func parsesFilters() {
        let parsed = SearchSyntax.parse("invoice app:chrome type:image in:work is:pinned date:week tag:finance")
        #expect(parsed.freeText == "invoice")
        #expect(parsed.app == "chrome")
        #expect(parsed.category == .images)
        #expect(parsed.space == "work")
        #expect(parsed.pinned)
        #expect(parsed.date == .last7Days)
        #expect(parsed.tag == "finance")
    }

    @Test func keepsURLsAndUnknownKeysAsText() {
        let parsed = SearchSyntax.parse("https://example.com foo:bar")
        #expect(parsed.freeText == "https://example.com foo:bar")
    }

    @Test func quotedPhrases() {
        #expect(SearchSyntax.terms("\"hello world\" test") == ["hello world", "test"])
        #expect(SearchSyntax.parse("\"app:literal\"").app == nil)
    }

    @Test func matchExpressionEscapesQuotes() {
        let expr = SearchPlanner.matchExpression(["say \"hi\""], columns: SearchFields.all.ftsColumns)
        #expect(expr == "\"say \"\"hi\"\"\"")
        let limited = SearchPlanner.matchExpression(["abc"], columns: ["title", "body"])
        #expect(limited == "{title body} : \"abc\"")
    }
}

@Suite("Classifier performance guards")
struct ClassifierPerformanceTests {
    /// Regression test: a nested-quantifier pattern once caused catastrophic backtracking on
    /// ordinary multi-word text. Classification of hostile or huge input must stay fast.
    @Test(arguments: [
        String(repeating: "supabase ", count: 2_000),
        String(repeating: "a", count: 50_000),
        String(repeating: "SELECT x ", count: 3_000),
        String(repeating: "PASSWORD_", count: 5_000) + "=x",
        (0..<3_000).map { "word\($0)-part.\($0) > sel" }.joined(separator: " "),
        String(repeating: "def f(" , count: 4_000),
    ])
    func pathologicalInputIsFast(_ input: String) {
        let start = Date()
        _ = ContentClassifier.classify(.text(input))
        #expect(Date().timeIntervalSince(start) < 1.5, "classification took \(Date().timeIntervalSince(start))s")
    }
}

@Suite("Code detection false positives")
struct CodeFalsePositiveTests {
    /// A long structured prompt/notes document with "Label: value" lines and bullets is prose, not YAML.
    @Test func structuredProseIsNotYAML() {
        let text = """
        Build and fully install a production-quality app.
        Reference products:
        Notes app: a place for quick notes
        Tasks app: simple and lightweight
        Core idea:
        Everything you copy should be easy to find again.
        Default behavior:
        KEEP CLIPS FOREVER.
        The only practical limit should be available local storage.
        Users can explicitly delete items or configure cleanup rules.
        Search:
        Search is one of the most important features.
        """
        #expect(CodeDetector.detect(text) == nil)
        #expect(ContentClassifier.classify(.text(text)).kind == .text)
    }

    @Test func realYAMLStillDetected() {
        let yaml = "name: build\non:\n  push:\n    branches: [main]\njobs:\n  test:\n    runs-on: macos-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: swift test"
        #expect(CodeDetector.detect(yaml)?.language == "yaml")
    }
}

@Suite("Commands that are also English words")
struct EnglishCommandWordTests {
    @Test(arguments: [
        "go ahead generate a great animation rich website for the product which i will be putting in github and zipped app in github releases , also make sure its unique",
        "make sure the build passes before we merge",
        "go to the store and buy milk",
        "export the report as a pdf for the client",
        "echo chamber is a real problem on social media",
        "cd player still works fine in the car",
    ])
    func proseStartingWithCommandWordsIsText(_ text: String) {
        #expect(CodeDetector.detect(text) == nil, "misdetected: \(text)")
    }

    @Test(arguments: [
        ("go run main.go", "bash"),
        ("make build", "bash"),
        ("export PATH=$PATH:/usr/local/bin", "bash"),
        ("cd ~/Projects && ls -la", "bash"),
        ("echo \"$HOME\"", "bash"),
        ("git commit -m \"fix the bug for the user\"", "bash"),
    ])
    func realCommandsStillDetected(_ sample: (String, String)) {
        #expect(CodeDetector.detect(sample.0)?.language == sample.1, "expected \(sample.1) for \(sample.0)")
    }
}
