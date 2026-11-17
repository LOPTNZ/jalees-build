import XCTest
@testable import Wird

/// The reader's menu as the owner arranges it (reader 2.4): what is saved is read back safely, every item has exactly
/// one place, and the round buttons never outgrow their line.
final class ReaderMenuTests: XCTestCase {
    private func all(_ l: ReaderMenuLayout) -> [ReaderMenuItem] { l.rows + l.buttons + l.more + l.hidden }

    func testTheDefaultHoldsEveryItemOnce() {
        let items = all(.standard)
        XCTAssertEqual(items.count, ReaderMenuItem.allCases.count)
        XCTAssertEqual(Set(items), Set(ReaderMenuItem.allCases))
        XCTAssertLessThanOrEqual(ReaderMenuLayout.standard.rows.count, ReaderMenuLayout.maxRows)
        XCTAssertTrue(ReaderMenuLayout.fit(ReaderMenuLayout.standard.buttons).spill.isEmpty)
    }

    func testNothingSavedIsTheDefault() {
        XCTAssertEqual(ReaderMenuLayout.parse(nil), .standard)
        XCTAssertEqual(ReaderMenuLayout.parse("not json"), .standard)
    }

    func testSavedArrangementComesBack() {
        var l = ReaderMenuLayout.standard
        l.move(.guide, to: .rows)
        l.move(.search, to: .hidden)
        l.scrubber = true
        let back = ReaderMenuLayout.parse(l.json)
        XCTAssertEqual(back, l)
        XCTAssertEqual(back.rows.last, .guide)
        XCTAssertTrue(back.hidden.contains(.search))
    }

    /// A name from a newer Jalees is left out; an item listed twice keeps its first place; an item the saved menu never
    /// heard of (added later) goes to «المزيد».
    func testUnknownTwiceAndMissing() {
        let json = #"{"rows":["contents","teleport","aloud"],"buttons":["aloud","search"],"more":[],"hidden":["lock"],"scrubber":false}"#
        let l = ReaderMenuLayout.parse(json)
        XCTAssertEqual(l.rows, [.contents, .aloud])
        XCTAssertEqual(l.buttons, [.search])
        XCTAssertEqual(l.hidden, [.lock])
        XCTAssertEqual(all(l).count, ReaderMenuItem.allCases.count)
        XCTAssertTrue(l.more.contains(.rules))
        XCTAssertTrue(l.more.contains(.chapters))
    }

    /// Six round buttons fill the line, «المزيد» one of them: a pair takes two places, and what does not fit goes into
    /// «المزيد».
    func testButtonsThatDoNotFitSpill() {
        let f = ReaderMenuLayout.fit([.search, .fontSize, .theme, .chapters, .bookmark])
        XCTAssertEqual(f.kept, [.search, .fontSize, .theme, .bookmark])
        XCTAssertEqual(f.spill, [.chapters])
    }

    func testMovingKeepsOnePlace() {
        var l = ReaderMenuLayout.standard
        l.move(.contents, to: .more)
        XCTAssertFalse(l.rows.contains(.contents))
        XCTAssertEqual(l.more.last, .contents)
        XCTAssertEqual(all(l).count, ReaderMenuItem.allCases.count)
        XCTAssertEqual(l.spot(of: .contents), .more)
    }
}
