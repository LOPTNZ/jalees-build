import SwiftUI
import UIKit

// دفتري (inventory-2, 2.1–2.2): quotes, thoughts, words, characters and highlights («معلومات») from every book.

struct NotebookView: View {
    @ObservedObject private var lib = Library.shared
    @ObservedObject private var nav = NotebookNav.shared
    @Environment(\.look) private var L
    @State private var tab = "quote"
    @State private var bookFilter = ""
    @State private var query = ""
    @State private var favOnly = false
    @State private var markColor: String?
    @State private var edit: ItemRef?
    @State private var card: ItemRef?
    @State private var review = false
    @State private var fabOpen = false
    @State private var fabDim = false
    @State private var lastY: CGFloat = 0

    private static let tabs: [(String, String)] = [("quote", "اقتباسات"), ("thought", "أفكار"), ("word", "كلمات"), ("char", "شخصيات"), ("mark", "معلومات")]

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("دفتري").font(JFont.display(28, .bold)).foregroundStyle(Color(L.ink)).id("nbTop")
                    Spacer()
                    if tab != "mark" {
                        Button { add() } label: { Label(NoteKind(rawValue: tab)?.name ?? "", systemImage: "plus") }.buttonStyle(JButtonStyle(look: L, small: true))
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.tabs, id: \.0) { t in
                            JChip(look: L, text: t.1, count: count(t.0), on: tab == t.0) { tab = t.0; bookFilter = ""; query = "" }
                        }
                    }
                }
                filters
                if tab == "mark" { marks } else { list }
            }
            .padding(.horizontal, 16).padding(.bottom, 96)
            .background(GeometryReader { g in Color.clear.preference(key: ScrollY.self, value: g.frame(in: .named("nb")).minY) })
        }
        .coordinateSpace(name: "nb")
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
        .overlay { if fabOpen { Color(red: 6 / 255, green: 14 / 255, blue: 12 / 255).opacity(0.42).ignoresSafeArea().onTapGesture { fabMenu(false) }.transition(.opacity) } }
        .overlay(alignment: .bottomLeading) { fab }
        .statusBarBackdrop(Color(L.bg))
        .background(Color(L.bg).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: follow)
        .onChange(of: nav.book) { _ in follow() }
        .onChange(of: nav.kind) { _ in follow() }
        .onChange(of: nav.character) { _ in follow() }
        .sheet(item: $edit) { r in ItemForm(ref: r).environment(\.look, L).environment(\.layoutDirection, .rightToLeft) }
        .sheet(item: $card) { r in CharacterCard(bookID: r.book, charID: r.item ?? "").environment(\.look, L).environment(\.layoutDirection, .rightToLeft) }
        .sheet(isPresented: $review) { WordReview(bookID: bookFilter.isEmpty ? nil : bookFilter).environment(\.look, L).environment(\.layoutDirection, .rightToLeft) }
    }

    // MARK: the floating + (03-app's FAB): a fan of the four kinds and a photographed quote

    private static let fabItems: [(String, String, String)] = [("char", "شخصية", "person"), ("word", "كلمة", "character.book.closed"),
                                                               ("thought", "فكرة", "lightbulb"), ("photo", "صوّر اقتباس", "camera"),
                                                               ("quote", "اقتباس", "quote.opening")]

    @ViewBuilder private var fab: some View {
        if SessionModel.shared.timer == nil || !SessionModel.shared.showScreen {
            VStack(alignment: .leading, spacing: 12) {
                if fabOpen {
                    ForEach(Array(Self.fabItems.enumerated()), id: \.element.0) { i, it in
                        Button { fabPick(it.0) } label: {
                            HStack(spacing: 10) {
                                let cur = it.0 == tab
                                Image(systemName: it.2).font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Color(cur ? L.onPrimary : L.primary))
                                    .frame(width: 46, height: 46)
                                    .background(Circle().fill(Color(cur ? L.primary : L.surface)))
                                    .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
                                Text(it.1).font(JFont.body(15 * 0.92, .semibold)).foregroundStyle(Color(L.ink))
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                                    .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(it.1)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.9))
                                                    .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(Double(Self.fabItems.count - 1 - i) * 0.03)),
                                                removal: .opacity.animation(.easeOut(duration: 0.15))))
                    }
                    .padding(.leading, 6)
                }
                Button { fabMenu(!fabOpen) } label: {
                    Image(systemName: "plus").font(.system(size: 24, weight: .semibold))
                        .rotationEffect(.degrees(fabOpen ? 135 : 0))
                        .foregroundStyle(Color(L.onPrimary))
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color(L.primary)))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(fabOpen ? "إغلاق القائمة" : "إضافة للدفتر")
                .opacity(fabDim && !fabOpen ? 0.38 : 1)
                .scaleEffect(fabDim && !fabOpen ? 0.88 : 1)
            }
            // above the tab bar (58 high, with 8 over it and 4 under it), as the web's nav height + 16
            .padding(.leading, 16).padding(.bottom, 16 + 70)
        }
    }

    private func fabMenu(_ on: Bool) {
        if on { Haptics.play("soft"); fabDim = false }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { fabOpen = on }
    }

    private func fabPick(_ k: String) {
        fabMenu(false)
        let b = bookFilter.isEmpty ? (lib.state.lastBookId() ?? "") : bookFilter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if k == "photo" { edit = ItemRef(book: b, kind: "quote", item: nil, pick: true, photo: true) }
            else { edit = ItemRef(book: b, kind: k, item: nil, pick: true) }
        }
    }

    /// Opened from somewhere else (a book, the reader): its book, its list, maybe a character's card.
    private func follow() {
        if let b = nav.book { bookFilter = b }
        if let k = nav.kind {
            let map = ["quotes": "quote", "thoughts": "thought", "words": "word", "chars": "char", "marks": "mark"]
            tab = map[k] ?? (NoteKind(rawValue: k) != nil || k == "mark" ? k : tab)
        }
        if let c = nav.character, let b = nav.book {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { card = ItemRef(book: b, kind: "char", item: c) }
        }
        nav.book = nil; nav.kind = nil; nav.character = nil
    }

    private func add() {
        if let k = NoteKind(rawValue: tab) {
            let b = bookFilter.isEmpty ? (lib.state.lastBookId() ?? "") : bookFilter
            edit = ItemRef(book: b, kind: k.rawValue, item: nil, pick: bookFilter.isEmpty)
        }
    }

    private func count(_ k: String) -> Int {
        if k == "mark" { return lib.state.books.reduce(0) { $0 + $1.marks.count } }
        guard let kind = NoteKind(rawValue: k) else { return 0 }
        return lib.state.books.reduce(0) { $0 + $1.items(kind).count }
    }

    // MARK: filters

    private var filters: some View {
        let books = lib.state.books.filter { b in tab == "mark" ? !b.marks.isEmpty : !(NoteKind(rawValue: tab).map { b.items($0) } ?? []).isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    Button("كل الكتب") { bookFilter = "" }
                    ForEach(books) { b in Button(b.title) { bookFilter = b.id } }
                } label: {
                    HStack {
                        Text(lib.state.book(bookFilter)?.title ?? "كل الكتب").lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                    }
                    .font(JFont.body(14.5)).foregroundStyle(Color(L.ink))
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(L.ink2))
                    TextField("بحث", text: $query).font(JFont.body(15)).autocorrectionDisabled()
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
            }
            if tab == "word" && count("word") > 0 {
                HStack(spacing: 8) {
                    Button { review = true } label: { Label("اختبار" + dueText, systemImage: "rectangle.on.rectangle").frame(maxWidth: .infinity) }
                        .buttonStyle(JButtonStyle(look: L, primary: true))
                    Button { exportAnki() } label: { Text("تصدير لـ Anki") }.buttonStyle(JButtonStyle(look: L))
                }
            }
            if tab == "quote" && count("quote") > 0 {
                JChip(look: L, text: "★ المفضّلة فقط", on: favOnly) { favOnly.toggle() }
            }
        }
    }

    private var dueText: String {
        guard lib.state.settings.raw.str("review", "srs") == "srs" else { return "" }
        let n = WordReview.pool(bookFilter.isEmpty ? nil : bookFilter).filter { WordReview.isDue($0.item) }.count
        return n > 0 ? " · \(n) مستحقة" : ""
    }

    // MARK: lists

    @ViewBuilder private var list: some View {
        let k = NoteKind(rawValue: tab) ?? .quote
        let q = Words.norm(query)
        let rows: [(Book, NoteItem)] = lib.state.books.filter { bookFilter.isEmpty || $0.id == bookFilter }.flatMap { b in
            b.items(k).map { (b, $0) }
        }.filter { b, x in
            if favOnly && k == .quote && !x.fav { return false }
            guard !q.isEmpty else { return true }
            let r = x.raw
            let hay = [r.str("text"), r.str("passage"), r.str("word"), r.str("tr"), r.str("meaning"), r.str("name"), r.str("alias"), r.str("desc"), r.str("speakerName"), b.title]
            return Words.norm(hay.joined(separator: " ")).contains(q)
        }
        let sorted = k == .char ? rows : rows.sorted { $0.1.at > $1.1.at }
        if sorted.isEmpty {
            empty(k, filtered: !q.isEmpty || favOnly || !bookFilter.isEmpty)
        } else if k == .char {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(sorted, id: \.1.id) { b, x in
                    Button { card = ItemRef(book: b.id, kind: "char", item: x.id) } label: { CharTile(book: b, item: x, showBook: bookFilter.isEmpty) }.buttonStyle(.plain)
                }
            }
        } else if k == .word {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(sorted, id: \.1.id) { b, x in
                    Button { edit = ItemRef(book: b.id, kind: "word", item: x.id) } label: { WordCard(book: b, item: x, showBook: bookFilter.isEmpty) }.buttonStyle(.plain)
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sorted, id: \.1.id) { b, x in
                    Button { edit = ItemRef(book: b.id, kind: k.rawValue, item: x.id) } label: { QuoteRow(book: b, item: x, kind: k, showBook: bookFilter.isEmpty) }.buttonStyle(.plain)
                }
            }
        }
    }

    private func empty(_ k: NoteKind, filtered: Bool) -> some View {
        let t: [NoteKind: (String, String)] = [
            .quote: ("ما فيه اقتباسات بعد.", "أثناء الجلسة اضغط «اقتباس»، أو صوّر الصفحة وحدد السطر اللي يعجبك وأنا أكتبه لك."),
            .thought: ("ما فيه أفكار بعد.", "سجّل اللي يخطر في بالك وأنت تقرأ، مع النص اللي ألهمك."),
            .word: ("ما فيه كلمات بعد.", "أضف الكلمات الجديدة بمعناها وترجمتها، وراجعها بالبطاقات أو صدّرها لـ Anki."),
            .char: ("ما فيه شخصيات بعد.", "أضف شخصيات الكتاب بأوصافها وعلاقاتها عشان ما تضيع بينها.")
        ]
        let short: [NoteKind: String] = [.quote: "ما فيه اقتباسات.", .thought: "ما فيه أفكار.", .word: "ما فيه كلمات.", .char: "ما فيه شخصيات."]
        return VStack(alignment: .leading, spacing: 6) {
            Text(filtered ? (short[k] ?? "") : (t[k]?.0 ?? "")).font(JFont.body(15, .medium)).foregroundStyle(Color(L.ink))
            if !filtered { Text(t[k]?.1 ?? "").font(JFont.body(13.5)).foregroundStyle(Color(L.ink2)) }
        }
        .padding(.top, 20)
    }

    // MARK: highlights

    @ViewBuilder private var marks: some View {
        let labels = lib.state.settings.markLabels
        let all: [(Book, JSONObject)] = lib.state.books.filter { bookFilter.isEmpty || $0.id == bookFilter }.flatMap { b in b.marks.map { (b, $0) } }
            .sorted { $0.1.num("at") > $1.1.num("at") }
        let info = MarkColor.allCases.first { (labels[$0.rawValue] ?? "") == "معلومة" }?.rawValue
        let col = markColor ?? (info.flatMap { i in all.contains { $0.1.str("color") == i } ? i : nil } ?? "")
        let counts = Dictionary(grouping: all, by: { $0.1.str("color") }).mapValues(\.count)
        let q = Words.norm(query)
        let shown = all.filter { b, m in (col.isEmpty || m.str("color") == col) && (q.isEmpty || Words.norm([m.str("text"), m.str("note"), b.title].joined(separator: " ")).contains(q)) }
        if all.isEmpty {
            Text("حدد نص وأنت تقرأ رواية أو كتاب واختر «للدفتر ← معلومة»، أو ظلّله بلون له اسم (معلومة، مضحك، تلميح…)، ويتجمّع هنا.")
                .font(JFont.body(14)).foregroundStyle(Color(L.ink2)).padding(.top, 16)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    JChip(look: L, text: "الكل", on: col.isEmpty) { markColor = "" }
                    ForEach(MarkColor.allCases.filter { counts[$0.rawValue] != nil }, id: \.self) { c in
                        JChip(look: L, text: name(c, labels), count: counts[c.rawValue], dot: UIColor(hex: c.hex), on: col == c.rawValue) { markColor = c.rawValue }
                    }
                }
            }
            if shown.isEmpty { Text("ما فيه تظليلات هنا.").font(JFont.body(14)).foregroundStyle(Color(L.ink2)) }
            LazyVStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, x in
                    let (b, m) = x
                    Button { openMark(b, m) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.str("text")).font(JFont.quote(18)).foregroundStyle(Color(L.ink)).lineSpacing(4)
                            if !m.str("note").isEmpty {
                                Text(m.str("note")).font(JFont.quote(15.5)).foregroundStyle(Color(L.ink2)).padding(.leading, 10)
                                    .overlay(alignment: .leading) { Rectangle().fill(Color(L.line)).frame(width: 3) }
                            }
                            Text([name(MarkColor(rawValue: m.str("color")) ?? .yellow, labels), m.str("chLabel"), b.title, Words.date(m.num("at"))].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
                        }
                        .padding(.vertical, 14).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: (MarkColor(rawValue: m.str("color")) ?? .yellow).hex)).frame(width: 4) }
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func name(_ c: MarkColor, _ labels: [String: String]) -> String { (labels[c.rawValue]).flatMap { $0.isEmpty ? nil : $0 } ?? c.plain }

    private func openMark(_ b: Book, _ m: JSONObject) {
        guard let n = b.novel else { return }
        NovelBridge.openReader(novel: n.novelID, book: b.id, index: nil, chapter: m.int("ch"), paragraph: m.int("p"))
    }

    // MARK: Anki

    private func exportAnki() {
        let rows = lib.state.books.filter { bookFilter.isEmpty || $0.id == bookFilter }.flatMap { b in b.words.map { (b, $0) } }
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let csv = rows.map { b, w in
            [w.raw.str("word"), [w.raw.str("tr"), w.raw.str("meaning"), w.raw.str("ex").isEmpty ? "" : "«" + w.raw.str("ex") + "»"].filter { !$0.isEmpty }.joined(separator: "<br>"), b.title]
                .map(esc).joined(separator: ",")
        }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jalees-words.csv")
        try? ("\u{FEFF}" + csv).data(using: .utf8)?.write(to: url)
        Share.files([url])
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
}

