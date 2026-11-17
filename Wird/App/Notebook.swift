import SwiftUI
import UIKit

// دفتري 2.4 (docs/plan/notebook-2.4.md). The tab's first page is alive: passages to read again today, the words due
// for review, the shelf of the books' notebooks, the newest kept. The chips above it list one kind across every book
// (quotes, highlights with their colours' names and notes, thoughts, words, characters), with a book, tags, sorting,
// a search and picking several to copy, share or delete. A book's own notebook is a page of its own (BookNotebook.swift).

struct NotebookView: View {
    @ObservedObject private var store = NotebookStore.shared
    @ObservedObject private var nav = NotebookNav.shared
    @Environment(\.look) private var L
    @State private var tab = "home"
    @State private var bookFilter = ""
    @State private var query = ""
    @State private var favOnly = false
    /// "" all, "__note" the ones with your words, else a colour (its name is the owner's category)
    @State private var markColor = ""
    @State private var tagFilter = ""
    /// "new", "old", "book"
    @State private var sort = "new"
    @State private var sheet: NBSheet?
    /// nil: not picking
    @State private var picked: Set<String>? = nil
    @State private var askDeleteMany = false
    @State private var shuffle = 0
    @State private var fabOpen = false
    @State private var fabDim = false
    @State private var lastY: CGFloat = 0

