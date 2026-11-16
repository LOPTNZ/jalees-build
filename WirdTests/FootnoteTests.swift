import XCTest
@testable import Wird

/// EPUB footnotes: a reference stays in the paragraph as one marker character, its note comes out as the last
/// paragraph (prefix + JSON), whether the note sits in the same file or in another one.
@MainActor
final class FootnoteTests: XCTestCase {
    private let page = "wirdapp://app/epub/book/OEBPS/ch1.xhtml"

    private func notes(_ paras: [String]) -> [String: String] {
        guard let last = paras.last, last.hasPrefix(EpubStore.notesPrefix),
              let data = String(last.dropFirst(EpubStore.notesPrefix.count)).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return o
    }

    func testNotesInTheSameFileBecomeMarkersAndNotes() async throws {
        let html = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <h1>Chapter</h1>
        <p>First line<a epub:type="noteref" href="#fn1">1</a> and more.</p>
        <p>Second<sup><a href="#fn2">2</a></sup> line.</p>
        <aside epub:type="footnote" id="fn1"><p>The first note. <a epub:type="backlink" href="#r1">back</a></p></aside>
        <aside epub:type="footnote" id="fn2"><p>The second note.</p></aside>
        </body></html>
        """
        let (_, paras) = try await EpubStore.paragraphs(html: html, url: page) { _ in nil }
        XCTAssertEqual(paras[0], "First line" + EpubStore.noteMark + " and more.")
        XCTAssertEqual(paras[1], "Second" + EpubStore.noteMark + " line.")
        // the notes are not running text any more: two paragraphs and the notes paragraph
        XCTAssertEqual(paras.count, 3)
        let n = notes(paras)
        XCTAssertEqual(n["1"], "The first note.")
        XCTAssertEqual(n["2"], "The second note.")
    }

    func testNotesInAnotherFileAreFetchedFromIt() async throws {
        let html = """
        <html><body><p>Text<sup><a href="notes.xhtml#n3">3</a></sup> end.</p></body></html>
        """
        let other = """
        <html><body><ol><li id="n3">Kept in the notes file. <a href="ch1.xhtml#r3">↩</a></li></ol></body></html>
        """
        var asked: [String] = []
        let (_, paras) = try await EpubStore.paragraphs(html: html, url: page) { file in
            asked.append(file)
            return other
        }
        XCTAssertEqual(asked, ["wirdapp://app/epub/book/OEBPS/notes.xhtml"])
        XCTAssertEqual(paras[0], "Text" + EpubStore.noteMark + " end.")
        XCTAssertEqual(notes(paras)["1"], "Kept in the notes file.")
    }

    func testAChapterWithoutNotesIsAsBefore() async throws {
        let html = "<html><body><p>Plain.</p><p>Text.</p></body></html>"
        let (_, paras) = try await EpubStore.paragraphs(html: html, url: page) { _ in nil }
        XCTAssertEqual(paras, ["Plain.", "Text."])
    }

    func testANotesOnlySectionStaysReadable() async throws {
        let html = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <aside epub:type="endnote" id="e1"><p>An endnote nobody points to from here.</p></aside>
        </body></html>
        """
        let (_, paras) = try await EpubStore.paragraphs(html: html, url: page) { _ in nil }
        XCTAssertEqual(paras, ["An endnote nobody points to from here."])
    }
}
