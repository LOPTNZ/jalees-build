import SwiftUI
import UIKit

/// The library tab (inventory-1, section 2): a header with add, view, options and search; the books as a carousel,
/// a shelf or a grid; a welcome page when there are none.
struct LibraryView: View {
    let ns: Namespace.ID
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var sheet: LibSheet?

    enum LibSheet: Identifiable {
        case add, view, options, status, search, shelfStyle, progress(String), note(String)
        var id: String {
            switch self {
            case .add: return "add"
            case .view: return "view"
            case .options: return "options"
            case .status: return "status"
            case .search: return "search"
            case .shelfStyle: return "shelfStyle"
            case .progress(let b): return "p" + b
            case .note(let b): return "n" + b
            }
        }
    }

    private var view: String { lib.state.settings.view }
    private var filterActive: Bool {
        let f = lib.state.settings.filter
        return f.str("format", "all") != "all" || !f.str("genre").isEmpty || f.str("series", "all") != "all" || f.bool("hideDone") || !f.str("col").isEmpty
    }

    var body: some View {
        let books = lib.state.libList(query: "")
        let carousel = view == "carousel" && !lib.state.books.isEmpty
        VStack(spacing: 0) {
            header(over: carousel)
            if lib.state.books.isEmpty {
                WelcomeView()
            } else if books.isEmpty && view != "shelf" {
                emptyFilter
            } else if view == "grid" {
                LibraryGrid(books: books, ns: ns)
            } else if view == "shelf" {
                ShelfView(books: books, ns: ns)
            } else {
                CarouselView(books: books, ns: ns, sheet: $sheet)
            }
        }
        .background {
            if carousel { CarouselBand(books: books).ignoresSafeArea() } else { Color(L.bg).ignoresSafeArea() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .add: AddMenu()
                case .view: ViewMenu()
                case .options: LibOptions()
                case .status: StatusMenu()
                case .search: GlobalSearchSheet()
                case .shelfStyle: ShelfStyleSheet()
                case .progress(let id): QuickProgress(bookID: id)
                case .note(let id): AddNoteMenu(bookID: id)
                }
            }
            .environment(\.look, L)
            .environment(\.layoutDirection, Lang.direction)
            .presentationDetents(s.id == "options" || s.id == "search" ? [.large] : [.medium, .large])
        }
    }

    // MARK: header

    private static let views: [(String, String, String)] = [("carousel", "دائري", "rectangle.stack"), ("shelf", "رفوف", "books.vertical"), ("grid", "شبكة", "square.grid.3x3")]
    private static let sorts: [(String, String, String)] = [
        ("lastRead", "آخر قراءة", "date"), ("added", "تاريخ الإضافة", "date"), ("started", "تاريخ البدء", "date"), ("finished", "تاريخ الانتهاء", "date"),
        ("title", "اسم الكتاب", "alpha"), ("author", "اسم المؤلف", "alpha"), ("progress", "نسبة التقدم", "amount"), ("rating", "التقييم", "amount"), ("length", "الطول", "len")
    ]
    private static let dirWords: [String: (String, String)] = ["date": ("الأحدث", "الأقدم"), "alpha": ("ي ← أ", "أ ← ي"), "amount": ("الأعلى", "الأقل"), "len": ("الأطول", "الأقصر")]

    private func header(over: Bool) -> some View {
        let empty = lib.state.books.isEmpty
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                // adding stays a sheet: each row has a line of description, which a menu cannot show
                headerButton("plus", "إضافة كتاب", over) { sheet = .add }
                if !empty { viewMenu(over) }
                Spacer()
                Text("جَليس").font(JFont.display(27, .bold)).foregroundStyle(over ? Color.white : Color(L.ink))
                    .shadow(color: over ? .black.opacity(0.35) : .clear, radius: 3, y: 1)
                Spacer()
                if !empty {
                    optionsMenu(over)
                    headerButton("magnifyingglass", "بحث", over) { sheet = .search }
                }
            }
            if !empty {
                ZStack {
                    // the minimised session sits at the start of this row, as in the web app
                    HStack { HeaderSessionChip(); Spacer(minLength: 0) }
                    statusMenu(over)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }

    /// a menu row that shows a checkmark when it is the current choice
    private func pick(_ title: String, _ on: Bool, icon: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            if on { Label(title, systemImage: "checkmark") }
            else if let icon = icon { Label(title, systemImage: icon) }
            else { Text(title) }
        }
    }

    private func bind(_ path: String, _ v: Bool) -> Binding<Bool> {
        Binding(get: { v }, set: { LibraryFilters.set(path, .bool($0)) })
    }

    // «طريقة العرض»: the style, and the one setting that belongs to it
    private func viewMenu(_ over: Bool) -> some View {
        let s = lib.state.settings
        let symbol = Self.views.first { $0.0 == s.view }?.2 ?? "rectangle.stack"
        return Menu {
            ForEach(Self.views, id: \.0) { v in
                pick(v.1, s.view == v.0, icon: v.2) {
                    // leaving the shelf ends its editing (the draft would come back stale)
                    if v.0 != "shelf" && ShelfEditor.shared.editing { ShelfEditor.shared.cancel() }
                    lib.change { $0.settings.view = v.0 }
                }
            }
            if s.view == "carousel" {
                Section("شكل الدوران") {
                    pick("مكدّس", s.carStyle == "stack") { lib.change { $0.settings.carStyle = "stack" } }
                    pick("أغلفة مائلة", s.carStyle == "flow") { lib.change { $0.settings.carStyle = "flow" } }
                }
            } else if s.view == "grid" {
                Section("عدد الأعمدة") {
                    ForEach([2, 3, 4], id: \.self) { n in pick("\(n)", s.cols == n) { lib.change { $0.settings.cols = n } } }
                }
            } else {
                // the shelf's look is a form of its own
                Button { sheet = .shelfStyle } label: { Label("شكل الرف…", systemImage: "paintpalette") }
            }
        } label: {
            headerIcon(symbol, over, dot: false)
        }
        .accessibilityLabel("طريقة العرض")
    }

    // «خيارات المكتبة»: the order and the quick filters; the long lists stay in the sheet
    private func optionsMenu(_ over: Bool) -> some View {
        let s = lib.state.settings, f = s.filter, show = s.show
        let kind = Self.sorts.first { $0.0 == s.sort }?.2 ?? "date"
        let w = Self.dirWords[kind] ?? ("", "")
        // as in the sheet: the first direction of a name is A to Z, of the others the newest or the largest
        let first = kind == "alpha" ? "asc" : "desc", second = first == "asc" ? "desc" : "asc"
        let genres = Array(Set(lib.state.books.flatMap(\.genres))).sorted()
        return Menu {
            Section("الترتيب") {
                ForEach(Self.sorts, id: \.0) { x in
                    pick(x.1, s.sort == x.0) {
                        let fd = x.2 == "alpha" ? "asc" : "desc"
                        lib.change { $0.settings.sort = x.0; $0.settings.dir = (s.sort == x.0 ? s.dir : fd) }
                    }
                }
            }
            Section("الاتجاه") {
                pick(kind == "alpha" ? w.1 : w.0, s.dir == first) { lib.change { $0.settings.dir = first } }
                pick(kind == "alpha" ? w.0 : w.1, s.dir == second) { lib.change { $0.settings.dir = second } }
            }
            Section("التصفية") {
                Toggle("إخفاء الكتب المنتهية", isOn: bind("f.hideDone", f.bool("hideDone")))
                Menu {
                    ForEach([("all", "الكل"), ("physical", "ملموس"), ("ebook", "إلكتروني"), ("audio", "صوتي")], id: \.0) { x in
                        pick(x.1, f.str("format", "all") == x.0) { LibraryFilters.set("f.format", .string(x.0)) }
                    }
                } label: { Label("الصيغة", systemImage: "doc.text") }
                Menu {
                    ForEach([("all", "الكل"), ("series", "السلاسل فقط"), ("single", "بدون سلاسل")], id: \.0) { x in
                        pick(x.1, f.str("series", "all") == x.0) { LibraryFilters.set("f.series", .string(x.0)) }
                    }
                } label: { Label("السلاسل", systemImage: "books.vertical") }
                if !genres.isEmpty {
                    Menu {
                        pick("كل التصنيفات", f.str("genre").isEmpty) { LibraryFilters.set("f.genre", .string("")) }
                        ForEach(genres, id: \.self) { g in pick(g, f.str("genre") == g) { LibraryFilters.set("f.genre", .string(g)) } }
                    } label: { Label("التصنيف", systemImage: "tag") }
                }
            }
            Section("على الغلاف") {
                Toggle("نسبة التقدم", isOn: bind("show.prog", show.bool("prog")))
                Toggle("التقييم بالنجوم", isOn: bind("show.stars", show.bool("stars")))
                Toggle("شارة الصوتي والإلكتروني", isOn: bind("show.badge", show.bool("badge")))
            }
            Button { sheet = .options } label: { Label("خيارات أكثر…", systemImage: "slider.horizontal.3") }
        } label: {
            headerIcon("slider.horizontal.3", over, dot: filterActive)
        }
        .accessibilityLabel("خيارات المكتبة")
    }

    // «كل الكتب ⌄»: by status, or by collection, with how many each has
    private func statusMenu(_ over: Bool) -> some View {
        let st = lib.state, f = st.settings.filter
        let cols = st.allCols
        return Menu {
            ForEach(LibraryFilters.order, id: \.self) { k in
                pick((LibraryFilters.label[k] ?? k) + " · \(count(k, st))", f.str("col").isEmpty && f.str("status", "all") == k, icon: statusIcon(k)) {
                    LibraryFilters.set("f.status", .string(k)); LibraryFilters.set("f.col", .string(""))
                }
            }
            if !cols.isEmpty {
                Section("مجموعاتك") {
                    ForEach(cols.keys.sorted(), id: \.self) { c in
                        pick(st.colLabel(c) + " · \(cols[c] ?? 0)", f.str("col") == c, icon: "folder") {
                            LibraryFilters.set("f.col", .string(c)); LibraryFilters.set("f.status", .string("all"))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(statusTitle).font(JFont.body(15, .semibold))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(over ? Color.white : Color(L.ink))
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(over ? Color.black.opacity(0.26) : Color(L.surface)))
            .overlay(Capsule().strokeBorder(over ? Color.white.opacity(0.14) : Color(L.line), lineWidth: 1))
        }
        .accessibilityLabel("عرض: " + statusTitle)
    }

    private func statusIcon(_ k: String) -> String {
        ["all": "books.vertical", "reading": "book", "want": "bookmark", "done": "checkmark.circle", "dnf": "xmark.circle", "paused": "pause.circle", "lent": "hand.raised"][k] ?? "book"
    }

    private func count(_ k: String, _ st: AppState) -> Int {
        switch k {
        case "all": return st.books.count
        case "lent": return st.books.filter { $0.format == .physical && ($0.loan.bool("lent") || $0.loan.bool("borrowed")) }.count
        default: return st.books.filter { $0.status.rawValue == k }.count
        }
    }

    private var statusTitle: String {
        let f = lib.state.settings.filter
        let col = f.str("col")
        if !col.isEmpty { return col }
        return LibraryFilters.label[f.str("status", "all")] ?? "كل الكتب"
    }

    private func headerIcon(_ symbol: String, _ over: Bool, dot: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            .foregroundStyle(over ? Color.white : Color(L.ink))
            .frame(width: 44, height: 44)
            .background(Circle().fill(over ? Color.black.opacity(0.26) : Color(L.surface)))
            .overlay(Circle().strokeBorder(over ? Color.white.opacity(0.14) : Color(L.line), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if dot { Circle().fill(Color(L.accent)).frame(width: 9, height: 9).offset(x: -3, y: 3) }
            }
    }

    private func headerButton(_ symbol: String, _ label: String, _ over: Bool, dot: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { headerIcon(symbol, over, dot: dot) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private var emptyFilter: some View {
        VStack(spacing: 14) {
            Text("ما فيه كتب تطابق البحث أو التصفية.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
            Button("إظهار كل الكتب") { LibraryFilters.clear() }.buttonStyle(JButtonStyle(look: L))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum LibraryFilters {
    static let label: [String: String] = ["all": "كل الكتب", "reading": "أقرأه الآن", "want": "أريد قراءته", "done": "أنهيته", "dnf": "تركته", "paused": "وقفت مؤقتًا", "lent": "المعارة والمستعارة"]
    static let order = ["all", "reading", "paused", "want", "done", "dnf", "lent"]

    @MainActor static func clear() {
        Library.shared.change { $0.settings.filter = Settings.defaults().obj("f") }
    }

    @MainActor static func set(_ path: String, _ v: JSONValue) {
        Library.shared.change { st in
            var s = st.settings.raw
            let parts = path.split(separator: ".").map(String.init)
            if parts.count == 2 {
                var o = s.obj(parts[0])
                o[parts[1]] = v
                s[parts[0]] = .object(o)
            } else {
                s[path] = v
            }
            st.settings = Settings(s)
        }
    }
}

// MARK: - the welcome page (no books yet)

struct WelcomeView: View {
    @Environment(\.look) private var L

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("جَليس").font(JFont.display(46, .bold)).foregroundStyle(Color(L.primary)).padding(.top, 30)
                Text("رفّك ينتظر أول كتاب").font(JFont.display(22, .semibold)).foregroundStyle(Color(L.ink))
                Text("أضف الكتب اللي تقرأها الحين، وكل جلسة ومقطع يعجبك يصير له مكان هنا.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                VStack(spacing: 10) {
                    item("barcode.viewfinder", "امسح الباركود", "من ظهر الكتاب") { Flows.scanAdd() }
                    item("square.stack.3d.down.right", "مسح متتابع", "كتاب ورا كتاب، مناسب لمكتبتك الورقية") { Flows.scanBatch() }
                    item("magnifyingglass", "ابحث أو أضفه يدويًا", "بالعنوان أو المؤلف") { Flows.addBook() }
                    item("arrow.clockwise.icloud", "استعادة نسخة احتياطية", "من ملف صدّرته قبل") { Flows.importBackup() }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 30)
        }
    }

    private func item(_ icon: String, _ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color(L.primary)).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(JFont.body(16, .semibold)).foregroundStyle(Color(L.ink))
                    Text(sub).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                }
                Spacer()
                Image(systemName: "chevron.backward").foregroundStyle(Color(L.ink2))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - opening a book from the library

@MainActor
enum OpenBook {
    /// A book's page (a novel's own page for web novels and EPUB books), pushed in the library tab.
    static func open(_ b: Book) {
        // from any tab: the book layer, in place (Flight.swift); the cover travels when it is on screen
        BookLayer.shared.open(b.id)
    }
}


// MARK: - the grid

struct LibraryGrid: View {
    let books: [Book]
    let ns: Namespace.ID
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L

    var body: some View {
        let cols = max(2, min(4, lib.state.settings.cols)) + (Screen.wide ? 3 : 0)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: cols), spacing: 20) {
                ForEach(books) { b in
                    Button { OpenBook.open(b) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            BookCover(book: b).frame(maxWidth: .infinity).coverSpot(b.id)
                                .shadow(color: .black.opacity(0.3), radius: 7, y: 6)
                            Text(b.title).font(JFont.body(cols == 4 ? 12 : 13.5, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(2)
                            Text(b.author.isEmpty ? b.status.label : b.author).font(JFont.body(cols == 4 ? 11 : 12)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(b.title)
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 110)
        }
    }
}
