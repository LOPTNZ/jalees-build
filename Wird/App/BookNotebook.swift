import SwiftUI
import UIKit

// A book's notebook (docs/plan/notebook-2.4.md): the journal of one book. Its passages by chapter in reading order (a
// chapter's heading opens it in the reader, a passage opens the text at it), its characters as a gallery and a map of
// their relations, its words with their review, and everything kept as a timeline. The same view is دفتري's page for a
// book and the reader's «دفتر الرواية» (there a tap moves the open reader).

/// The parts of a book's notebook.
enum NBSection: String, CaseIterable {
    case passages, chars, words, time, bmarks

    var title: String {
        ["passages": "المقاطع", "chars": "الشخصيات", "words": "الكلمات", "time": "الخط الزمني", "bmarks": "وقفات"][rawValue] ?? ""
    }

    var symbol: String {
        ["passages": "text.quote", "chars": "person.2", "words": "character.book.closed", "time": "clock", "bmarks": "bookmark"][rawValue] ?? "circle"
    }
}

/// A book's notebook as a page of دفتري (Router.Page.notebook).
struct BookNotebookPage: View {
    let bookID: String
    var start = ""

    var body: some View { BookNotebookBody(bookID: bookID, start: start) }
}

struct BookNotebookBody: View {
    let bookID: String
    /// where it opens: a section («char», «word», «time», «bmark») or a kind of passage («quote», «mark», «note», «thought»)
    var start = ""
    /// the reader, when this is its «دفتر الرواية»
    var reader: NBReaderLink? = nil
    var title = ""
    var close: (() -> Void)? = nil

    @ObservedObject private var store = NotebookStore.shared
    @Environment(\.look) private var L
    @Environment(\.dismiss) private var dismiss
    @State private var section: NBSection = .passages
    @State private var filter = "all"
    @State private var color = ""
    @State private var tag = ""
    @State private var byPlace = true
    @State private var chapters = NBChapters()
    @State private var current = 0
    @State private var sheet: NBSheet?
    @State private var askDelete: NBEntry?
    /// nil: not picking
    @State private var picked: Set<String>? = nil
    @State private var askDeleteMany = false
    @State private var fabOpen = false
    @State private var fabDim = false
    @State private var lastY: CGFloat = 0
    @State private var started = false

    var body: some View {
        Group {
            if reader != nil { inReader } else { asPage }
        }
        .nbSheets($sheet)
        .confirmationDialog("حذف؟", isPresented: Binding(get: { askDelete != nil }, set: { if !$0 { askDelete = nil } }), titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                if let e = askDelete { act.deleteNow(e) }
                askDelete = nil
            }
            Button("إلغاء", role: .cancel) { askDelete = nil }
        } message: {
            Text("ينحذف من دفترك، وتظليله في النص معه.")
        }
        .confirmationDialog("حذف المحدد؟", isPresented: $askDeleteMany, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { deletePicked() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("تقدر تتراجع خلال ثواني.")
        }
    }

    // MARK: the two places it shows

