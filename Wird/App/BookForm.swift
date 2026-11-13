import SwiftUI
import UIKit
import PhotosUI

// The book form (inventory-1, section 3.1): add a book (search online, barcode, by hand) or edit one.

enum Vocab {
    static let genres = ["رواية", "غموض", "جريمة", "رعب", "فانتازيا", "خيال علمي", "دراما", "رومانسي", "كوميدي", "تاريخي", "مغامرة", "ستيم بانك",
                         "فلسفة", "ديني", "تطوير ذات", "سيرة", "شعر", "علوم", "روايات ويب", "مانجا وكوميكس"]
    static let platforms = ["Apple Books", "Kindle", "أبجد", "كتبي", "Google Play Books", "Storytel", "Audible", "الرف", "موقع روايات ويب"]
    static let shops = ["مكتبة جرير", "مكتبة العبيكان", "معرض الكتاب", "أمازون", "نيل وفرات"]
    static let speeds: [Double] = [1, 1.25, 1.5, 1.75, 2]
    static let moods = ["مشوّق", "مظلم", "مضحك", "عاطفي", "ملهم", "غامض", "متوتر", "حزين", "هادئ", "مغامر", "عميق", "خفيف"]
}

@MainActor
final class BookFormModel: ObservableObject {
    let editing: Bool
    @Published var b: Book
    @Published var start: Date?
    @Published var finish: Date?
    @Published var openBuy: Bool
    @Published var openDims: Bool
    @Published var q = ""
    @Published var results: [BookLookup.Item]?
    @Published var showAll = false
    @Published var busy = false
    @Published var errs: [String] = []
    @Published var err = ""
    @Published var newGenre = ""
    @Published var newCol = ""
    /// pictures made while the form is open (deleted if it closes without saving)
    var newImgs: [String] = []
    /// the format was chosen by hand (an edition does not change it then)
    var formatSet = false
    /// the cover came from your own photo (the edition picker asks before replacing it)
    var ownCover = false
    private let original: Data?
    private let old: (cover: String?, spine: String?)
    var saved = false

    init(bookID: String?) {
        let book: Book
        if let id = bookID, let found = Library.shared.state.book(id) {
            editing = true
            book = Book(Library.fixBook(found.raw))
        } else {
            editing = false
            book = Book(Library.fixBook(Library.blankBook()))
        }
        b = book
        start = book.start.map(Millis.date)
        finish = book.finish.map(Millis.date)
        let p = book.purchase
        openBuy = !p.str("where").isEmpty || !p.str("price").isEmpty || !p.str("date").isEmpty || p.bool("gift")
        openDims = book.dims != nil
        old = (book.cover, book.spine)
        original = JSONValue.object(book.raw).data()
    }

    var dirty: Bool { !saved && (JSONValue.object(b.raw).data() != original || !newImgs.isEmpty) }

    func discard() {
        guard !saved else { return }
        for id in newImgs { Library.shared.deleteImage(id) }
        newImgs = []
    }

    // MARK: search

    func runSearch() async -> Bool {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if !(await BookLookup.isbn(text)).isEmpty { return true }
        busy = true; results = nil; showAll = false; err = ""; errs = []
        let r = await BookLookup.search(text)
        busy = false
        results = r.list
        errs = r.errs
        if r.list.isEmpty && r.errs.count >= 3 { err = "تعذّر البحث، تأكد من الإنترنت." }
        return false
    }

