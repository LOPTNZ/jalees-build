import SwiftUI
import UIKit

// The library's sheets (inventory-1, section 3.4): adding, the view, the options, the status filter, progress, notes.

/// «إضافة»
struct AddMenu: View {
    @Environment(\.dismiss) private var dismiss
    @State private var novel = false

    var body: some View {
        JSheet(title: "إضافة") {
            VStack(spacing: 0) {
                JMenuRow(icon: "book", title: "كتاب واحد", sub: "بحث بالإنترنت أو يدويًا") { dismiss(); Flows.addBook() }
                JMenuRow(icon: "globe", title: "رواية من موقع", sub: "الصق رابطها، وتنضاف بفصولها لمكتبتك") { novel = true }
                JMenuRow(icon: "folder", title: "رواية من أداتك", sub: "مجلد الرواية من Novel Scraper، وفصولها تنحفظ كلها") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NovelArchive.pick() }
                }
                JMenuRow(icon: "doc.text", title: "كتاب PDF من ملفاتك", sub: "ينقرأ من مكانه، وصفحتك تنحفظ") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { PDFBooks.pick() }
                }
                JMenuRow(icon: "doc.richtext", title: "كتاب EPUB من ملفاتك", sub: "ينقرأ من مكانه، بدون نسخة ثانية") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { EpubPick.run() }
                }
                JMenuRow(icon: "barcode.viewfinder", title: "امسح باركود الكتاب", sub: "بالكاميرا، وأختار طبعتك من اللي ألقاه") { dismiss(); Flows.scanAdd() }
                JMenuRow(icon: "square.stack.3d.down.right", title: "مسح متتابع", sub: "امسح كتاب ورا كتاب، وتنضاف كلها مرة وحدة") { dismiss(); Flows.scanBatch() }
                JMenuRow(icon: "list.bullet", title: "عدة كتب دفعة واحدة", sub: "اكتب العناوين وكمّل تفاصيلها لاحقًا") { dismiss(); Flows.multiAdd() }
                JMenuRow(icon: "arrow.clockwise.icloud", title: "استعادة نسخة احتياطية", sub: "من ملف صدّرته من جَليس") { dismiss(); Flows.importBackup() }
            }
        }
        .sheet(isPresented: $novel) { NovelAddSheet { dismiss() } }
    }
}

/// An EPUB from the Files app: read in place, added as a book, then its page.
@MainActor
enum EpubPick {
    static func run() {
        guard let h = NovelBridge.host else { return }
        EpubStore.pick(from: NovelBridge.top(h)) { url in
            guard let u = url else { return }
            NovelLibrary.epubAdded(NovelBridge.epubInfo(u))
        }
    }
}

/// «رواية من موقع»: paste a novel's link (or any of its chapters) and it joins the library with its chapters.
struct NovelAddSheet: View {
    var done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var url = ""
    @State private var busy = false
    @State private var msg = ""
    @State private var err = ""

    var body: some View {
        JSheet(title: "رواية من موقع") {
            Text("الصق رابط صفحة الرواية أو رابط أي فصل منها، وتصير الرواية كتاب في مكتبتك.").font(JFont.body(14.5)).foregroundStyle(Color(L.ink2))
            VStack(alignment: .leading, spacing: 6) {
                JLabel(text: "الرابط")
                TextField("https://kolnovel.com/series/…", text: $url).font(JFont.body(16)).keyboardType(.URL).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().disabled(busy).environment(\.layoutDirection, .leftToRight)
                    .padding(.horizontal, 12).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
            }
            Text("المواقع المدعومة الحين: ملوك الروايات (kolnovel.com). باقي مواقعك في المرحلة الثانية.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
            if !err.isEmpty {
                Text(err).font(JFont.body(14)).foregroundStyle(Color(L.ink)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.accentSoft)))
            }
            if busy {
                HStack(spacing: 10) { ProgressView(); Text(msg.isEmpty ? "أتصل بالموقع" : msg).font(JFont.body(14)).foregroundStyle(Color(L.ink2)) }
            } else {
                Button { add() } label: { Label("أضف الرواية", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L, primary: true))
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func add() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.contains(".") else { err = "الصق رابط الرواية أو رابط فصل منها."; return }
        busy = true; err = ""; msg = "أتصل بالموقع"
        Task {
            let r = await NovelBridge.add(u) { s in msg = s }
            busy = false
            if let e = r["error"] as? String { err = e; return }
            let book = (r["book"] as? String) ?? ""
            dismiss()
            done()
            Router.shared.openNovel(NovelBridge.num(r["id"]), book: book)
            if let i = r["open"] { NovelBridge.showPage(novel: NovelBridge.num(r["id"]), book: book, openIndex: NovelBridge.num(i)) }
            ToastCenter.shared.show("انضافت «\((r["title"] as? String) ?? "")»")
        }
    }
}

/// «طريقة العرض»
struct ViewMenu: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L

