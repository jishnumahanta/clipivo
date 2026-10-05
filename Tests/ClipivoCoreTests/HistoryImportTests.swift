import Foundation
import Testing
@testable import ClipivoCore

@Suite struct HistoryImportTests {
    @Test func splitsOneClipPerLine() {
        let result = HistoryImport.split("first\nsecond\n\nthird", mode: .line)
        #expect(result == ["first", "second", "third"])
    }

    @Test func splitsOnBlankLinesKeepingMultilineEntriesTogether() {
        let text = "221B Baker Street\nLondon NW1 6XE\n\nhello@example.com\n\n221B Baker Street\nLondon NW1 6XE"
        let result = HistoryImport.split(text, mode: .paragraph)
        #expect(result.count == 2, "The repeated address is a duplicate and dropped")
        #expect(result[0] == "221B Baker Street\nLondon NW1 6XE")
        #expect(result[1] == "hello@example.com")
    }

    @Test func dropsBlankAndWhitespaceOnlyEntries() {
        #expect(HistoryImport.split("a\n\n  \n\nb\n   ", mode: .line) == ["a", "b"])
    }

    @Test func readsAJSONArrayExport() {
        let data = Data(#"["one", "two", "two", "  three  "]"#.utf8)
        #expect(HistoryImport.read(fileContents: data, fallbackMode: .line) == ["one", "two", "three"])
    }

    @Test func fallsBackToPlainTextWhenNotJSON() {
        let data = Data("alpha\nbeta\nbeta".utf8)
        #expect(HistoryImport.read(fileContents: data, fallbackMode: .line) == ["alpha", "beta"])
    }

    @Test func emptyInputYieldsNoEntries() {
        #expect(HistoryImport.split("", mode: .line).isEmpty)
        #expect(HistoryImport.split("\n\n\n", mode: .paragraph).isEmpty)
    }
}