    private var asPage: some View {
        content
            .coordinateSpace(name: "nbb")
            .onPreferenceChange(ScrollY.self) { y in
                // the + fades while scrolling down and comes back when scrolling up or near the top
                guard !fabOpen else { lastY = y; return }
                if y - lastY < -4 && y < -40 { if !fabDim { withAnimation(.easeOut(duration: 0.2)) { fabDim = true } } }
                else if y - lastY > 4 || y > -40 { if fabDim { withAnimation(.easeOut(duration: 0.2)) { fabDim = false } } }
                lastY = y
            }
            .overlay { if fabOpen { Color(red: 6 / 255, green: 14 / 255, blue: 12 / 255).opacity(0.42).ignoresSafeArea().onTapGesture { fabToggle(false) }.transition(.opacity) } }
            .overlay(alignment: .bottomLeading) {
                if picked == nil && (SessionModel.shared.timer == nil || !SessionModel.shared.showScreen) {
                    NotebookFab(open: $fabOpen, dim: fabDim, current: fabKind) { k in fabPick(k) }
                }
            }
            .overlay(alignment: .bottom) { if let p = picked { selectBar(p) } }
            .statusBarBackdrop(Color(L.bg))
            .background(Color(L.bg).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
    }

    private var inReader: some View {
        VStack(spacing: 0) {
            readerBar
            content
        }
        .background(Color(L.bg).ignoresSafeArea())
    }

    private var content: some View {
        let all = store.ix.byBook[bookID] ?? []
        let book = Library.shared.state.book(bookID)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let b = book {
                        if reader == nil {
                            NBHero(book: b, entries: all, back: back, add: { k in add(k) },
                                   exportText: { NotebookExport.shareText(all.filter { $0.kind != .bmark }) },
                                   exportMarkdown: { NotebookExport.shareMarkdown(all.filter { $0.kind != .bmark }, name: b.title) })
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            sectionChips(all)
                            sectionBody(all, b)
                        }
                        .padding(.horizontal, 16)
                        .readableColumn(820)
                    } else {
                        Text("ما لقيت هذا الكتاب في مكتبتك.").font(JFont.body(15)).foregroundStyle(Color(L.ink2)).padding(24)
                    }
                }
                .padding(.top, reader == nil ? 0 : 4)
                .padding(.bottom, 120)
                .background(GeometryReader { g in Color.clear.preference(key: ScrollY.self, value: g.frame(in: .named("nbb")).minY) })
            }
            .onAppear {
                let here = begin()
                // the reader's list opens at the chapter being read
                if reader != nil && here != 0 && (start.isEmpty || start == "all") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("c\(here)", anchor: .top) } }
                }
            }
        }
    }

    private var act: NBDo {
        var a = NBDo(reader: reader, show: { sheet = $0 }, inBook: true)
        if !chapters.order.isEmpty { a.chapters = chapters }
        if reader == nil {
            a.pick = { e in togglePick(e) }
        } else {
            // an undo toast would be under the reader: an entry asks first
            a.ask = { e in askDelete = e }
        }
        return a
    }

    /// Once, when it first shows: the section asked for, the novel's chapters, the chapter being read (returned).
    @discardableResult
    private func begin() -> Int {
        guard !started else { return 0 }
        started = true
        switch start {
        case "char", "chars": section = .chars
        case "word", "words": section = .words
        case "time": section = .time
        case "bmark", "bmarks": section = .bmarks
        case "quote", "mark", "note", "thought": filter = start
        default: break
        }
        let n = Library.shared.state.book(bookID)?.novel
        var here = 0
        if let r = reader {
            chapters = r.chapters
            if let n = n { here = Novels.shared.novel(n.novelID)?.curChapter ?? 0 }
            current = here
        } else if let n = n {
            chapters = NBChapters(Novels.shared.chapters(n.novelID))
        }
        return here
    }

    private func back() {
        if Router.shared.paths[.notebook]?.isEmpty == false { Router.shared.paths[.notebook]?.removeLast() } else { dismiss() }
    }

    // MARK: the reader's bar

    private var readerBar: some View {
        let all = store.ix.byBook[bookID] ?? []
        let kept = all.filter { $0.kind != .bmark }.count
        return HStack(spacing: 10) {
            Menu {
                Button { reader?.add("bmark") } label: {
                    Label(reader?.bookmarkedHere == true ? "فيه وقفة هنا" : "وقفة هنا", systemImage: "bookmark")
                }
                .disabled(reader?.bookmarkedHere == true)
                Divider()
                ForEach(NoteKind.allCases, id: \.self) { k in
                    Button { reader?.add(k.rawValue) } label: { Label(k.name, systemImage: k.symbol) }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(L.onPrimary))
                    .frame(width: 34, height: 34).background(Circle().fill(Color(L.primary)))
            }
            .accessibilityLabel("إضافة للدفتر")
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(verbatim: title).font(JFont.display(17, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1)
                Text(kept > 0 ? "\(kept) في الدفتر" : "الدفتر فاضي").font(JFont.body(12)).foregroundStyle(Color(L.ink2)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button { reader?.toNotebook() } label: { Label("افتح في دفتري", systemImage: "book.closed") }
                Button { NotebookExport.shareMarkdown(all.filter { $0.kind != .bmark }, name: title) } label: { Label("تصدير Markdown", systemImage: "square.and.arrow.up") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(L.ink))
                    .frame(width: 34, height: 34).background(Circle().fill(Color(L.surface2)))
            }
            .accessibilityLabel("خيارات")
            Button { if let c = close { c() } else { dismiss() } } label: {
                Text("تم").font(JFont.body(15.5, .semibold)).foregroundStyle(Color(L.primary)).padding(.horizontal, 4).frame(height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
    }

    // MARK: sections

    private func counts(_ all: [NBEntry]) -> [NBSection: Int] {
        var n: [NBSection: Int] = [:]
        for e in all {
            switch e.kind {
            case .quote, .mark, .thought: n[.passages, default: 0] += 1
            case .char: n[.chars, default: 0] += 1
            case .word: n[.words, default: 0] += 1
            case .bmark: n[.bmarks, default: 0] += 1
            }
        }
        n[.time] = all.count - (n[.bmarks] ?? 0)
        return n
    }

    private func sectionChips(_ all: [NBEntry]) -> some View {
        let n = counts(all)
        let shown = NBSection.allCases.filter { s in s == .passages || s == section || (n[s] ?? 0) > 0 }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shown, id: \.self) { s in
                    NBChip(text: s.title, count: s == .time ? nil : (n[s] ?? 0), symbol: s.symbol, on: section == s) {
                        withAnimation(.easeOut(duration: 0.2)) { section = s }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    @ViewBuilder private func sectionBody(_ all: [NBEntry], _ b: Book) -> some View {
        switch section {
        case .passages:
            passages(all.filter(\.isPassage), b)
        case .chars:
            NBCharacters(book: b, entries: all.filter { $0.kind == .char }, act: act, add: { add("char") })
        case .words:
            NBWords(entries: all.filter { $0.kind == .word }, act: act, stats: store.ix.words(bookID),
                    review: { sheet = .review(bookID) }, anki: { NotebookExport.anki(bookID) }, add: { add("word") })
        case .time:
            timeline(all.filter { $0.kind != .bmark })
        case .bmarks:
            bookmarks(all.filter { $0.kind == .bmark })
        }
    }

    // MARK: passages: the journal

    @ViewBuilder private func passages(_ list: [NBEntry], _ b: Book) -> some View {
        if list.isEmpty {
            empty("ما فيه مقاطع بعد", b.isNovel
                  ? "حدد نص وأنت تقرأ واختر «تظليل» أو «ملاحظة» أو «للدفتر». يتجمّع هنا حسب الفصول، ومن هنا ترجع لمكانه في القارئ."
                  : "أضف اقتباس أو فكرة من زر +، أو صوّر الصفحة وأنا أكتب نصها.")
        } else {
            filterRow(list)
            let shown = list.filter { matches($0) }
            if shown.isEmpty {
                Text("ما فيه شي هنا.").font(JFont.body(14)).foregroundStyle(Color(L.ink2)).padding(.top, 8)
            } else {
                let groups = NBIndex.journal(shown, chapters: chapters, pages: b.unit == .page && !b.isNovel, byDay: !byPlace)
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.rows) { e in PassageCard(e: e, act: act, picked: picked.map { $0.contains(e.id) }) }
                        } header: {
                            if !g.title.isEmpty { groupHeader(g) }
                        }
                    }
                }
            }
        }
    }

    private func matches(_ e: NBEntry) -> Bool {
        switch filter {
        case "quote", "mark", "thought": if e.kind.rawValue != filter { return false }
        case "note": if e.note.isEmpty || e.kind == .thought { return false }
        case "fav": if !e.fav { return false }
        default: break
        }
        if !color.isEmpty && e.color != color { return false }
        if !tag.isEmpty && !e.tags.contains(tag) { return false }
        return true
    }

    private func filterRow(_ list: [NBEntry]) -> some View {
        let q = list.filter { $0.kind == .quote }.count
        let m = list.filter { $0.kind == .mark }.count
        let t = list.filter { $0.kind == .thought }.count
        let notes = list.filter { !$0.note.isEmpty && $0.kind != .thought }.count
        let favs = list.filter(\.fav).count
        let colors = MarkColor.allCases.filter { c in list.contains { $0.color == c.rawValue } }
        let tags = Array(Set(list.flatMap(\.tags))).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        NBChip(text: "الكل", count: list.count, on: filter == "all") { setFilter("all") }
                        if q > 0 || filter == "quote" { NBChip(text: "اقتباسات", count: q, on: filter == "quote") { setFilter("quote") } }
                        if m > 0 || filter == "mark" { NBChip(text: "تظليلات", count: m, on: filter == "mark") { setFilter("mark") } }
                        if notes > 0 || filter == "note" { NBChip(text: "ملاحظات", count: notes, on: filter == "note") { setFilter("note") } }
                        if t > 0 || filter == "thought" { NBChip(text: "أفكار", count: t, on: filter == "thought") { setFilter("thought") } }
                        if favs > 0 || filter == "fav" { NBChip(text: "المفضّلة", count: favs, symbol: "star.fill", on: filter == "fav") { setFilter("fav") } }
                    }
                }
                sortMenu
            }
            if colors.count > 1 || !color.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        NBChip(text: "كل الألوان", on: color.isEmpty) { color = "" }
                        ForEach(colors, id: \.self) { c in
                            NBChip(text: NotebookExport.colorName(c.rawValue), count: list.filter { $0.color == c.rawValue }.count, dot: UIColor(hex: c.hex), on: color == c.rawValue) {
                                color = color == c.rawValue ? "" : c.rawValue
                            }
                        }
                    }
                }
            }
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { x in
                            NBChip(text: "#" + x, on: tag == x) { tag = tag == x ? "" : x }
                        }
                    }
                }
            }
        }
    }

    private func setFilter(_ f: String) {
        withAnimation(.easeOut(duration: 0.15)) { filter = f }
    }

    private var sortMenu: some View {
        Menu {
            Picker("الترتيب", selection: $byPlace) {
                Label("حسب المكان", systemImage: "list.number").tag(true)
                Label("الأحدث أولًا", systemImage: "clock").tag(false)
            }
            if reader == nil && picked == nil {
                Button { withAnimation(.easeOut(duration: 0.2)) { picked = [] } } label: { Label("تحديد", systemImage: "checkmark.circle") }
            }
        } label: {
            Image(systemName: byPlace ? "list.number" : "clock").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(L.ink))
                .frame(width: 38, height: 34)
                .background(Capsule().fill(Color(L.surface)))
                .overlay(Capsule().strokeBorder(Color(L.line), lineWidth: 1))
        }
        .accessibilityLabel("الترتيب")
    }

    /// A chapter's heading (pinned while its passages scroll), with the way into the reader at it.
    private func groupHeader(_ g: NBGroup) -> some View {
        HStack(spacing: 8) {
            Text(g.title).font(JFont.display(16, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1)
            if reader != nil && g.ch != 0 && g.ch == current {
                Text("أنت هنا").font(JFont.body(11.5, .semibold)).foregroundStyle(Color(L.onPrimary))
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color(L.primary)))
            }
            Spacer(minLength: 8)
            Text(verbatim: "\(g.rows.count)").font(JFont.body(12.5, .medium)).foregroundStyle(Color(L.ink2)).monospacedDigit()
            if act.canOpenChapter(g.ch, book: bookID) {
                Button { act.openChapter(g.ch, book: bookID) } label: {
                    Image(systemName: "book").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(L.primary))
                        .frame(width: 32, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("افتح الفصل في القارئ")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(L.bg))
        .padding(.horizontal, -16)
    }

    // MARK: the timeline, the bookmarks

    @ViewBuilder private func timeline(_ list: [NBEntry]) -> some View {
        if list.isEmpty {
            empty("ما فيه شي بعد", "كل اللي تحفظه من هذا الكتاب يتجمّع هنا بتاريخه، يوم بيوم.")
        } else {
            let groups = NBIndex.journal(list, chapters: chapters, pages: false, byDay: true)
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { g in
                    Section {
                        ForEach(g.rows) { e in NBRow(e: e, act: act) }
                    } header: {
                        HStack {
                            Text(g.title).font(JFont.display(16, .semibold)).foregroundStyle(Color(L.ink))
                            Spacer()
                            Text(verbatim: "\(g.rows.count)").font(JFont.body(12.5, .medium)).foregroundStyle(Color(L.ink2)).monospacedDigit()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color(L.bg))
                        .padding(.horizontal, -16)
                    }
                }
            }
        }
    }

    @ViewBuilder private func bookmarks(_ list: [NBEntry]) -> some View {
        if list.isEmpty {
            empty("ما فيه وقفات", "افتح القائمة وأنت تقرأ واضغط زر الوقفة، وترجع لها من هنا.")
        } else {
            let sorted = list.sorted { a, b in
                let x = chapters.order[a.ch] ?? Int.max, y = chapters.order[b.ch] ?? Int.max
                return x != y ? x < y : a.p < b.p
            }
            LazyVStack(spacing: 0) {
                ForEach(sorted) { e in NBRow(e: e, act: act) }
            }
        }
    }

    private func empty(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(JFont.body(15.5, .semibold)).foregroundStyle(Color(L.ink))
            Text(d).font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(L.surface)))
    }

    // MARK: adding

    private var fabKind: String {
        switch section {
        case .chars: return "char"
        case .words: return "word"
        default: return filter == "thought" ? "thought" : "quote"
        }
    }

    private func fabToggle(_ on: Bool) {
        if on { fabDim = false }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { fabOpen = on }
    }

    private func fabPick(_ k: String) {
        let wasOpen = fabOpen
        fabToggle(false)
        let run = { add(k) }
        if wasOpen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: run) } else { run() }
    }

    /// A new entry for this book: in the reader, at the chapter being read; on the page, placed where the book is.
    private func add(_ k: String) {
        if let r = reader { r.add(k == "photo" ? "quote" : k); return }
        if k == "photo" {
            sheet = .form(ItemRef(book: bookID, kind: "quote", item: nil, photo: true))
        } else {
            sheet = .form(ItemRef(book: bookID, kind: k, item: nil))
        }
    }

    // MARK: picking several

    private func togglePick(_ e: NBEntry) {
        var p = picked ?? []
        if p.contains(e.id) { p.remove(e.id) } else { p.insert(e.id) }
        withAnimation(.easeOut(duration: 0.15)) { picked = p }
        Haptics.play("sel")
    }

    private var pickedEntries: [NBEntry] {
        guard let p = picked else { return [] }
        return (store.ix.byBook[bookID] ?? []).filter { p.contains($0.id) }
    }

    private func selectBar(_ p: Set<String>) -> some View {
        NBSelectBar(count: p.count,
                    all: { picked = Set((store.ix.byBook[bookID] ?? []).filter { $0.isPassage && matches($0) }.map(\.id)) },
                    copy: { UIPasteboard.general.string = NotebookExport.text(pickedEntries); Haptics.play("soft"); ToastCenter.shared.show("تم النسخ") },
                    shareText: { NotebookExport.shareText(pickedEntries) },
                    shareMarkdown: { NotebookExport.shareMarkdown(pickedEntries, name: Library.shared.state.book(bookID)?.title ?? "") },
                    delete: { askDeleteMany = true },
                    done: { withAnimation(.easeOut(duration: 0.2)) { picked = nil } })
    }

    private func deletePicked() {
        let list = pickedEntries
        withAnimation(.easeOut(duration: 0.2)) { picked = nil }
        NoteItems.deleteMany(list)
    }
}

