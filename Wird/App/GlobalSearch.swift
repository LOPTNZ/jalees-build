import SwiftUI
import UIKit

// The library's global search: one field over the books, quotes, thoughts, words, characters, highlights and the
// novels that are not in the library yet. It matches the way the library's own search does (Words.norm: no marks,
// one form for alef, ya and ta marbuta), with every word of the query found somewhere in the item.

// MARK: - what is found

struct SearchHit: Identifiable {
    enum Kind { case book, quote, thought, word, char, mark, novel }
    let kind: Kind
    let bookID: String
    /// the note's or character's id, a novel's number
    var itemID = ""
    let title: String
    var detail = ""
    /// the book it belongs to, under the text
    var meta = ""
    /// a highlight's place in its novel
    var ch: Int? = nil
    var p: Int? = nil
    var idx = 0
    var id: String { "\(kind)|\(bookID)|\(itemID)|\(idx)" }
}

struct SearchResults {
    var books: [SearchHit] = []
    var quotes: [SearchHit] = []
    var thoughts: [SearchHit] = []
    var words: [SearchHit] = []
    var chars: [SearchHit] = []
    var marks: [SearchHit] = []
    var novels: [SearchHit] = []
    var isEmpty: Bool { books.isEmpty && quotes.isEmpty && thoughts.isEmpty && words.isEmpty && chars.isEmpty && marks.isEmpty && novels.isEmpty }
}

/// a novel that is not a library book, copied out so the search can run off the main thread
struct SearchNovel {
    let id: Int
    let title: String
    let author: String
    let site: String
}

// MARK: - the search itself

enum SearchEngine {
    /// the most results a group shows
    static let cap = 30

    static func tokens(_ q: String) -> [String] {
        Words.norm(q).split(separator: " ").map(String.init)
    }

    private static func match(_ parts: [String], _ toks: [String]) -> Bool {
        let n = Words.norm(parts.joined(separator: " "))
        return toks.allSatisfy { n.contains($0) }
    }

    static func run(_ st: AppState, novels: [SearchNovel], toks: [String]) -> SearchResults {
        var r = SearchResults()
        var titleFirst: [SearchHit] = [], others: [SearchHit] = []
        for b in st.books {
            if !match([b.title, b.author, b.translator, b.narrator, b.cols.joined(separator: " "), b.genres.joined(separator: " ")], toks) { continue }
            let h = SearchHit(kind: .book, bookID: b.id, title: b.title, detail: b.author)
            if match([b.title], toks) { titleFirst.append(h) } else { others.append(h) }
        }
        r.books = Array((titleFirst + others).prefix(cap))

        for b in st.books {
            for q in b.quotes where r.quotes.count < cap {
                if match([q.text, q.passage, q.raw.str("note")], toks) {
                    r.quotes.append(SearchHit(kind: .quote, bookID: b.id, itemID: q.id, title: q.text, detail: q.passage, meta: b.title))
                }
            }
            for t in b.thoughts where r.thoughts.count < cap {
                if match([t.text, t.passage], toks) {
                    r.thoughts.append(SearchHit(kind: .thought, bookID: b.id, itemID: t.id, title: t.text, meta: b.title))
                }
            }
            for w in b.words where r.words.count < cap {
                let tr = w.raw.str("tr")
                if match([w.word, w.meaning, tr], toks) {
                    r.words.append(SearchHit(kind: .word, bookID: b.id, itemID: w.id, title: w.word, detail: [tr, w.meaning].filter { !$0.isEmpty }.joined(separator: " · "), meta: b.title))
                }
            }
            for c in b.chars where r.chars.count < cap {
                if match([c.name, c.alias, c.desc], toks) {
                    r.chars.append(SearchHit(kind: .char, bookID: b.id, itemID: c.id, title: c.name, detail: c.alias.isEmpty ? c.desc : c.alias + " · " + c.desc, meta: b.title))
                }
            }
            for (i, m) in b.marks.enumerated() where r.marks.count < cap {
                if match([m.str("text"), m.str("note")], toks) {
                    let ch = m.str("chLabel")
                    r.marks.append(SearchHit(kind: .mark, bookID: b.id, title: m.str("text"), detail: m.str("note"),
                                             meta: [ch, b.title].filter { !$0.isEmpty }.joined(separator: " · "),
                                             ch: m.int("ch"), p: m.int("p"), idx: i))
                }
            }
        }

        for n in novels where r.novels.count < cap {
            if match([n.title, n.author], toks) {
                r.novels.append(SearchHit(kind: .novel, bookID: "", itemID: String(n.id), title: n.title, detail: n.author, meta: n.site))
            }
        }
        return r
    }