    /// The chosen edition into the form (applyEdition): title, author, language, ISBN, length, format; the cover too.
    func apply(_ e: BookLookup.Item, coverOnly: Bool, keepCover: Bool) async {
        if !coverOnly {
            if let t = e["title"] as? String, !t.isEmpty { b.title = t }
            if let a = e["author"] as? String, !a.isEmpty, b.author.isEmpty || (e["src"] as? String) != "ol" { b.author = a }
            let lg = (e["lang"] as? String) ?? ""
            if Words.langs.contains(where: { $0.0 == lg }) { b.lang = lg }
            if let i = e["isbn"] as? String, !i.isEmpty { b.isbn = i }
            let pages = (e["pages"] as? Double) ?? Double(NovelBridge.num(e["pages"]))
            if !b.series, pages > 0, (e["approx"] as? Bool) != true, b.unit == .page { setTotal(0, pages.rounded()) }
            let minutes = (e["minutes"] as? Double) ?? Double(NovelBridge.num(e["minutes"]))
            if !b.series, minutes > 0, b.unit.time { setTotal(0, minutes) }
            let fmt = ((e["format"] as? String) ?? "").lowercased()
            if !formatSet {
                if (fmt.contains("kindle") || fmt.contains("ebook")) && b.format == .physical { b.format = .ebook }
                if fmt.contains("audio") { b.format = .audio; b.audioBy = "time" }
            }
            results = nil
        }
        let cover = (e["cover"] as? String) ?? "", thumb = e["thumb"] as? String
        if !cover.isEmpty && !keepCover {
            ToastCenter.shared.show("أجيب الغلاف…")
            var url = cover
            if (e["src"] as? String) == "abj", let u = e["url"] as? String {
                let x = await BookLookup.page(u)
                if let c = x["cover"] as? String, !c.isEmpty { url = c }
            }
            if let img = await BookLookup.coverImage(url, fallback: thumb) {
                setImage(img, kind: "cover")
                ToastCenter.shared.show("تم وضع الغلاف، راجع البيانات")
            } else {
                ToastCenter.shared.show("ما قدرت أجيب الغلاف، جرّب غلافًا ثانيًا")
            }
        } else {
            ToastCenter.shared.show(coverOnly ? "هذي الطبعة ما لها غلاف" : "تمت تعبئة البيانات، راجعها")
        }
    }

    // MARK: pictures

    func setImage(_ img: UIImage, kind: String) {
        let maxSide: CGFloat = kind == "spine" ? 1300 : 1100
        let fitted = img.resized(maxSide: maxSide)
        guard let id = Library.shared.putImage(fitted) else { return }
        newImgs.append(id)
        let ratio = fitted.size.height > 0 ? Double(fitted.size.width / fitted.size.height) : nil
        if kind == "spine" {
            b.spine = id
            b.spineRatio = ratio
        } else {
            b.cover = id
            b.coverRatio = ratio
            b.color = fitted.averageHSL()
        }
    }

    func clearImage(_ kind: String) {
        if kind == "spine" { b.spine = nil; b.spineRatio = nil } else { b.cover = nil; b.coverRatio = nil; b.color = nil }
    }

    // MARK: lengths

    func total(_ i: Int) -> Double? { b.volumes.indices.contains(i) ? b.volumes[i].total : nil }

    func setTotal(_ i: Int, _ v: Double?) {
        var vols = b.volumes
        guard vols.indices.contains(i) else { return }
        vols[i].total = (v ?? 0) > 0 ? v : nil
        b.volumes = vols
    }

    func setVolumeTitle(_ i: Int, _ t: String) {
        var vols = b.volumes
        guard vols.indices.contains(i) else { return }
        vols[i].title = t
        b.volumes = vols
    }

    func addVolume() { b.volumes = b.volumes + [Volume.blank()] }
    func deleteVolume(_ i: Int) { var v = b.volumes; if v.count > 1 { v.remove(at: i); b.volumes = v; b.vi = min(b.vi, v.count - 1) } }

    // MARK: saving (saveBookDraft)