// MARK: - the page's top

/// The top of a book's notebook page: the book's colours and cover, what was kept from it, and the way back to
/// reading it.
struct NBHero: View {
    let book: Book
    let entries: [NBEntry]
    let back: () -> Void
    let add: (String) -> Void
    let exportText: () -> Void
    let exportMarkdown: () -> Void
    @Environment(\.look) private var L

    var body: some View {
        let b = book
        let tint = UIColor.hslParts(b.hslString) ?? L.primary
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward").font(.system(size: 15, weight: .semibold))
                        Text("دفتري").font(JFont.body(15, .medium))
                    }
                    .foregroundStyle(Color.white)
                    .frame(minHeight: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("رجوع")
                Spacer(minLength: 0)
                HeaderSessionChip()
                Menu {
                    Button(action: exportText) { Label("مشاركة الدفتر كنص", systemImage: "doc.plaintext") }
                    Button(action: exportMarkdown) { Label("تصدير Markdown", systemImage: "square.and.arrow.up") }
                    Button { BookLayer.shared.open(b.id) } label: { Label("صفحة الكتاب", systemImage: "info.circle") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.white)
                        .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.18)))
                }
                .accessibilityLabel("خيارات")
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(b.isNovel ? (b.novel?.isEpub == true ? "دفتر الكتاب" : "دفتر الرواية") : "دفتر الكتاب")
                        .font(JFont.body(13, .medium)).foregroundStyle(Color.white.opacity(0.75))
                    Text(verbatim: b.title).font(JFont.display(26, .bold)).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true)
                    if !b.author.isEmpty { Text(verbatim: b.author).font(JFont.body(14.5)).foregroundStyle(Color.white.opacity(0.85)) }
                    Flow(spacing: 6) {
                        ForEach(stats, id: \.self) { s in
                            Text(verbatim: s).font(JFont.body(12.5)).foregroundStyle(Color.white)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.16)))
                        }
                    }
                }
                Spacer(minLength: 0)
                Button { BookLayer.shared.open(b.id) } label: {
                    BookCover(book: b, radius: 6, marks: false).frame(width: 100)
                        .shadow(color: .black.opacity(0.55), radius: 11, y: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("صفحة الكتاب")
            }
            HStack(spacing: 10) {
                if let n = b.novel {
                    Button { NovelBridge.openReader(novel: n.novelID, book: b.id, index: nil, chapter: nil, paragraph: nil) } label: {
                        pill("book.fill", "تابع القراءة", primary: true)
                    }
                    .buttonStyle(NBPress())
                }
                Menu {
                    Button { add("quote") } label: { Label("اقتباس", systemImage: NoteKind.quote.symbol) }
                    Button { add("photo") } label: { Label("صوّر اقتباس", systemImage: "camera") }
                    Button { add("thought") } label: { Label("فكرة", systemImage: NoteKind.thought.symbol) }
                    Button { add("word") } label: { Label("كلمة", systemImage: NoteKind.word.symbol) }
                    Button { add("char") } label: { Label("شخصية", systemImage: NoteKind.char.symbol) }
                } label: {
                    pill("plus", "أضف", primary: false)
                }
                .accessibilityLabel("أضف للدفتر")
            }
        }
        .readableColumn()
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 22)
        .background {
            Color(tint)
                .overlay { if let img = Library.shared.softBackdrop(b.cover) { Image(uiImage: img).resizable().interpolation(.medium).scaledToFill().opacity(0.75) } }
                .overlay { LinearGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.55)], startPoint: .top, endPoint: .bottom) }
                .clipped()
                .ignoresSafeArea(edges: .top)
        }
    }

    /// «12 اقتباسًا», «30 تظليلًا»…
    private var stats: [String] {
        var n: [NBEntry.Kind: Int] = [:]
        for e in entries { n[e.kind, default: 0] += 1 }
        return [NBEntry.Kind.quote, .mark, .thought, .word, .char].compactMap { k in (n[k] ?? 0) > 0 ? k.count(n[k] ?? 0) : nil }
    }

    private func pill(_ symbol: String, _ title: String, primary: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            Text(title).font(JFont.body(15, .semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(primary ? Color(L.onPrimary) : Color.white)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Capsule().fill(primary ? Color(L.primary) : Color.white.opacity(0.18)))
    }
}