    /// the home, then one list for each kind (the highlights next to the quotes: both are passages kept from books)
    private static let tabs: [(String, String)] = [("home", "الرئيسية"), ("quote", "اقتباسات"), ("mark", "تظليلات"), ("thought", "أفكار"),
                                                  ("word", "كلمات"), ("char", "شخصيات")]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header.id("nbTop")
                    chips
                    searchField
                    if tab == "home" {
                        if tokens.isEmpty { home } else { results }
                    } else {
                        kindList
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 130)
                .readableColumn(820)
                .background(GeometryReader { g in Color.clear.preference(key: ScrollY.self, value: g.frame(in: .named("nb")).minY) })
            }
            .coordinateSpace(name: "nb")
            .scrollDismissesKeyboard(.interactively)
            .onReceive(NotificationCenter.default.publisher(for: .tabRetap)) { n in
                if (n.object as? String) == "notebook" { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("nbTop", anchor: .top) } }
            }
        }
        .onPreferenceChange(ScrollY.self) { y in
            // the + fades while scrolling down the list and comes back when scrolling up or near the top
            guard !fabOpen else { lastY = y; return }
            if y - lastY < -4 && y < -40 { if !fabDim { withAnimation(.easeOut(duration: 0.2)) { fabDim = true } } }
            else if y - lastY > 4 || y > -40 { if fabDim { withAnimation(.easeOut(duration: 0.2)) { fabDim = false } } }
            lastY = y
        }
        .overlay { if fabOpen { Color(red: 6 / 255, green: 14 / 255, blue: 12 / 255).opacity(0.42).ignoresSafeArea().onTapGesture { fabToggle(false) }.transition(.opacity) } }
        .overlay(alignment: .bottomLeading) {
            if picked == nil && (SessionModel.shared.timer == nil || !SessionModel.shared.showScreen) {
                NotebookFab(open: $fabOpen, dim: fabDim, current: tab == "home" || tab == "mark" ? "quote" : tab) { k in fabPick(k) }
            }
        }
        .overlay(alignment: .bottom) { if let p = picked { selectBar(p) } }
        .statusBarBackdrop(Color(L.bg))
        .background(Color(L.bg).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: follow)
        // the + fan folds when you go to another tab
        .onReceive(Router.shared.$mainTab) { _ in if fabOpen { fabToggle(false) } }
        .onReceive(Router.shared.$group) { _ in if fabOpen { fabToggle(false) } }
        .onChange(of: nav.book) { _ in follow() }
        .onChange(of: nav.kind) { _ in follow() }
        .onChange(of: nav.character) { _ in follow() }
        .nbSheets($sheet)
        .confirmationDialog("حذف المحدد؟", isPresented: $askDeleteMany, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { deletePicked() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("تقدر تتراجع خلال ثواني.")
        }
    }

    private var act: NBDo {
        var a = NBDo(show: { sheet = $0 })
        // picking several is for the lists (the home has nothing to do with a selection)
        if tab != "home" { a.pick = { e in togglePick(e) } }
        return a
    }

    private func lib(_ id: String) -> Book? { Library.shared.state.book(id) }

    private var tokens: [String] { Words.norm(query).split(separator: " ").map(String.init) }

    // MARK: the top

    private var header: some View {
        HStack(spacing: 10) {
            Text("دفتري").font(JFont.display(28, .bold)).foregroundStyle(Color(L.ink))
            HeaderSessionChip()
            Spacer()
            if tab != "home" && picked == nil && store.ix.n(NBEntry.Kind(rawValue: tab) ?? .quote) > 0 {
                Button { withAnimation(.easeOut(duration: 0.2)) { picked = [] } } label: {
                    Text("تحديد").font(JFont.body(15, .medium)).foregroundStyle(Color(L.primary)).frame(minHeight: 36)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.tabs, id: \.0) { t in
                    NBChip(text: t.1, count: t.0 == "home" ? nil : store.ix.n(NBEntry.Kind(rawValue: t.0) ?? .quote),
                           symbol: t.0 == "home" ? "sparkles" : nil, on: tab == t.0) { pickTab(t.0) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color(L.ink2))
            TextField(tab == "home" ? "ابحث في دفترك" : "بحث", text: $query).font(JFont.body(15)).autocorrectionDisabled()
                .clearButton($query, Color(L.ink2))
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    private func pickTab(_ t: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            tab = t
            query = ""
            markColor = ""
            tagFilter = ""
            favOnly = false
            picked = nil
            if t == "word" || t == "char", sort == "book" { sort = "new" }
        }
    }

    // MARK: the home

    @ViewBuilder private var home: some View {
        let ix = store.ix
        if ix.all.isEmpty {
            welcome
        } else {
            today
            if ix.n(.word) > 0 {
                NBReviewPanel(stats: ix.words(), review: { sheet = .review(nil) })
            }
            shelf
            recent
        }
    }

    @ViewBuilder private var today: some View {
        let list = store.today(shuffle: shuffle)
        if !list.isEmpty {
            let w = min(UIScreen.main.bounds.width - 56, 520)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    NBTitle(title: "من دفترك اليوم", sub: "مقاطع ترجع لك كل يوم، والمفضّلة أكثر")
                    Spacer()
                    if list.count > 1 {
                        Button { withAnimation(.easeOut(duration: 0.25)) { shuffle += 1 } } label: {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(L.primary))
                                .frame(width: 38, height: 38).background(Circle().fill(Color(L.surface)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("مقاطع أخرى")
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(list) { e in TodayCard(e: e, book: lib(e.book), act: act).frame(width: w) }
                    }
                    .modifier(NBPagingTargets())
                }
                .modifier(NBPagingRow())
                .padding(.horizontal, -16)
            }
        }
    }

    private var shelf: some View {
        let books = store.ix.books
        return VStack(alignment: .leading, spacing: 10) {
            NBTitle(title: "دفاتر كتبك", count: books.count, sub: "كل كتاب بدفتره: مقاطعه حسب الفصول، شخصياته وكلماته")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(books) { info in
                        if let b = lib(info.id) {
                            Button { Router.shared.push(.notebook(info.id, ""), in: .notebook) } label: { BookNotebookCard(book: b, info: info) }
                                .buttonStyle(NBPress())
                                .accessibilityIdentifier("nb-book-" + info.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
    }

    private var recent: some View {
        let list = Array(store.ix.all.prefix(10))
        return VStack(alignment: .leading, spacing: 10) {
            NBTitle(title: "آخر ما حفظت")
            VStack(spacing: 10) {
                ForEach(list) { e in entry(e, showBook: true, compact: true) }
            }
        }
    }

    @ViewBuilder private func entry(_ e: NBEntry, showBook: Bool, compact: Bool) -> some View {
        if e.isPassage {
            PassageCard(e: e, act: act, book: lib(e.book), showBook: showBook, compact: compact, picked: pickState(e))
        } else if e.kind == .word && tab != "home" {
            WordTile(e: e, act: act, book: lib(e.book), showBook: showBook, picked: pickState(e))
        } else {
            NBRow(e: e, act: act, book: lib(e.book), showBook: showBook, boxed: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 34, weight: .light)).foregroundStyle(Color(L.primary))
            Text("دفترك يبدأ من أول سطر يعجبك").font(JFont.display(22, .semibold)).foregroundStyle(Color(L.ink))
            tip("highlighter", "وأنت تقرأ رواية أو كتاب: حدد النص واختر «تظليل» أو «ملاحظة» أو «للدفتر».")
            tip("plus.circle", "من زر + هنا: اقتباس، فكرة، كلمة، شخصية، أو صوّر صفحة وأنا أكتب نصها.")
            tip("sparkles", "اللي تحفظه يرجع لك هنا كل يوم، ويفتح لك مكانه في القارئ.")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(L.surface)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(L.primary)).frame(width: 22)
            Text(text).font(JFont.body(14.5)).foregroundStyle(Color(L.ink2)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the home's search finds: every kind, every book.
    @ViewBuilder private var results: some View {
        let toks = tokens
        let hits = store.ix.all.filter { e in toks.allSatisfy { e.hay.contains($0) } }
        if hits.isEmpty {
            Text("ما لقيت شيئًا يطابق بحثك.").font(JFont.body(15)).foregroundStyle(Color(L.ink2)).padding(.top, 12)
        } else {
            Text(Words.cnt(Double(hits.count), ["نتيجة واحدة", "نتيجتان", "نتائج", "نتيجة"])).font(JFont.body(13, .medium)).foregroundStyle(Color(L.ink2))
            LazyVStack(spacing: 10) {
                ForEach(Array(hits.prefix(200))) { e in entry(e, showBook: true, compact: true) }
            }
        }
    }

    // MARK: a kind across the books

    @ViewBuilder private var kindList: some View {
        let kind = NBEntry.Kind(rawValue: tab) ?? .quote
        let base = store.ix.all.filter { $0.kind == kind }
        let shown = filtered(base, kind)
        filterBar(kind, base)
        if shown.isEmpty {
            empty(kind, filtered: !base.isEmpty)
        } else {
            switch kind {
            case .word:
                NBWords(entries: shown, act: act, stats: store.ix.words(bookFilter.isEmpty ? nil : bookFilter),
                        review: { sheet = .review(bookFilter.isEmpty ? nil : bookFilter) },
                        anki: { NotebookExport.anki(bookFilter.isEmpty ? nil : bookFilter) },
                        add: { fabPick("word") }, books: bookMap, showBook: bookFilter.isEmpty, picked: picked)
            case .char:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(shown) { e in CharacterTile(e: e, act: act, book: lib(e.book), showBook: bookFilter.isEmpty, picked: pickState(e)) }
                }
            default:
                if sort == "book" {
                    byBook(shown)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(shown) { e in PassageCard(e: e, act: act, book: lib(e.book), showBook: bookFilter.isEmpty, picked: pickState(e)) }
                    }
                }
            }
        }
    }

    private var bookMap: [String: Book] {
        Dictionary(Library.shared.state.books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func filtered(_ base: [NBEntry], _ kind: NBEntry.Kind) -> [NBEntry] {
        let toks = tokens
        var l = base.filter { e in
            if !bookFilter.isEmpty && e.book != bookFilter { return false }
            if favOnly && !e.fav { return false }
            if !tagFilter.isEmpty && !e.tags.contains(tagFilter) { return false }
            if kind == .mark && !markColor.isEmpty {
                if markColor == "__note" {
                    if e.note.isEmpty { return false }
                } else if e.color != markColor {
                    return false
                }
            }
            return toks.allSatisfy { e.hay.contains($0) }
        }
        if sort == "old" { l.reverse() }
        return l
    }

    private func filterBar(_ kind: NBEntry.Kind, _ base: [NBEntry]) -> some View {
        let books = store.ix.books.filter { $0.n(kind) > 0 }
        let tags = Array(Set(base.flatMap(\.tags))).sorted()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                bookMenu(books)
                if !bookFilter.isEmpty {
                    Button { Router.shared.push(.notebook(bookFilter, kind == .mark ? "mark" : kind.rawValue), in: .notebook) } label: {
                        Image(systemName: "book.closed").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(L.primary))
                            .frame(width: 42, height: 42)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("دفتر الكتاب")
                }
                sortMenu(kind)
            }
            if kind == .quote && base.contains(where: { $0.fav }) {
                NBChip(text: "★ المفضّلة فقط", on: favOnly) { favOnly.toggle() }
            }
            if kind == .mark { markChips(base) }
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { x in
                            NBChip(text: "#" + x, on: tagFilter == x) { tagFilter = tagFilter == x ? "" : x }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    private func bookMenu(_ books: [NBBook]) -> some View {
        Menu {
            Button("كل الكتب") { bookFilter = "" }
            ForEach(books) { b in Button(b.title) { bookFilter = b.id } }
        } label: {
            HStack {
                Text(bookFilter.isEmpty ? "كل الكتب" : (lib(bookFilter)?.title ?? "كل الكتب")).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .font(JFont.body(14.5)).foregroundStyle(Color(L.ink))
            .padding(.horizontal, 12).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        }
    }

    private func sortMenu(_ kind: NBEntry.Kind) -> some View {
        Menu {
            Picker("الترتيب", selection: $sort) {
                Label("الأحدث أولًا", systemImage: "clock").tag("new")
                Label("الأقدم أولًا", systemImage: "clock.arrow.circlepath").tag("old")
                if kind != .word && kind != .char { Label("حسب الكتاب", systemImage: "books.vertical").tag("book") }
            }
            Button { withAnimation(.easeOut(duration: 0.2)) { picked = [] } } label: { Label("تحديد", systemImage: "checkmark.circle") }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(L.ink))
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        }
        .accessibilityLabel("الترتيب")
    }

    /// The highlights' own row: all, the ones with your words, and each colour by the name you gave it.
    private func markChips(_ base: [NBEntry]) -> some View {
        let inBook = base.filter { bookFilter.isEmpty || $0.book == bookFilter }
        let noted = inBook.filter { !$0.note.isEmpty }.count
        let counts = Dictionary(grouping: inBook, by: { $0.color ?? "" }).mapValues { $0.count }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                NBChip(text: "الكل", on: markColor.isEmpty) { markColor = "" }
                if noted > 0 || markColor == "__note" {
                    NBChip(text: "ملاحظات", count: noted, symbol: "text.bubble", on: markColor == "__note") { markColor = "__note" }
                }
                ForEach(MarkColor.allCases.filter { counts[$0.rawValue] != nil }, id: \.self) { c in
                    NBChip(text: NotebookExport.colorName(c.rawValue), count: counts[c.rawValue], dot: UIColor(hex: c.hex), on: markColor == c.rawValue) {
                        markColor = c.rawValue
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    /// Passages grouped under their books (sorted «حسب الكتاب»).
    private func byBook(_ shown: [NBEntry]) -> some View {
        var order: [String] = []
        var seen = Set<String>()
        for e in shown where !seen.contains(e.book) { seen.insert(e.book); order.append(e.book) }
        let groups = Dictionary(grouping: shown, by: { $0.book })
        return LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
            ForEach(order, id: \.self) { bid in
                Section {
                    ForEach(groups[bid] ?? []) { e in PassageCard(e: e, act: act, picked: pickState(e)) }
                } header: {
                    HStack(spacing: 8) {
                        if let b = lib(bid) { NBBookLine(book: b) }
                        Spacer(minLength: 8)
                        Text(verbatim: "\((groups[bid] ?? []).count)").font(JFont.body(12.5, .medium)).foregroundStyle(Color(L.ink2)).monospacedDigit()
                        Button { Router.shared.push(.notebook(bid, tab), in: .notebook) } label: {
                            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(L.primary)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("دفتر الكتاب")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color(L.bg))
                    .padding(.horizontal, -16)
                }
            }
        }
    }

    private func empty(_ k: NBEntry.Kind, filtered: Bool) -> some View {
        let t: [NBEntry.Kind: (String, String)] = [
            .quote: ("ما فيه اقتباسات بعد.", "أثناء الجلسة اضغط «اقتباس»، أو صوّر الصفحة وحدد السطر اللي يعجبك وأنا أكتبه لك."),
            .mark: ("ما فيه تظليلات بعد.", "حدد نص وأنت تقرأ رواية أو كتاب واختر «تظليل» أو «ملاحظة». لكل لون اسم تختاره (معلومة، مضحك، تلميح…)، وكل اللي ظلّلته يتجمّع هنا. الاقتباسات والأفكار والكلمات اللي تحفظها من النص تنظلّل فيه وتطلع في قوائمها."),
            .thought: ("ما فيه أفكار بعد.", "سجّل اللي يخطر في بالك وأنت تقرأ، مع النص اللي ألهمك."),
            .word: ("ما فيه كلمات بعد.", "أضف الكلمات الجديدة بمعناها وترجمتها، وراجعها بالبطاقات أو صدّرها لـ Anki."),
            .char: ("ما فيه شخصيات بعد.", "أضف شخصيات الكتاب بأوصافها وعلاقاتها عشان ما تضيع بينها.")
        ]
        let short: [NBEntry.Kind: String] = [.quote: "ما فيه اقتباسات.", .mark: "ما فيه تظليلات هنا.", .thought: "ما فيه أفكار.", .word: "ما فيه كلمات.", .char: "ما فيه شخصيات."]
        return VStack(alignment: .leading, spacing: 6) {
            Text(filtered ? (short[k] ?? "") : (t[k]?.0 ?? "")).font(JFont.body(15, .medium)).foregroundStyle(Color(L.ink))
            if !filtered { Text(t[k]?.1 ?? "").font(JFont.body(13.5)).foregroundStyle(Color(L.ink2)) }
        }
        .padding(.top, 12)
    }

    // MARK: picking several

    private func pickState(_ e: NBEntry) -> Bool? { picked.map { $0.contains(e.id) } }

    private func togglePick(_ e: NBEntry) {
        var p = picked ?? []
        if p.contains(e.id) { p.remove(e.id) } else { p.insert(e.id) }
        withAnimation(.easeOut(duration: 0.15)) { picked = p }
        Haptics.play("sel")
    }

    private var pickedEntries: [NBEntry] {
        guard let p = picked else { return [] }
        return store.ix.all.filter { p.contains($0.id) }
    }

    private func selectBar(_ p: Set<String>) -> some View {
        NBSelectBar(count: p.count,
                    all: {
                        let kind = NBEntry.Kind(rawValue: tab) ?? .quote
                        picked = Set(filtered(store.ix.all.filter { $0.kind == kind }, kind).map(\.id))
                    },
                    copy: { UIPasteboard.general.string = NotebookExport.text(pickedEntries); Haptics.play("soft"); ToastCenter.shared.show("تم النسخ") },
                    shareText: { NotebookExport.shareText(pickedEntries) },
                    shareMarkdown: { NotebookExport.shareMarkdown(pickedEntries, name: "جليس - دفتري".tr) },
                    delete: { askDeleteMany = true },
                    done: { withAnimation(.easeOut(duration: 0.2)) { picked = nil } })
    }

    private func deletePicked() {
        let list = pickedEntries
        withAnimation(.easeOut(duration: 0.2)) { picked = nil }
        NoteItems.deleteMany(list)
    }

    // MARK: the floating +

    private func fabToggle(_ on: Bool) {
        if on { fabDim = false }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { fabOpen = on }
    }

    private func fabPick(_ k: String) {
        let wasOpen = fabOpen
        fabToggle(false)
        // the book shown in the list, or none: the form asks (it does not guess the last book read)
        let b = bookFilter
        let run = {
            if k == "photo" {
                sheet = .form(ItemRef(book: b, kind: "quote", item: nil, pick: true, photo: true, fromNotebook: true))
            } else {
                sheet = .form(ItemRef(book: b, kind: k, item: nil, pick: true, fromNotebook: true))
            }
        }
        // straight away from a hold; after the fan folds when picked from it
        if wasOpen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: run) } else { run() }
    }

    /// Opened from somewhere else: a list («quotes», «marks»…), a book's notebook, a character's card.
    private func follow() {
        if let k = nav.kind {
            let map = ["quotes": "quote", "thoughts": "thought", "words": "word", "chars": "char", "marks": "mark"]
            let t = map[k] ?? k
            if Self.tabs.contains(where: { $0.0 == t }) { pickTab(t) }
        }
        if let b = nav.book, !b.isEmpty {
            if let c = nav.character {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sheet = .character(b, c) }
            } else {
                Router.shared.paths[.notebook] = [.notebook(b, "")]
            }
        }
        if nav.book != nil || nav.kind != nil || nav.character != nil {
            nav.book = nil
            nav.kind = nil
            nav.character = nil
        }
    }
}

struct ItemRef: Identifiable {
    let id = UUID()
    let book: String
    let kind: String
    let item: String?
    var pick = false
    /// open the camera (or photos) for a page right away (the + menu's «صوّر اقتباس»)
    var photo = false
    /// added from the notebook's own +: no page or chapter is filled in for you
    var fromNotebook = false
    /// fields filled in for a new entry (the reader: the selected text, the chapter, its place in the novel)
    var prefill: [String: Any]? = nil
    /// opened over the reader: «افتح مكانه في القارئ» is not offered (the reader is right there)
    var inReader = false
}

/// A highlight of a book, for its note's sheet.
struct MarkRef: Identifiable {
    let id = UUID()
    let book: String
    let mark: JSONObject
}

extension Notification.Name {
    /// an entry was saved by its form: the reader shows a new character's name in the text
    static let noteSaved = Notification.Name("jalees.noteSaved")
}

/// The notebook's scroll position, for the floating + that fades while scrolling.
struct ScrollY: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Shares files (or text) from wherever the app is: over the topmost screen.
@MainActor
enum Share {
    static func files(_ urls: [URL]) {
        guard let h = NovelBridge.host else { return }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = h.view
        NovelBridge.top(h).present(vc, animated: true)
    }

    static func text(_ s: String) {
        guard let h = NovelBridge.host, !s.isEmpty else { return }
        let vc = UIActivityViewController(activityItems: [s], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = h.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: h.view.bounds.midX, y: h.view.bounds.maxY - 80, width: 1, height: 1)
        NovelBridge.top(h).present(vc, animated: true)
    }
}

/// A quote or a thought in a list (a character's card shows its quotes so).
struct QuoteRow: View {
    let book: Book
    let item: NoteItem
    let kind: NoteKind
    let showBook: Bool
    @Environment(\.look) private var L

    var body: some View {
        let r = item.raw
        VStack(alignment: .leading, spacing: 6) {
            if let img = item.img, let i = Library.shared.image(img) {
                Image(uiImage: i).resizable().scaledToFit().frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !r.str("text").isEmpty {
                Text(kind == .quote && item.img == nil ? "«" + r.str("text") + "»" : r.str("text")).font(JFont.quote(19)).foregroundStyle(Color(L.ink)).lineSpacing(5)
                    .spoiler(r.bool("spoiler"))
            }
            // a quote's note (the words a highlight had when it became this quote, or written in its form)
            if kind == .quote && !r.str("note").isEmpty {
                Text(r.str("note")).font(JFont.quote(15.5)).foregroundStyle(Color(L.ink2)).padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(L.line)).frame(width: 3) }
            }
            if kind == .thought && !r.str("passage").isEmpty {
                Text(r.str("passage")).font(JFont.quote(16)).foregroundStyle(Color(L.ink2)).padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(L.line)).frame(width: 3) }
            }
            Text(meta).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
        }
        .padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
    }

    private var meta: String {
        let r = item.raw
        var parts: [String] = []
        if item.fav { parts.append("★") }
        let sid = r.str("speakerId")
        let speaker = sid == "__o" ? r.str("speakerName") : (book.chars.first { $0.id == sid }?.name ?? "")
        if !speaker.isEmpty { parts.append("— " + speaker) }
        parts.append(contentsOf: [NoteItems.locLabel(book, item), showBook ? book.title : "", Words.date(item.at)].filter { !$0.isEmpty })
        return parts.joined(separator: " · ")
    }
}

/// A character's face, or its first letter on a colour from its name.
struct Avatar: View {
    let name: String
    let photo: String?
    let size: CGFloat

    var body: some View {
        ZStack {
            let h = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff } % 360) / 360
            LinearGradient(colors: [Color(hue: h, saturation: 0.42, brightness: 0.55), Color(hue: h, saturation: 0.5, brightness: 0.38)], startPoint: .top, endPoint: .bottom)
            Text(String(name.prefix(1))).font(JFont.display(size * 0.42, .bold)).foregroundStyle(.white)
            if let p = photo, let img = Library.shared.image(p) { Image(uiImage: img).resizable().scaledToFill() }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

enum NoteItems {
    /// The entry as text to copy: a quote with its book, a word with its meaning, a character with its description.
    static func plainText(_ b: Book, _ x: NoteItem, _ k: NoteKind) -> String {
        let r = x.raw
        switch k {
        case .quote: return "«" + r.str("text") + "»\n— " + b.title + (b.author.isEmpty ? "" : "، " + b.author)
        case .thought: return [r.str("text"), r.str("passage").isEmpty ? "" : "«" + r.str("passage") + "»"].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .word: return [r.str("word"), r.str("meaning"), r.str("tr")].filter { !$0.isEmpty }.joined(separator: " — ")
        case .char: return [r.str("name"), r.str("desc")].filter { !$0.isEmpty }.joined(separator: ": ")
        }
    }

    /// itemDel: a character also leaves the others' relations, and its quotes keep its name as «another person».
    /// The toast takes it all back.
    @MainActor
    static func delete(_ bookID: String, _ k: NoteKind, _ id: String) {
        guard let b = Library.shared.state.book(bookID), let x = b.items(k).first(where: { $0.id == id }) else { return }
        let snapshot = b
        let name = x.raw.str("name")
        Library.shared.changeBook(bookID) { bb in
            bb.raw.set(k.listKey, objects: bb.raw.objs(k.listKey).filter { $0.str("id") != id })
            // a quote (thought, word) taken from the text goes with its highlight there: they are one thing
            if k != .char { bb.marks = bb.marks.filter { $0.str("item") != id } }
            if k == .char {
                bb.raw.set("chars", objects: bb.raw.objs("chars").map { c in var c = c; c.set("rel", objects: c.objs("rel").filter { $0.str("to") != id }); return c })
                bb.raw.set("quotes", objects: bb.raw.objs("quotes").map { q in
                    var q = q
                    if q.str("speakerId") == id { q.set("speakerId", "__o"); q.set("speakerName", name) }
                    return q
                })
            }
        }
        Haptics.play("warn")
        let this = ["quote": "هذا الاقتباس", "thought": "هذه الفكرة", "word": "هذه الكلمة", "char": "هذه الشخصية"][k.rawValue] ?? ""
        ToastCenter.shared.show("تم حذف " + this) {
            Library.shared.change { st in if let i = st.index(of: snapshot.id) { st.books[i] = snapshot } }
        }
    }

    /// A highlight deleted from the notebook (the open reader follows); the toast takes it back.
    @MainActor
    static func deleteMark(_ bookID: String, _ id: String) {
        guard let b = Library.shared.state.book(bookID) else { return }
        let snapshot = b
        NovelLibrary.markDel(bookID, id)
        Haptics.play("warn")
        ToastCenter.shared.show("تم حذف التظليل") {
            Library.shared.change { st in if let i = st.index(of: snapshot.id) { st.books[i] = snapshot } }
        }
    }

    /// Where an entry is in its book: «ص 12», «ف 30», «1:05», with the volume for a series.
    static func locLabel(_ b: Book, _ x: NoteItem) -> String {
        guard let loc = x.raw.optNum("loc"), loc > 0 else { return "" }
        let v = b.series ? "م\(x.vol + 1) · " : ""
        return v + (b.unit.time ? Words.hm(loc) : b.unit.abbr + " " + Words.n0(loc))
    }
}