    func save() -> Bool {
        var x = b
        x.title = x.title.trimmingCharacters(in: .whitespacesAndNewlines)
        x.author = x.author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.title.isEmpty else { err = "اكتب عنوان الكتاب."; return false }
        if !x.series { x.volumes = Array(x.volumes.prefix(1)) }
        x.volumes = x.volumes.map { v in var v = v; v.total = (v.total ?? 0) > 0 ? (x.unit.time ? v.total : v.total?.rounded()) : nil; return v }
        if !x.series && x.unit == .page && x.volumes.first?.total == nil { err = "اكتب عدد الصفحات."; return false }
        if x.unit == .page { x.ongoing = false }
        x.link = x.isNovel ? x.link : ""
        x.vi = min(max(0, x.vi), max(0, x.volumes.count - 1))
        x.pos = max(0, x.pos.rounded())
        if let t = x.volumes[x.vi].total, x.pos > t {
            err = x.unit.time ? "الوقت اللي وصلت له أكبر من مدة الكتاب (\(Words.hm(t)))." : "رقم \(x.unit.name) أكبر من العدد الكلي (\(Int(t)))."
            return false
        }
        if !x.isAudio { x.audioBy = "time" }
        if !Vocab.speeds.contains(x.speed) { x.speed = 1 }
        x.start = start.map(Millis.ms)
        x.finish = finish.map(Millis.ms) ?? (x.status == .done ? Millis.now : nil)
        if x.status != .done { x.finish = nil }
        if x.status == .done, let s = x.start, let f = x.finish, f < s { err = "تاريخ الانتهاء قبل تاريخ البدء."; return false }
        if x.status == .done { x.vi = max(0, x.volumes.count - 1); x.pos = x.volumes.last?.total ?? x.pos }
        if x.status == .want { x.pos = 0; x.vi = 0 }
        if x.status != .done && x.status != .dnf { x.rating = 0 }
        if (x.status == .reading || x.status == .dnf) && x.start == nil { x.start = Millis.now }
        if x.format != .physical {
            x.purchase = Library.blankBook().obj("purchase")
            var l = x.loan; l.set("lent", false); l.set("borrowed", false); x.loan = l
        } else if !openBuy {
            x.purchase = Library.blankBook().obj("purchase")
        }
        if x.format == .physical { x.platform = "" }
        if !x.isAudio { x.narrator = "" }
        if !x.translated { x.translator = "" }
        if !openDims { x.dims = nil }
        if let c = old.cover, c != x.cover { Library.shared.deleteImage(c) }
        if let s = old.spine, s != x.spine { Library.shared.deleteImage(s) }
        let book = Book(Library.fixBook(x.raw))
        if editing {
            Library.shared.change { st in if let i = st.index(of: book.id) { st.books[i] = book } }
        } else {
            Library.shared.change { $0.books.append(book) }
            CarouselCenter.shared.id = book.id
        }
        saved = true
        Achievements.check()
        WidgetFeed.update()
        if !editing { Router.shared.select(.library) }
        ToastCenter.shared.show(editing ? "تم حفظ التعديلات" : "تمت إضافة الكتاب")
        return true
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let w = size.width * scale, h = size.height * scale, side = max(w, h)
        guard side > maxSide else { return self }
        let k = maxSide / side
        let s = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: s, format: f).image { _ in draw(in: CGRect(origin: .zero, size: s)) }
    }
}

struct BookFormView: View {
    @StateObject private var m: BookFormModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var askLeave = false
    @State private var editions: EditionsRequest?
    @State private var coverSearch = false
    @State private var photo: PhotoTarget?
    @State private var crop: CropRequest?
    @State private var dims = false
    @State private var browse: BrowseRequest?