// MARK: - characters: a gallery and a map

struct NBCharacters: View {
    let book: Book
    let entries: [NBEntry]
    let act: NBDo
    let add: () -> Void
    @State private var order = "first"
    @Environment(\.look) private var L

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ما فيه شخصيات بعد.").font(JFont.body(15.5, .semibold)).foregroundStyle(Color(L.ink))
                    Text(book.isNovel ? "حدد اسم الشخصية وأنت تقرأ واختر «للدفتر ← شخصية»: اسمها يتعلّم في النص، وأول ظهور لها ينحسب لحاله."
                         : "أضف شخصيات الكتاب بأوصافها وعلاقاتها عشان ما تضيع بينها.")
                        .font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
                    Button(action: add) { Label("شخصية", systemImage: "plus") }.buttonStyle(JButtonStyle(look: L, small: true))
                }
            } else {
                HStack {
                    NBTitle(title: "المعرض", count: entries.count)
                    Spacer()
                    Menu {
                        Picker("الترتيب", selection: $order) {
                            Text("حسب الظهور").tag("first")
                            Text("الرئيسية أولًا").tag("role")
                            Text("حسب الاسم").tag("name")
                        }
                    } label: {
                        Label("الترتيب", systemImage: "arrow.up.arrow.down").font(JFont.body(13.5, .medium)).foregroundStyle(Color(L.primary))
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(sorted) { e in CharacterTile(e: e, act: act) }
                }
                let map = RelationMap.of(book)
                if !map.nodes.isEmpty {
                    NBTitle(title: "خريطة العلاقات", sub: "اضغط على شخصية لبطاقتها، والعلاقات تضيفها من بطاقتها.")
                    RelationMap(nodes: map.nodes, links: map.links) { id in
                        if let e = entries.first(where: { $0.rawID == id }) { act.character(e) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(L.surface)))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                } else if entries.count > 1 {
                    Text("اربط الشخصيات ببعض من «العلاقات» في بطاقة كل شخصية، وتطلع لك خريطتها هنا.")
                        .font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                }
            }
        }
    }

    private var sorted: [NBEntry] {
        switch order {
        case "name": return entries.sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
        case "role":
            func rank(_ e: NBEntry) -> Int { e.role == "main" ? 0 : (e.role == "secondary" ? 1 : 2) }
            return entries.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : ($0.num ?? 1e9) < ($1.num ?? 1e9) }
        default:
            return entries.sorted { ($0.num ?? 1e9) != ($1.num ?? 1e9) ? ($0.num ?? 1e9) < ($1.num ?? 1e9) : $0.at < $1.at }
        }
    }
}

