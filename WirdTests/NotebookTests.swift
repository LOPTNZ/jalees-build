import XCTest
@testable import Wird

/// دفتري 2.4's index (NotebookModel.swift): one entry per thing kept (a quote taken from the text is the quote, with
/// its highlight's colour and place, never also a highlight), a book's journal in the novel's chapter order, today's
/// passages the same all day, and the data a backup from before 2.4 holds still read.
@MainActor
final class NotebookTests: XCTestCase {
    private func book(_ o: JSONObject) -> Book { Book(Library.fixBook(Library.blankBook().merging(o) { $1 })) }

    /// a novel's book: two highlights (one is a quote's place), the quote, a word, a character, a bookmark
    private func sample() -> Book {
        let mark: JSONObject = ["id": .string("m1"), "color": .string("purple"), "style": .string("hl"), "ch": .number(12), "chLabel": .string("الفصل 3: الباب"),
                                "p": .number(4), "s": .number(0), "text": .string("سطر مظلل"), "note": .string("ملاحظتي"), "at": .number(1000)]
        let linked: JSONObject = ["id": .string("m2"), "color": .string("yellow"), "style": .string("hl"), "ch": .number(10), "chLabel": .string("الفصل 1"),
                                  "p": .number(2), "s": .number(5), "text": .string("اقتباس من النص"), "kind": .string("quote"), "item": .string("q1"), "at": .number(2000)]
        let quote: JSONObject = ["id": .string("q1"), "text": .string("اقتباس من النص"), "at": .number(2000), "fav": .bool(true), "mark": .string("m2"),
                                 "loc": .number(1), "tags": .array([.string("حبكة")])]
        let word: JSONObject = ["id": .string("w1"), "word": .string("الإملاق"), "meaning": .string("الفقر"), "tr": .string(""), "at": .number(3000),
                                "srs": .object(["ivl": .number(30), "due": .number(0), "ease": .number(2.5), "reps": .number(4)])]
        let char: JSONObject = ["id": .string("c1"), "name": .string("سالم"), "role": .string("main"), "first": .number(2), "at": .number(500)]
        let bmark: JSONObject = ["id": .string("b1"), "ch": .number(11), "chLabel": .string("الفصل 2"), "p": .number(0), "at": .number(400)]
        return book([
            "id": .string("bk"), "title": .string("حارس المكتبة"), "structure": .string("chapters"), "format": .string("web"),
            "novel": .object(["id": .number(7), "site": .string("x")]),
            "marks": .array([.object(mark), .object(linked)]), "bmarks": .array([.object(bmark)]),
            "quotes": .array([.object(quote)]), "words": .array([.object(word)]), "chars": .array([.object(char)])
        ])
    }

    func testOneEntryPerThingKept() {
        let list = NBIndex.entries(of: sample(), now: 10_000)
        // the quote's highlight is the quote: not listed twice
        XCTAssertEqual(list.filter { $0.kind == .mark }.map(\.rawID), ["m1"])
        let q = list.first { $0.kind == .quote }
        XCTAssertEqual(q?.color, "yellow", "a quote taken from the text carries its highlight's colour")
        XCTAssertEqual(q?.ch, 10)
        XCTAssertEqual(q?.markID, "m2")
        XCTAssertEqual(q?.tags, ["حبكة"])
        XCTAssertEqual(q?.fav, true)
        let w = list.first { $0.kind == .word }
        XCTAssertEqual(w?.stage, 2, "a word reviewed past three weeks is known")
        XCTAssertEqual(w?.due, true)
        XCTAssertEqual(list.first { $0.kind == .char }?.num, 2)
        XCTAssertEqual(list.filter { $0.kind == .bmark }.count, 1)
        XCTAssertTrue(list.first { $0.kind == .mark }?.hay.contains(Words.norm("ملاحظتي")) ?? false, "a highlight is found by its note")
    }

    func testIndexLeavesBookmarksOutOfTheNotebook() {
        var st = AppState(Library.empty())
        st.books = [sample()]
        let ix = NBIndex.build(st)
        XCTAssertEqual(ix.all.count, 4, "highlight, quote, word, character")
        XCTAssertEqual(ix.byBook["bk"]?.count, 5, "the book's own list keeps its bookmark")
        XCTAssertEqual(ix.books.first?.total, 4)
        XCTAssertEqual(ix.tagCounts["حبكة"], 1)
        XCTAssertEqual(ix.all.first?.kind, .word, "newest first")
    }

    func testJournalFollowsTheChapters() {
        let list = NBIndex.entries(of: sample(), now: 10_000).filter(\.isPassage)
        var chapters = NBChapters()
        chapters.order = [10: 0, 11: 1, 12: 2]
        chapters.lines = [10: "الفصل 1", 11: "الفصل 2", 12: "الفصل 3: الباب"]
        let groups = NBIndex.journal(list, chapters: chapters, pages: false, byDay: false)
        XCTAssertEqual(groups.map(\.id), ["c10", "c12"], "by the novel's order, not by when they were kept")
        XCTAssertEqual(groups.first?.title, "الفصل 1")
        let days = NBIndex.journal(list, chapters: chapters, pages: false, byDay: true)
        XCTAssertFalse(days.isEmpty)
    }

    func testTodayIsTheSameAllDay() {
        var st = AppState(Library.empty())
        var books: [Book] = []
        for i in 0..<6 {
            var q: [JSONValue] = []
            for j in 0..<5 { q.append(.object(["id": .string("q\(i)-\(j)"), "text": .string("نص \(i) \(j)"), "at": .number(Double(i * 10 + j))])) }
            books.append(book(["id": .string("b\(i)"), "title": .string("كتاب \(i)"), "quotes": .array(q)]))
        }
        st.books = books
        let ix = NBIndex.build(st)
        let a = ix.today(5).map(\.id), b = ix.today(5).map(\.id)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 5)
        XCTAssertNotEqual(ix.today(5, shuffle: 1).map(\.id), a, "another set when asked for others")
    }

    /// a library written before 2.4 (no tags, no links): read as before
    func testOldDataStillReads() {
        let old = book(["id": .string("o"), "title": .string("قديم"), "quotes": .array([.object(["id": .string("x"), "text": .string("نص"), "loc": .number(12)])])])
        let list = NBIndex.entries(of: old, now: 0)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.tags, [])
        XCTAssertEqual(list.first?.num, 12)
        XCTAssertEqual(list.first?.ch, 0)
    }
}