    init(bookID: String?) { _m = StateObject(wrappedValue: BookFormModel(bookID: bookID)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !m.editing { searchSection }
                    imagesSection
                    group("طريقة التقدم") { progressMethod }
                    group("الصيغة") {
                        JSeg(options: [(BookFormat.physical, "ملموس"), (.ebook, "إلكتروني"), (.audio, "صوتي")],
                             value: Binding(get: { m.b.format }, set: { m.b.format = $0; m.formatSet = true; if $0 == .audio && m.b.audioBy.isEmpty { m.b.audioBy = "time" } }))
                    }
                    group("التفاصيل") { details }
                    group("التصنيفات") { genres }
                    group("المجموعات") { collections }
                    group("الحالة") { status }
                    if m.b.format == .physical { group("الشراء") { purchase } }
                    if m.b.format == .ebook || m.b.format == .audio {
                        group("المنصة") { field("المنصة (اختياري)", $m.b.platform, suggestions: Vocab.platforms) }
                    }
                    group("الشكل على الرف") {
                        Button { dims = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("أبعاد الكتاب والكعب").font(JFont.body(15.5, .medium)).foregroundStyle(Color(L.ink))
                                    Text(dimsText).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                                }
                                Spacer()
                                Image(systemName: "chevron.backward").foregroundStyle(Color(L.ink2))
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                        }
                        .buttonStyle(.plain)
                    }
                    if !m.err.isEmpty { Text(m.err).font(JFont.body(14.5)).foregroundStyle(Color(L.danger)).id("err") }
                    Button { if m.save() { dismiss() } } label: { Text(m.editing ? "حفظ التعديلات" : "إضافة الكتاب").frame(maxWidth: .infinity) }
                        .buttonStyle(JButtonStyle(look: L, primary: true))
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(L.surface).ignoresSafeArea())
            .navigationTitle(m.editing ? "تعديل الكتاب" : "إضافة كتاب")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel("إغلاق")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { if m.save() { dismiss() } } label: { Image(systemName: "checkmark") }.accessibilityLabel("حفظ")
                }
            }
        }
        .tint(Color(L.primary))
        .interactiveDismissDisabled(m.dirty)
        .confirmationDialog(m.editing ? "تترك التعديلات؟" : "تترك الإضافة؟", isPresented: $askLeave, titleVisibility: .visible) {
            Button("اطلع بدون حفظ", role: .destructive) { m.discard(); dismiss() }
            Button("أكمل", role: .cancel) {}
        } message: {
            Text(m.editing ? "التغييرات اللي سويتها ما انحفظت، وبتروح إذا طلعت." : "اللي كتبته ما انحفظ، وبيروح إذا طلعت.")
        }
        .sheet(item: $editions) { r in
            EditionsSheet(request: r) { e, keep in Task { await m.apply(e, coverOnly: false, keepCover: keep) } }
                .environment(\.look, L).environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(isPresented: $coverSearch) {
            CoverSearchSheet(query: m.b.isbn.isEmpty || !m.b.title.isEmpty ? (m.b.title + " " + m.b.author).trimmingCharacters(in: .whitespaces) : m.b.isbn) { e in
                Task { await m.apply(e, coverOnly: true, keepCover: false) }
            }
            .environment(\.look, L).environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(item: $photo) { t in
            ImageSource(target: t) { img in
                photo = nil
                if let i = img { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { crop = CropRequest(image: i, kind: t.kind) } }
            }
        }
        .fullScreenCover(item: $crop) { r in
            CropView(request: r) { img in
                crop = nil
                if let i = img { m.setImage(i, kind: r.kind); if r.kind == "cover" { m.ownCover = true } }
            }
        }
        .sheet(isPresented: $dims) {
            DimsSheet(model: m).environment(\.look, L).environment(\.layoutDirection, .rightToLeft)
        }
        .fullScreenCover(item: $browse) { r in
            BrowserImport(request: r) { data in
                browse = nil
                if let d = data { Task { await m.apply(d, coverOnly: r.coverOnly, keepCover: false) } }
            }
        }
        .onDisappear { if !m.saved { m.discard() } }
        .onReceive(NotificationCenter.default.publisher(for: .formScan)) { _ in scan() }
        .onReceive(NotificationCenter.default.publisher(for: .formQuery)) { n in if let q = n.object as? String { m.q = q; search() } }
    }

    private func close() { if m.dirty { askLeave = true } else { m.discard(); dismiss() } }

    private var dimsText: String {
        if m.openDims, let d = m.b.dims {
            return String(format: "%.1f × %.1f × %.1f سم", d.num("h"), d.num("w"), d.num("t"))
        }
        return "تلقائي، حسب نسبة صورة الغلاف بدون مطّ"
    }

    // MARK: sections

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(JFont.display(18, .semibold)).foregroundStyle(Color(L.ink))
            content()
        }
    }

    private var searchSection: some View {
        group("البحث بالإنترنت") {
            HStack(spacing: 8) {
                TextField("اسم الكتاب أو المؤلف أو ISBN", text: $m.q).font(JFont.body(16)).submitLabel(.search).onSubmit { search() }
                    .padding(.horizontal, 12).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                Button(m.busy ? "أبحث…" : "ابحث") { search() }.buttonStyle(JButtonStyle(look: L, primary: true)).disabled(m.busy)
                Button { scan() } label: { Image(systemName: "barcode.viewfinder").font(.system(size: 20)) }
                    .buttonStyle(JButtonStyle(look: L)).accessibilityLabel("مسح باركود الكتاب")
            }
            if m.results == nil && !m.busy { Text("أو امسح باركود الكتاب من زر الباركود.").font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
            if let res = m.results { results(res) }
        }
    }

    private func search() {
        Task {
            if await m.runSearch() {
                editions = EditionsRequest(isbn: await BookLookup.isbn(m.q), q: "", seed: nil)
            }
        }
    }

    private func scan() {
        guard let h = NovelBridge.host else { return }
        let s = BarcodeScanner()
        ScanKeeper.current = s
        s.present(from: NovelBridge.top(h)) { code in
            ScanKeeper.current = nil
            guard let c = code as? String else { if code == nil { ToastCenter.shared.show("تعذّر فتح الكاميرا") }; return }
            let isbn = BookLookup.clean(c)
            guard !isbn.isEmpty else { return }
            Haptics.play("success")
            m.b.isbn = isbn
            editions = EditionsRequest(isbn: isbn, q: "", seed: nil)
        }
    }

    @ViewBuilder private func results(_ res: [BookLookup.Item]) -> some View {
        if res.isEmpty {
            Text("ما لقيت نتائج" + (m.errs.isEmpty ? "" : " (ما وصلت لـ " + m.errs.joined(separator: "، ") + ")") + ". تأكد من الكتابة، أو امسح الباركود، أو دوّر عليه بنفسك:")
                .font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
        } else {
            let more = res.count - 6
            let shown = m.showAll || more <= 1 ? res : Array(res.prefix(6))
            VStack(spacing: 0) {
                ForEach(shown.indices, id: \.self) { i in
                    ResultRow(item: shown[i]) { editions = EditionsRequest(isbn: "", q: "", seed: shown[i]) }
                }
            }
            if more > 1 {
                Button(m.showAll ? "إخفاء" : "إظهار " + Words.cnt(Double(more), ["نتيجة واحدة", "نتيجتان", "نتائج", "نتيجة"])) { m.showAll.toggle() }
                    .font(JFont.body(14, .medium)).foregroundStyle(Color(L.primary))
            }
            if !m.errs.isEmpty { Text("ما وصلت لـ " + m.errs.joined(separator: "، ") + "، والنتائج من الباقي.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)) }
            Text("اختر الأقرب، وبعدها تختار طبعتك وغلافها. ما لقيت نسختك؟ دوّر عليها بنفسك:").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
        }
        SiteChips { site in browse = BrowseRequest(query: m.q, site: site, coverOnly: false) }
    }

    private var imagesSection: some View {
        group("الصور") {
            HStack(alignment: .top, spacing: 14) {
                tile(kind: "spine", width: 34, height: 150, id: m.b.spine, caption: "الكعب", icon: "plus")
                tile(kind: "cover", width: 100, height: 150, id: m.b.cover, caption: "الغلاف", icon: "camera")
                VStack(alignment: .leading, spacing: 8) {
                    Text("من صورك أو بالكاميرا، وبعدها تقصّها. الكعب يظهر في الرفوف، وبدونه أصمم له كعبًا من لون الغلاف.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
                    Button { coverSearch = true } label: { Label(m.b.cover == nil ? "غلاف من الإنترنت" : "غلاف ثاني من الإنترنت", systemImage: "globe") }
                        .buttonStyle(JButtonStyle(look: L, small: true))
                }
            }
            HStack(spacing: 8) {
                if let c = m.b.cover, let img = Library.shared.image(c) {
                    Button("قص الغلاف") { crop = CropRequest(image: img, kind: "cover") }.buttonStyle(JButtonStyle(look: L, small: true))
                    Button("إزالته") { m.clearImage("cover") }.buttonStyle(JButtonStyle(look: L, small: true)).foregroundStyle(Color(L.danger))
                }
                if let s = m.b.spine, let img = Library.shared.image(s) {
                    Button("قص الكعب") { crop = CropRequest(image: img, kind: "spine") }.buttonStyle(JButtonStyle(look: L, small: true))
                    Button("إزالته") { m.clearImage("spine") }.buttonStyle(JButtonStyle(look: L, small: true)).foregroundStyle(Color(L.danger))
                }
            }
        }
    }

    private func tile(kind: String, width: CGFloat, height: CGFloat, id: String?, caption: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Button { photo = PhotoTarget(kind: kind) } label: {
                ZStack {
                    if let i = Library.shared.image(id) {
                        Image(uiImage: i).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Color(L.line))
                        Image(systemName: icon).foregroundStyle(Color(L.ink2))
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(kind == "spine" ? "صورة الكعب" : "صورة الغلاف")
            Text(caption).font(JFont.body(12)).foregroundStyle(Color(L.ink2))
        }
    }

    @ViewBuilder private var progressMethod: some View {
        if m.b.isAudio {
            JSeg(options: [("time", "بالوقت"), ("chapters", "بالفصول")], value: $m.b.audioBy)
            if m.b.unit.time {
                JLabel(text: "سرعة الاستماع المعتادة")
                JSeg(options: Vocab.speeds.map { ($0, "×" + ($0 == $0.rounded() ? String(Int($0)) : String($0))) }, value: $m.b.speed)
            }
        } else {
            JSeg(options: [("volume", "بالصفحات"), ("chapters", "بالفصول")], value: $m.b.structure)
        }
        Text(m.b.unit.time ? "مدة الكتاب ثابتة، والتقديرات تُحسب منها ومن سرعة الاستماع، مو من سرعة قراءتك."
                           : "تسجّل وين وصلت ب" + (m.b.unit == .page ? "رقم الصفحة" : "رقم الفصل") + "، والتقديرات تُحسب من سرعتك.")
            .font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
    }

    @ViewBuilder private var details: some View {
        field("العنوان *", $m.b.title)
        field("المؤلف", $m.b.author)
        if m.b.isAudio { field("الراوي (اختياري)", $m.b.narrator) }
        langPicker("لغة الكتاب", $m.b.lang)
        JSwitchRow(title: "مترجم", sub: "إذا ما هو بلغته الأصلية", on: $m.b.translated)
        if m.b.translated {
            langPicker("مترجم من", $m.b.origLang)
            field("المترجم (اختياري)", $m.b.translator)
        }
        JSwitchRow(title: "مقسّم لمجلدات (سلسلة)", sub: "مثل هاري بوتر، أو رواية ويب لها مجلدات", on: $m.b.series)
        length
    }

    @ViewBuilder private var length: some View {
        if m.b.series {
            ForEach(m.b.volumes.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(JFont.body(14, .semibold)).foregroundStyle(Color(L.ink2)).frame(width: 22)
                    TextField("اسم المجلد (اختياري)", text: Binding(get: { m.b.volumes.indices.contains(i) ? m.b.volumes[i].title : "" }, set: { m.setVolumeTitle(i, $0) }))
                        .font(JFont.body(15)).padding(.horizontal, 10).frame(height: 44).background(RoundedRectangle(cornerRadius: 10).fill(Color(L.bg)))
                    numberField(m.b.unit.time ? "دقائق" : (m.b.unit == .page ? "صفحات" : "فصول"), Binding(get: { m.total(i) }, set: { m.setTotal(i, $0) })).frame(width: 90)
                    if m.b.volumes.count > 1 {
                        Button { m.deleteVolume(i) } label: { Image(systemName: "xmark").foregroundStyle(Color(L.ink2)) }.buttonStyle(.plain).accessibilityLabel("حذف المجلد")
                    }
                }
            }
            Button { m.addVolume() } label: { Label("مجلد", systemImage: "plus") }.buttonStyle(JButtonStyle(look: L, small: true))
        } else if m.b.unit.time {
            JLabel(text: "مدة الكتاب")
            DurationField(minutes: Binding(get: { m.total(0) ?? 0 }, set: { m.setTotal(0, $0) }))
        } else {
            JLabel(text: m.b.unit == .page ? "عدد الصفحات *" : "عدد الفصول")
            numberField(m.b.unit == .page ? "صفحات" : "فصول", Binding(get: { m.total(0) }, set: { m.setTotal(0, $0) }))
            if m.b.unit == .chapter {
                JSwitchRow(title: "مستمرة (العدد الكلي غير معروف)", sub: "تكتب رقم فصلك فقط، وتضيف العدد متى ما عرفته", on: $m.b.ongoing)
            }
        }
    }

    private var genres: some View {
        let all = Vocab.genres + m.b.genres.filter { !Vocab.genres.contains($0) }
        return VStack(alignment: .leading, spacing: 10) {
            Flow(spacing: 8) {
                ForEach(all, id: \.self) { g in JChip(look: L, text: g, on: m.b.genres.contains(g)) { toggle(&m.b.genres, g) } }
            }
            addTag("تصنيف جديد", $m.newGenre) { m.b.genres.append($0) }
        }
    }

    private var collections: some View {
        let all = Array(Set(Library.shared.state.allCols.keys).union(m.b.cols)).sorted()
        return VStack(alignment: .leading, spacing: 10) {
            Text("قوائمك الخاصة، مثل «مكتبة البيت» أو «أقرأها قريبًا».").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
            if !all.isEmpty {
                Flow(spacing: 8) { ForEach(all, id: \.self) { c in JChip(look: L, text: c, on: m.b.cols.contains(c)) { toggle(&m.b.cols, c) } } }
            }
            addTag("مجموعة جديدة", $m.newCol) { m.b.cols.append($0) }
        }
    }

    private func toggle(_ list: inout [String], _ v: String) {
        if let i = list.firstIndex(of: v) { list.remove(at: i) } else { list.append(v) }
        Haptics.play("sel")
    }

    private func addTag(_ placeholder: String, _ text: Binding<String>, add: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text).font(JFont.body(15)).padding(.horizontal, 12).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            Button("إضافة") {
                let v = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty else { return }
                add(v); text.wrappedValue = ""
            }
            .buttonStyle(JButtonStyle(look: L, small: true))
        }
    }

    @ViewBuilder private var status: some View {
        JSeg(options: [(BookStatus.want, "أريد قراءته"), (.reading, m.b.isAudio ? "أستمع له" : "أقرأه الآن"), (.done, "أنهيته"), (.dnf, "توقفت")], value: $m.b.status)
        if m.b.status == .reading || m.b.status == .dnf {
            if m.b.series {
                Picker("المجلد الحالي", selection: $m.b.vi) {
                    ForEach(m.b.volumes.indices, id: \.self) { i in Text("المجلد \(i + 1)" + (m.b.volumes[i].title.isEmpty ? "" : " · " + m.b.volumes[i].title)).tag(i) }
                }
                .pickerStyle(.menu)
            }
            if m.b.unit.time {
                JLabel(text: "وصلت إلى")
                DurationField(minutes: $m.b.pos)
            } else {
                JLabel(text: m.b.unit == .page ? "الصفحة الحالية" : "الفصل الحالي")
                numberField("", Binding(get: { m.b.pos }, set: { m.b.pos = $0 ?? 0 }))
            }
        }
        if m.b.status != .want {
            DatePicker("تاريخ البدء", selection: Binding(get: { m.start ?? Date() }, set: { m.start = $0 }), displayedComponents: .date)
                .font(JFont.body(15)).environment(\.locale, Locale(identifier: "ar@numbers=latn"))
        }
        if m.b.status == .done {
            DatePicker("تاريخ الانتهاء", selection: Binding(get: { m.finish ?? Date() }, set: { m.finish = $0 }), displayedComponents: .date)
                .font(JFont.body(15)).environment(\.locale, Locale(identifier: "ar@numbers=latn"))
        }
        if m.b.status == .done || m.b.status == .dnf {
            HStack { Text("تقييمك").font(JFont.body(15)); Spacer(); JStars(value: $m.b.rating) }
        }
    }

    @ViewBuilder private var purchase: some View {
        JSwitchRow(title: "أضف تفاصيل الشراء (اختياري)", on: $m.openBuy)
        if m.openBuy {
            JSwitchRow(title: "هدية", on: Binding(get: { m.b.purchase.bool("gift") }, set: { v in var p = m.b.purchase; p.set("gift", v); m.b.purchase = p }))
            if m.b.purchase.bool("gift") {
                field("من أهداه لك", purchaseBinding("giftFrom"))
            } else {
                field("من وين اشتريته", purchaseBinding("where"), suggestions: Vocab.shops)
                field("بكم (ر.س)", purchaseBinding("price"), keyboard: .decimalPad)
                field("تاريخ الشراء (yyyy-mm-dd)", purchaseBinding("date"), keyboard: .numbersAndPunctuation)
            }
        }
    }

    private func purchaseBinding(_ k: String) -> Binding<String> {
        Binding(get: { m.b.purchase.str(k) }, set: { v in var p = m.b.purchase; p.set(k, v); m.b.purchase = p })
    }

    // MARK: fields

    private func field(_ label: String, _ text: Binding<String>, suggestions: [String] = [], keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            JLabel(text: label)
            TextField("", text: text).font(JFont.body(16)).keyboardType(keyboard)
                .padding(.horizontal, 12).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(suggestions, id: \.self) { s in JChip(look: L, text: s, on: text.wrappedValue == s) { text.wrappedValue = s } } }
                }
            }
        }
    }

    private func numberField(_ placeholder: String, _ v: Binding<Double?>) -> some View {
        TextField(placeholder, value: v, format: .number.grouping(.never)).keyboardType(.numberPad).font(JFont.body(16)).monospacedDigit()
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    private func langPicker(_ label: String, _ v: Binding<String>) -> some View {
        HStack {
            Text(label).font(JFont.body(15)).foregroundStyle(Color(L.ink))
            Spacer()
            Picker(label, selection: v) { ForEach(Words.langs, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.menu)
        }
        .frame(minHeight: 44)
    }
}

/// Hours and minutes, kept as one number of minutes.
struct DurationField: View {
    @Binding var minutes: Double
    @Environment(\.look) private var L

    var body: some View {
        HStack(spacing: 8) {
            box(Binding(get: { Double(Int(minutes) / 60) }, set: { minutes = max(0, $0) * 60 + Double(Int(minutes) % 60) }), "س")
            box(Binding(get: { Double(Int(minutes) % 60) }, set: { minutes = Double(Int(minutes) / 60) * 60 + min(59, max(0, $0)) }), "د")
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func box(_ v: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 6) {
            TextField("0", value: v, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.center).font(JFont.body(17)).monospacedDigit()
            Text(unit).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
        }
        .padding(.horizontal, 10).frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        .accessibilityLabel(unit == "س" ? "ساعات" : "دقائق")
    }
}

/// One search result: its small cover, title, author, pages, year, language and source.
struct ResultRow: View {
    let item: BookLookup.Item
    let pick: () -> Void
    @Environment(\.look) private var L

    var body: some View {
        let th = (item["thumb"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (item["cover"] as? String) ?? ""
        let pages = NovelBridge.num(item["pages"])
        let bits = [(item["author"] as? String) ?? "", pages > 0 ? ((item["approx"] as? Bool) == true ? "≈ " : "") + "\(pages) صفحة" : "", (item["year"] as? String) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let src = [Words.lang((item["lang"] as? String) ?? ""), BookLookup.sourceNames[(item["src"] as? String) ?? ""] ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        Button(action: pick) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: th)) { i in i.resizable().scaledToFill() } placeholder: { Color(L.surface2) }
                    .frame(width: 46, height: 68).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text((item["title"] as? String) ?? "").font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(2)
                    if !bits.isEmpty { Text(bits).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).lineLimit(1) }
                    if !src.isEmpty { Text(src).font(JFont.body(11.5)).foregroundStyle(Color(L.ink2)) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }
}

/// Quick ways into the small browser, straight to a book site.
struct SiteChips: View {
    let open: (Int) -> Void
    @Environment(\.look) private var L
    private static let sites: [(String, Int)] = [("Goodreads", 0), ("أبجد", 2), ("أمازون", 3), ("Google Books", 1), ("جملون", 5), ("صور Google", 6)]

    var body: some View {
        Flow(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(Color(L.ink2)).frame(height: 34)
            ForEach(Self.sites, id: \.1) { s in JChip(look: L, text: s.0) { open(s.1) } }
        }
    }
}