// MARK: - words with their review

struct NBWords: View {
    let entries: [NBEntry]
    let act: NBDo
    let stats: NBIndex.WordStats
    let review: () -> Void
    let anki: () -> Void
    let add: () -> Void
    var books: [String: Book] = [:]
    var showBook = false
    var picked: Set<String>? = nil
    @State private var stage = -1
    @Environment(\.look) private var L

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ما فيه كلمات بعد.").font(JFont.body(15.5, .semibold)).foregroundStyle(Color(L.ink))
                    Text("حدد كلمة وأنت تقرأ واختر «للدفتر ← كلمة»: معناها وترجمتها يتعبّون لحالهم، وجملتها من الكتاب معها.")
                        .font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
                    Button(action: add) { Label("كلمة", systemImage: "plus") }.buttonStyle(JButtonStyle(look: L, small: true))
                }
            } else {
                NBReviewPanel(stats: stats, review: review, anki: anki)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        NBChip(text: "الكل", count: entries.count, on: stage < 0) { stage = -1 }
                        ForEach(0..<3, id: \.self) { s in
                            let n = entries.filter { $0.stage == s }.count
                            if n > 0 || stage == s { NBChip(text: NBStage.name(s), count: n, on: stage == s) { stage = s } }
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 10)], spacing: 10) {
                    ForEach(entries.filter { stage < 0 || $0.stage == stage }) { e in
                        WordTile(e: e, act: act, book: books[e.book], showBook: showBook, picked: picked.map { $0.contains(e.id) })
                    }
                }
            }
        }
    }
}