    var body: some View {
        let s = lib.state.settings
        NavigationStack {
        JSheet(title: "طريقة العرض") {
            VStack(spacing: 0) {
                ForEach([("carousel", "دائري", "rectangle.stack"), ("shelf", "رفوف", "books.vertical"), ("grid", "شبكة", "square.grid.3x3")], id: \.0) { v in
                    JMenuRow(icon: v.2, title: v.1, checked: s.view == v.0) {
                        lib.change { $0.settings.view = v.0 }
                        dismiss()
                    }
                }
            }
            if s.view == "carousel" {
                JLabel(text: "شكل الدوران")
                JSeg(options: [("stack", "مكدّس"), ("flow", "أغلفة مائلة")], value: Binding(get: { s.carStyle }, set: { v in lib.change { $0.settings.carStyle = v } }))
            } else if s.view == "grid" {
                JLabel(text: "عدد الأعمدة")
                JSeg(options: [(2, "2"), (3, "3"), (4, "4")], value: Binding(get: { s.cols }, set: { v in lib.change { $0.settings.cols = v } }))
            } else {
                NavigationLink { ShelfStyleSheet().toolbar(.hidden, for: .navigationBar) } label: { Label("شكل الرف", systemImage: "paintpalette").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// «خيارات المكتبة»: the order, the filters, what the covers show.
struct LibOptions: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var moreSort = false

    private static let sorts: [(String, String, String)] = [
        ("lastRead", "آخر قراءة", "date"), ("added", "تاريخ الإضافة", "date"), ("started", "تاريخ البدء", "date"), ("finished", "تاريخ الانتهاء", "date"),
        ("title", "اسم الكتاب", "alpha"), ("author", "اسم المؤلف", "alpha"), ("progress", "نسبة التقدم", "amount"), ("rating", "التقييم", "amount"), ("length", "الطول", "len")
    ]
    private static let dirWords: [String: (String, String)] = ["date": ("الأحدث", "الأقدم"), "alpha": ("ي ← أ", "أ ← ي"), "amount": ("الأعلى", "الأقل"), "len": ("الأطول", "الأقصر")]

    var body: some View {
        let s = lib.state.settings, f = s.filter, show = s.show
        JSheet(title: "خيارات المكتبة", action: ("تم", { dismiss() })) {
            JLabel(text: "الترتيب")
            ForEach(Self.sorts.prefix(2), id: \.0) { sortRow($0, s) }
            let hidden = Self.sorts.dropFirst(2)
            let currentHidden = hidden.first { $0.0 == s.sort }
            DisclosureGroup(isExpanded: Binding(get: { moreSort || currentHidden != nil }, set: { moreSort = $0 })) {
                VStack(spacing: 10) { ForEach(Array(hidden), id: \.0) { sortRow($0, s) } }.padding(.top, 8)
            } label: {
                Text("مزيد من خيارات الترتيب" + (currentHidden.map { " · الحالي: " + $0.1 } ?? "")).font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.ink))
            }
            .tint(Color(L.ink2))

            JLabel(text: "التصفية").padding(.top, 6)
            JSwitchRow(title: "إخفاء الكتب المنتهية", on: bind("f.hideDone", f.bool("hideDone")))
            JSeg(options: [("all", "الكل"), ("physical", "ملموس"), ("ebook", "إلكتروني"), ("audio", "صوتي")], value: strBind("f.format", f.str("format", "all")))
            JSeg(options: [("all", "الكل"), ("series", "السلاسل فقط"), ("single", "بدون سلاسل")], value: strBind("f.series", f.str("series", "all")))
            let cols = lib.state.allCols.keys.sorted()
            if !cols.isEmpty {
                Flow(spacing: 8) {
                    JChip(look: L, text: "كل المجموعات", on: f.str("col").isEmpty) { LibraryFilters.set("f.col", .string("")) }
                    ForEach(cols, id: \.self) { c in JChip(look: L, text: lib.state.colLabel(c), on: f.str("col") == c) { LibraryFilters.set("f.col", .string(c)) } }
                }
            }
            let genres = Array(Set(lib.state.books.flatMap(\.genres))).sorted()
            if !genres.isEmpty {
                Flow(spacing: 8) {
                    JChip(look: L, text: "كل التصنيفات", on: f.str("genre").isEmpty) { LibraryFilters.set("f.genre", .string("")) }
                    ForEach(genres, id: \.self) { g in JChip(look: L, text: g, on: f.str("genre") == g) { LibraryFilters.set("f.genre", .string(g)) } }
                }
            }

            JLabel(text: "على الغلاف").padding(.top, 6)
            JSwitchRow(title: "نسبة التقدم", on: bind("show.prog", show.bool("prog")))
            JSwitchRow(title: "التقييم بالنجوم", on: bind("show.stars", show.bool("stars")))
            JSwitchRow(title: "شارة الصوتي والإلكتروني", on: bind("show.badge", show.bool("badge")))
            JLabel(text: "الرفوف").padding(.top, 6)
            JSwitchRow(title: "شارة الصوتي والإلكتروني على الكعب", on: bind("show.shelfBadge", show.bool("shelfBadge")))
        }
    }

    private func sortRow(_ x: (String, String, String), _ s: Settings) -> some View {
        let w = Self.dirWords[x.2] ?? ("", "")
        let first = x.2 == "alpha" ? "asc" : "desc", second = first == "asc" ? "desc" : "asc"
        let firstWord = x.2 == "alpha" ? w.1 : w.0, secondWord = x.2 == "alpha" ? w.0 : w.1
        return HStack(spacing: 10) {
            Text(x.1).font(JFont.body(15)).foregroundStyle(Color(L.ink)).frame(width: 110, alignment: .leading)
            JSeg(options: [(first, firstWord), (second, secondWord)],
                 value: Binding(get: { s.sort == x.0 ? s.dir : "" }, set: { d in lib.change { $0.settings.sort = x.0; $0.settings.dir = d } }))
        }
    }

    private func bind(_ path: String, _ v: Bool) -> Binding<Bool> {
        Binding(get: { v }, set: { LibraryFilters.set(path, .bool($0)) })
    }

    private func strBind(_ path: String, _ v: String) -> Binding<String> {
        Binding(get: { v }, set: { LibraryFilters.set(path, .string($0)) })
    }
}

/// «عرض»: which books, by status or by collection, with how many each has.
struct StatusMenu: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let st = lib.state, f = st.settings.filter
        JSheet(title: "عرض") {
            VStack(spacing: 0) {
                ForEach(LibraryFilters.order, id: \.self) { k in
                    JMenuRow(icon: icon(k), title: LibraryFilters.label[k] ?? k, count: count(k, st),
                             checked: f.str("col").isEmpty && f.str("status", "all") == k) {
                        LibraryFilters.set("f.status", .string(k)); LibraryFilters.set("f.col", .string("")); dismiss()
                    }
                }
            }
            let cols = st.allCols
            if !cols.isEmpty {
                JLabel(text: "مجموعاتك").padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(cols.keys.sorted(), id: \.self) { c in
                        JMenuRow(icon: "folder", title: st.colLabel(c), count: cols[c], checked: f.str("col") == c) {
                            LibraryFilters.set("f.col", .string(c)); LibraryFilters.set("f.status", .string("all")); dismiss()
                        }
                    }
                }
            }
        }
    }