    /// The text with the matched words marked, cut to a window round the first match when it is long.
    static func snippet(_ text: String, _ toks: [String], mark: Color, limit: Int = 140) -> AttributedString {
        let chars = Array(text.prefix(4000))
        // the normalised form, each of its letters pointing at the letter it came from
        var norm: [Character] = [], from: [Int] = []
        for (i, c) in chars.enumerated() {
            for x in (c.isWhitespace ? " " : Words.norm(String(c))) { norm.append(x); from.append(i) }
        }
        var spans: [Range<Int>] = []
        for t in toks {
            let tc = Array(t)
            guard !tc.isEmpty, norm.count >= tc.count else { continue }
            var i = 0
            while i + tc.count <= norm.count {
                if Array(norm[i..<(i + tc.count)]) == tc {
                    spans.append(from[i]..<(from[i + tc.count - 1] + 1))
                    i += tc.count
                } else {
                    i += 1
                }
            }
        }
        var start = 0
        if chars.count > limit, let first = spans.map(\.lowerBound).min() { start = max(0, first - 35) }
        let end = min(chars.count, start + limit)
        let window = String(chars[start..<end])
        var body = AttributedString(window)
        for s in spans {
            let lo = max(s.lowerBound, start), hi = min(s.upperBound, end)
            guard lo < hi else { continue }
            let a = window.index(window.startIndex, offsetBy: lo - start), b = window.index(window.startIndex, offsetBy: hi - start)
            if let r = Range(a..<b, in: body) { body[r].backgroundColor = mark }
        }
        var out = AttributedString(start > 0 ? "…" : "")
        out.append(body)
        out.append(AttributedString(end < chars.count ? "…" : ""))
        return out
    }
}