/// The notebook's scroll position, for the floating + that fades while scrolling.
struct ScrollY: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Shares files from wherever the app is.
@MainActor
enum Share {
    static func files(_ urls: [URL]) {
        guard let h = NovelBridge.host else { return }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = h.view
        NovelBridge.top(h).present(vc, animated: true)
    }
}

/// A quote or a thought in the notebook.
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

/// A word as a card.
struct WordCard: View {
    let book: Book
    let item: NoteItem
    let showBook: Bool
    @Environment(\.look) private var L

    var body: some View {
        let r = item.raw
        VStack(alignment: .leading, spacing: 4) {
            Text(r.str("word")).font(JFont.display(20, .semibold)).foregroundStyle(Color(L.ink))
            if !r.str("tr").isEmpty { Text(r.str("tr")).font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.primary)) }
            if !r.str("meaning").isEmpty { Text(r.str("meaning")).font(JFont.body(13.5)).foregroundStyle(Color(L.ink)).lineLimit(3) }
            Text([Words.lang(r.str("lang")), NoteItems.locLabel(book, item), showBook ? book.title : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(JFont.body(11.5)).foregroundStyle(Color(L.ink2))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }
}

/// A character as a tile: its face (or initial), name, alias, role, book.
struct CharTile: View {
    let book: Book
    let item: NoteItem
    let showBook: Bool
    @Environment(\.look) private var L

    var body: some View {
        let r = item.raw
        HStack(spacing: 10) {
            Avatar(name: r.str("name"), photo: r.optStr("photo"), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.str("name")).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1)
                Text([r.str("alias"), ["main": "رئيسية", "secondary": "ثانوية"][r.str("role")] ?? "", showBook ? book.title : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(JFont.body(12)).foregroundStyle(Color(L.ink2)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
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
    /// Where an entry is in its book: «ص 12», «ف 30», «1:05», with the volume for a series.
    static func locLabel(_ b: Book, _ x: NoteItem) -> String {
        guard let loc = x.raw.optNum("loc"), loc > 0 else { return "" }
        let v = b.series ? "م\(x.vol + 1) · " : ""
        return v + (b.unit.time ? Words.hm(loc) : b.unit.abbr + " " + Words.n0(loc))
    }
}