    private func icon(_ k: String) -> String {
        ["all": "books.vertical", "reading": "book", "want": "bookmark", "done": "checkmark.circle", "dnf": "xmark.circle", "paused": "pause.circle", "lent": "hand.raised"][k] ?? "book"
    }

    private func count(_ k: String, _ st: AppState) -> Int {
        switch k {
        case "all": return st.books.count
        case "lent": return st.books.filter { $0.format == .physical && ($0.loan.bool("lent") || $0.loan.bool("borrowed")) }.count
        default: return st.books.filter { $0.status.rawValue == k }.count
        }
    }
}

/// «تحديث التقدم»: the volume (for a series) and where you are, in pages, chapters or time.
struct QuickProgress: View {
    let bookID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var vi = 0
    @State private var pos: Double = 0
    @State private var err = ""
    @State private var loaded = false

    var body: some View {
        if let b = lib.state.book(bookID) {
            JSheet(title: "تحديث التقدم", subtitle: b.title) {
                if b.series {
                    JLabel(text: "المجلد")
                    Picker("المجلد", selection: $vi) {
                        ForEach(b.volumes.indices, id: \.self) { i in
                            Text("المجلد \(i + 1)" + (b.volumes[i].title.isEmpty ? "" : " · " + b.volumes[i].title)).tag(i)
                        }
                    }
                    .pickerStyle(.menu).tint(Color(L.ink))
                }
                let total = b.volumes.indices.contains(vi) ? b.volumes[vi].total : nil
                JLabel(text: b.unit.time ? "وين وصلت (ساعات ودقائق)" : "وين وصلت (" + b.unit.name + ")")
                PositionField(unitTime: b.unit.time, value: $pos, total: total)
                if let t = total { Text("من " + b.uv(t)).font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
                if !err.isEmpty { Text(err).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
                Button { afterEditing(save) } label: { Text("حفظ").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true; vi = b.vi; pos = b.pos
            }
        }
    }

    private func save() {
        if let e = ProgressRules.save(bookID, vi: vi, pos: pos) { err = e; return }
        dismiss()
    }
}

/// A position: a number with − and + (pages, chapters), or hours and minutes (audio by time).
struct PositionField: View {
    let unitTime: Bool
    @Binding var value: Double
    var total: Double?
    @Environment(\.look) private var L

    var body: some View {
        if unitTime {
            HStack(spacing: 10) {
                numberBox(Binding(get: { Double(Int(value) / 60) }, set: { value = $0 * 60 + Double(Int(value) % 60) }), label: "ساعات")
                Text(":").font(JFont.body(20, .medium))
                numberBox(Binding(get: { Double(Int(value) % 60) }, set: { value = Double(Int(value) / 60) * 60 + min(59, $0) }), label: "دقائق")
            }
            .environment(\.layoutDirection, .leftToRight)
        } else {
            HStack(spacing: 10) {
                stepButton("minus") { value = max(0, value - 1) }
                numberBox($value, label: "الموضع")
                stepButton("plus") { value = total.map { min($0, value + 1) } ?? value + 1 }
            }
        }
    }

    private func numberBox(_ v: Binding<Double>, label: String) -> some View {
        TextField(label, value: v, format: .number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
            .keyboardType(.numberPad).multilineTextAlignment(.center).font(JFont.body(20, .medium)).monospacedDigit()
            .frame(height: 48).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
            .accessibilityLabel(label)
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { action(); Haptics.play("sel") }) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Color(L.ink))
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// «أضف إلى «…»»: a quote, a thought, a character, a word, or the progress.
struct AddNoteMenu: View {
    let bookID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @State private var progress = false

    var body: some View {
        let b = lib.state.book(bookID)
        JSheet(title: "أضف إلى «" + (b?.title ?? "") + "»") {
            VStack(spacing: 0) {
                JMenuRow(icon: "quote.opening", title: "اقتباس", sub: "جملة أعجبتك") { dismiss(); Flows.note(bookID, kind: "quote") }
                JMenuRow(icon: "lightbulb", title: "فكرة", sub: "شي خطر في بالك وأنت تقرأ") { dismiss(); Flows.note(bookID, kind: "thought") }
                JMenuRow(icon: "person", title: "شخصية", sub: "اسمها ووصفها وعلاقاتها") { dismiss(); Flows.note(bookID, kind: "char") }
                JMenuRow(icon: "character.book.closed", title: "كلمة", sub: "كلمة جديدة ومعناها") { dismiss(); Flows.note(bookID, kind: "word") }
                if let b = b, !b.isNovel {
                    JMenuRow(icon: "flag", title: "تحديث التقدم", sub: b.posLabel) { progress = true }
                }
            }
        }
        .sheet(isPresented: $progress, onDismiss: { dismiss() }) { QuickProgress(bookID: bookID).presentationDetents([.medium]) }
    }
}