/// the last eight searches, kept on the phone
enum RecentSearches {
    private static let key = "jalees.recentSearches"

    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    @discardableResult
    static func add(_ q: String) -> [String] {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return load() }
        var l = load().filter { $0 != t }
        l.insert(t, at: 0)
        l = Array(l.prefix(8))
        UserDefaults.standard.set(l, forKey: key)
        return l
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - the sheet

@MainActor
struct GlobalSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var query = ""
    @State private var results = SearchResults()
    /// the words the shown results were found for (what gets marked)
    @State private var toks: [String] = []
    @State private var searched = ""
    @State private var recents = RecentSearches.load()
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if SearchEngine.tokens(query).isEmpty {
                        idle
                    } else if searched == query && results.isEmpty {
                        Text("ما لقيت شيئًا يطابق بحثك.").font(JFont.body(15)).foregroundStyle(Color(L.ink2)).padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    } else {
                        group("الكتب", results.books)
                        group("الاقتباسات", results.quotes)
                        group("الأفكار", results.thoughts)
                        group("الكلمات", results.words)
                        group("الشخصيات", results.chars)
                        group("المعلومات", results.marks)
                        group("روايات خارج مكتبتك", results.novels)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 30).padding(.top, 4)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .readableColumn()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(L.surface).ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .onAppear { DispatchQueue.main.async { focus = true } }
        // a new search starts a quarter of a second after the last key; the one before it is cancelled
        .task(id: query) { await refresh(query) }
    }

    // MARK: the field

    private var bar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(L.ink2))
                TextField("ابحث في كتبك وملاحظاتك…", text: $query).font(JFont.body(16)).submitLabel(.search).focused($focus)
                    .autocorrectionDisabled().onSubmit { recents = RecentSearches.add(query) }
                if !query.isEmpty {
                    Button { query = ""; focus = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color(L.ink2))
                    }
                    .buttonStyle(.plain).accessibilityLabel("مسح")
                }
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
            Button("إلغاء") { dismiss() }.font(JFont.body(15, .medium)).foregroundStyle(Color(L.primary))
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
    }

    // MARK: before anything is typed

    @ViewBuilder private var idle: some View {
        Text("ابحث بكلمة من العنوان أو المؤلف، أو من اقتباس أو فكرة أو كلمة أو شخصية أو تظليل. الهمزات والتشكيل ما تفرق.")
            .font(JFont.body(14)).foregroundStyle(Color(L.ink2)).padding(.top, 8)
        if !recents.isEmpty {
            HStack {
                Text("عمليات البحث الأخيرة").font(JFont.body(13, .semibold)).foregroundStyle(Color(L.ink2))
                Spacer()
                Button("مسح") { RecentSearches.clear(); recents = [] }.font(JFont.body(13.5, .medium)).foregroundStyle(Color(L.primary))
            }
            VStack(spacing: 0) {
                ForEach(recents, id: \.self) { r in
                    Button { query = r } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color(L.ink2)).frame(width: 24)
                            Text(r).font(JFont.body(16)).foregroundStyle(Color(L.ink)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 11).contentShape(Rectangle())
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: the results

    @ViewBuilder private func group(_ title: String, _ hits: [SearchHit]) -> some View {
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(JFont.body(13, .semibold)).foregroundStyle(Color(L.ink2)).padding(.bottom, 4)
                ForEach(hits) { h in row(h) }
            }
        }
    }

    private func row(_ h: SearchHit) -> some View {
        let quoted = h.kind == .quote || h.kind == .mark
        return Button { open(h) } label: {
            HStack(alignment: .top, spacing: 12) {
                leading(h)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mark(h.title)).font(quoted ? JFont.quote(16) : JFont.body(16, .semibold)).foregroundStyle(Color(L.ink))
                        .lineLimit(h.kind == .book || h.kind == .novel ? 2 : 3).multilineTextAlignment(.leading)
                    if !h.detail.isEmpty {
                        Text(mark(h.detail)).font(JFont.body(13.5)).foregroundStyle(Color(L.ink2)).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if !h.meta.isEmpty {
                        Text(h.meta).font(JFont.body(12)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func leading(_ h: SearchHit) -> some View {
        if h.kind == .book, let b = Library.shared.state.book(h.bookID) {
            BookCover(book: b, radius: 5, marks: false).frame(width: 38)
        } else {
            let icon = ["quote": "quote.opening", "thought": "lightbulb", "word": "character.book.closed", "char": "person", "mark": "highlighter", "novel": "globe", "book": "book"]
            Image(systemName: icon[String(describing: h.kind)] ?? "book").font(.system(size: 16)).foregroundStyle(Color(L.primary))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(L.surface2)))
        }
    }

    private func mark(_ s: String) -> AttributedString {
        SearchEngine.snippet(s, toks, mark: Color(L.accentSoft))
    }

    // MARK: running

    private func refresh(_ q: String) async {
        let t = SearchEngine.tokens(q)
        if t.isEmpty { results = SearchResults(); toks = []; searched = ""; return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        let st = Library.shared.state
        let novels = Novels.shared.list.filter { $0.book.isEmpty }.map { SearchNovel(id: $0.id, title: $0.title, author: $0.author, site: $0.siteName) }
        let r = await Task.detached(priority: .userInitiated) { SearchEngine.run(st, novels: novels, toks: t) }.value
        if Task.isCancelled { return }
        results = r; toks = t; searched = q
    }

    // MARK: tapping a result

    /// The sheet closes first; what opens next waits for it to be gone (Present.whenClear).
    private func open(_ h: SearchHit) {
        recents = RecentSearches.add(query)
        let book = h.bookID
        dismiss()
        switch h.kind {
        case .book:
            Present.whenClear { BookLayer.shared.open(book) }
        case .quote:
            Flows.note(book, kind: "edit:quote:" + h.itemID)
        case .thought:
            Flows.note(book, kind: "edit:thought:" + h.itemID)
        case .word:
            Flows.note(book, kind: "edit:word:" + h.itemID)
        case .char:
            Present.shared.open(.character(book, h.itemID))
        case .mark:
            // as the notebook does: the reader, at the highlighted paragraph
            if let n = Library.shared.state.book(book)?.novel {
                Present.whenClear { NovelBridge.openReader(novel: n.novelID, book: book, index: nil, chapter: h.ch, paragraph: h.p) }
            } else {
                Present.whenClear { BookLayer.shared.open(book) }
            }
        case .novel:
            if let id = Int(h.itemID) { Present.whenClear { BookLayer.shared.openNovel(id, book: "") } }
        }
    }
}
