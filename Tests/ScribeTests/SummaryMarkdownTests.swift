import XCTest
@testable import Scribe

final class SummaryMarkdownTests: XCTestCase {
    func testParsesTheBlocksSummariesUse() {
        let markdown = """
        ## Summary
        The team planned the survey tool migration
        and a **staging** test.

        ## Action items
        - [ ] Nikhil: test the MCP server by Friday
        - [x] Sam: share the prototype
        - Key point
          - Nested detail
        1. First step
        ### Decisions ###
        """
        XCTAssertEqual(SummaryMarkdown.blocks(markdown), [
            .heading(level: 2, text: "Summary"),
            .paragraph("The team planned the survey tool migration and a **staging** test."),
            .heading(level: 2, text: "Action items"),
            .task(indent: 0, done: false, text: "Nikhil: test the MCP server by Friday"),
            .task(indent: 0, done: true, text: "Sam: share the prototype"),
            .bullet(indent: 0, text: "Key point"),
            .bullet(indent: 1, text: "Nested detail"),
            .numbered(indent: 0, marker: "1.", text: "First step"),
            .heading(level: 3, text: "Decisions"),
        ])
    }

    func testPlainTextStaysAParagraph() {
        XCTAssertEqual(SummaryMarkdown.blocks("#hashtag and 100% done"), [.paragraph("#hashtag and 100% done")])
        XCTAssertEqual(SummaryMarkdown.blocks("  \n\n"), [])
    }
}
