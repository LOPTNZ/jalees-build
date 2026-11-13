import SwiftUI
import UIKit

// A book's page (inventory-1, section 2.5): the hero, status and progress, volumes, the target date, the review,
// the notes, the sessions, the reads, the details, lending, and the actions.

extension Words {
    static let langs: [(String, String)] = [("ar", "العربية"), ("en", "الإنجليزية"), ("fr", "الفرنسية"), ("ja", "اليابانية"), ("zh", "الصينية"), ("ko", "الكورية"),
                                            ("es", "الإسبانية"), ("de", "الألمانية"), ("ru", "الروسية"), ("tr", "التركية"), ("fa", "الفارسية"), ("other", "لغة أخرى")]
    static func lang(_ code: String) -> String { langs.first { $0.0 == code }?.1 ?? "" }
    static let paces: [String: String] = ["slow": "بطيء", "mid": "متوسط", "fast": "سريع"]
}

struct BookPage: View {
    let bookID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: Sheet?
    @State private var openReads: Set<Int> = []
    @State private var askDelete = false

    enum Sheet: Identifiable {
        case progress, target, note, list(String), session(String)
        var id: String {
            switch self {
            case .progress: return "p"
            case .target: return "t"
            case .note: return "n"
            case .list(let k): return "l" + k
            case .session(let s): return "s" + s
            }
        }
    }

    var body: some View {
        Group {
            if let b = lib.state.book(bookID) { page(b) } else { Color(L.bg).ignoresSafeArea() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .progress: QuickProgress(bookID: bookID).presentationDetents([.medium])
                case .target: TargetSheet(bookID: bookID).presentationDetents([.medium])
                case .note: AddNoteMenu(bookID: bookID).presentationDetents([.medium, .large])
                case .list(let k): ItemListSheet(bookID: bookID, kind: k)
                case .session(let sid): SessionEditSheet(sessionID: sid).presentationDetents([.medium])
                }
            }
            .environment(\.look, L)
            .environment(\.layoutDirection, .rightToLeft)
        }
        .confirmationDialog("حذف الكتاب؟", isPresented: $askDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { deleteBook() }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("ينحذف مع جلساته وكل ما في دفتره. تقدر تتراجع خلال ثواني.") }
    }

    private func page(_ b: Book) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero(b)
                VStack(alignment: .leading, spacing: 24) {
                    statusSection(b)
                    if b.status == .done || !b.review.isEmpty || !b.moods.isEmpty { reviewSection(b) }
                    notes(b, .quote, "الاقتباسات", 2, "ما فيه اقتباسات بعد.")
                    notes(b, .thought, "الأفكار", 2, "سجّل الأفكار اللي يلهمك فيها النص.")
                    notes(b, .char, "الشخصيات", 4, "أضف الشخصيات عشان تتذكر الكتاب أكثر.")
                    notes(b, .word, "الكلمات", 2, "أضف الكلمات الجديدة اللي تمر عليك.")
                    sessionsSection(b)
                    if !b.history.isEmpty { readsSection(b) }
                    detailsSection(b)
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 40)
        }
        .background(Color(L.bg).ignoresSafeArea())
    }

    // MARK: hero

    private func hero(_ b: Book) -> some View {
        let tint = UIColor.hslParts(b.hslString) ?? L.primary
        return VStack(alignment: .leading, spacing: 14) {
            Button { dismiss() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.forward").font(.system(size: 15, weight: .semibold))
                    Text(backLabel).font(JFont.body(15, .medium))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(b.title).font(JFont.display(26, .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    let by = [b.author.isEmpty ? nil : "بقلم " + b.author, b.translated && !b.translator.isEmpty ? "ترجمة " + b.translator : nil,
                              b.isAudio && !b.narrator.isEmpty ? "بصوت " + b.narrator : nil].compactMap { $0 }.joined(separator: " · ")
                    if !by.isEmpty { Text(by).font(JFont.body(14.5)).foregroundStyle(.white.opacity(0.85)) }
                    Flow(spacing: 6) { chips(b) }
                }
                Spacer(minLength: 0)
                Button { Flows.editBook(b.id) } label: {
                    BookCover(book: b, radius: 6, marks: false).frame(width: 116)
                        .shadow(color: .black.opacity(0.6), radius: 11, y: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("تعديل الكتاب")
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 22)
        .background {
            // the picture fills the hero and no more (an overlay takes the hero's size, so nothing spills below it)
            Color(tint)
                .overlay { if let img = lib.image(b.cover) { Image(uiImage: img).resizable().scaledToFill().blur(radius: 30).opacity(0.75) } }
                .overlay { LinearGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.5)], startPoint: .top, endPoint: .bottom) }
                .clipped()
                .ignoresSafeArea(edges: .top)
        }
    }

    private var backLabel: String {
        switch Router.shared.tab {
        case .notebook: return "دفتري"
        case .progress: return "إنجازاتي"
        default: return "المكتبة"
        }
    }

    @ViewBuilder private func chips(_ b: Book) -> some View {
        heroChip(b.format.label, icon: ["physical": "book", "ebook": "ipad", "audio": "headphones", "web": "globe"][b.format.rawValue])
        if b.series { heroChip(Words.cnt(Double(b.volumes.count), Words.vols)) }
        heroChip((b.structure == "chapters" ? "فصول" : "مجلد") + " · يُحسب ب" + b.unit.plu)
        heroChip(Words.lang(b.lang) + (b.translated ? " · مترجم من " + Words.lang(b.origLang) : ""))
        ForEach(Array(b.genres.prefix(9)), id: \.self) { heroChip($0) }
        ForEach(b.cols, id: \.self) { c in
            HStack(spacing: 4) { Image(systemName: "square.stack").font(.system(size: 10)); Text(c).font(JFont.body(12.5)) }
                .foregroundStyle(Color(L.accentInk)).padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(Color(L.accentSoft)))
        }
    }

    private func heroChip(_ t: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let i = icon { Image(systemName: i).font(.system(size: 10)) }
            Text(t).font(JFont.body(12.5))
        }
        .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.16)))
    }

    // MARK: status and progress

    private func statusSection(_ b: Book) -> some View {
        let st = lib.state
        return VStack(alignment: .leading, spacing: 14) {
            JSeg(options: [("want", "أريد"), ("reading", b.isAudio ? "أستمع له" : "أقرأه"), ("done", "أنهيته"), ("dnf", "توقفت")],
                 value: Binding(get: { b.status.rawValue }, set: { setStatus($0) }))
            if b.status == .done || b.status == .dnf {
                HStack {
                    Text("تقييمك" + (b.readNo > 1 ? " للقراءة \(b.readNo)" : "")).font(JFont.body(15)).foregroundStyle(Color(L.ink))
                    Spacer()
                    JStars(value: Binding(get: { b.rating }, set: { v in lib.changeBook(b.id) { $0.rating = v } }))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(b.posLabel).font(JFont.body(14, .medium)).foregroundStyle(Color(L.ink2))
                    Spacer()
                    if let p = b.pct { Text("\(Int((p * 100).rounded()))%").font(JFont.body(14, .medium)).foregroundStyle(Color(L.ink2)).monospacedDigit() }
                }
                if let p = b.pct { bar(p) }
            }
            if b.series { volumes(b) }
            HStack(spacing: 10) {
                Button { Actions.read(b) } label: {
                    HStack { if b.status == .done { Image(systemName: "repeat") }; Text(st.readLabel(b)) }.frame(maxWidth: .infinity)
                }
                .buttonStyle(JButtonStyle(look: L, primary: true))
                if b.status != .done && !b.isNovel {
                    Button("تحديث التقدم") { sheet = .progress }.buttonStyle(JButtonStyle(look: L))
                }
            }
            if b.status == .reading { goal(b) }
        }
    }

    private func bar(_ p: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(L.surface2))
                Capsule().fill(Color(L.primary)).frame(width: g.size.width * p)
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
        .frame(height: 6)
    }

    private func setStatus(_ v: String) {
        guard let s = BookStatus(rawValue: v), let b = lib.state.book(bookID), b.status != s else { return }
        let prev = b.status
        lib.changeBook(bookID) { x in
            x.status = s
            if s == .done {
                x.vi = max(0, x.volumes.count - 1)
                if let t = x.volumes.last?.total { x.pos = t }
                x.finish = Millis.now
                if x.start == nil { x.start = Millis.now }
            } else {
                x.finish = nil
            }
            if s == .reading && x.start == nil { x.start = Millis.now }
            if s != .done && s != .dnf { x.rating = 0 }
        }
        Achievements.check()
        if s == .done && prev != .done { Flows.finish(bookID, volume: nil) }
    }

    private func volumes(_ b: Book) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(b.volumes.enumerated()), id: \.element.id) { i, v in
                let finished = i < b.vi || b.status == .done
                let current = i == b.vi && b.status != .done
                let review = b.volReviews[v.id]?.object
                Button { Flows.review(b.id, volume: v.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("المجلد \(i + 1)" + (v.title.isEmpty ? "" : " · " + v.title)).font(JFont.body(14.5, current ? .semibold : .regular))
                                .foregroundStyle(Color(current ? L.primary : L.ink))
                            Spacer()
                            Text(volumeSide(b, i, v, finished: finished, current: current, review: review)).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                        }
                        if current, let t = v.total, t > 0 { bar(min(1, b.pos / t)) }
                        if let r = review?.str("review"), !r.isEmpty {
                            Text(r).font(JFont.quote(15)).foregroundStyle(Color(L.ink2)).lineLimit(2)
                        } else if finished {
                            Text("اضغط لتكتب مراجعة المجلد").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(current ? L.primary : L.line), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!finished)
            }
        }
    }

    private func volumeSide(_ b: Book, _ i: Int, _ v: Volume, finished: Bool, current: Bool, review: JSONObject?) -> String {
        if finished { return (review?.num("rating") ?? 0) > 0 ? Words.stars(review?.num("rating") ?? 0) : "أنهيته" }
        if current { return b.uv(b.pos) + " / " + (v.total.map { b.uv($0) } ?? "؟") }
        guard let t = v.total else { return "؟" }
        return b.unit.time ? Words.fmtMin(t) : Words.cnt(t, b.unit.forms)
    }

    private func goal(_ b: Book) -> some View {
        let st = lib.state
        return VStack(alignment: .leading, spacing: 8) {
            if let est = st.estFinishDate(b) {
                pill(icon: "flag", text: "بهذا المعدل تنهيه تقريبًا", value: Words.date(est))
            }
            if let t = Words.fromIso(b.target) {
                let days = ((t - Millis.now) / DAY).rounded(.up)
                HStack {
                    pill(icon: "flag.checkered", text: "هدفك تنهيه قبل " + Words.date(t), value: need(b, days: days))
                    Button { sheet = .target } label: { Image(systemName: "pencil").foregroundStyle(Color(L.ink2)) }
                        .buttonStyle(.plain).accessibilityLabel("تعديل الموعد")
                }
            } else {
                Button { sheet = .target } label: { Label("حدد موعد تبي تنهيه قبله", systemImage: "flag").font(JFont.body(14.5)) }
                    .buttonStyle(.plain).foregroundStyle(Color(L.ink))
            }
        }
    }

    private func need(_ b: Book, days: Double) -> String {
        if days <= 0 { return "انتهى الموعد" }
        let remain = lib.state.remainUnits(b)
        if b.unit.time, let r = remain { return "تحتاج " + Words.fmtMin(r / days / (b.speed > 0 ? b.speed : 1)) + " استماع يوميًا" }
        if let r = remain { return "تحتاج " + Words.cnt((r / days).rounded(.up), b.unit.forms) + " يوميًا" }
        return Words.cnt(days, Words.days) + " باقية"
    }

    private func pill(icon: String, text: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color(L.primary))
            Text(text).font(JFont.body(13.5)).foregroundStyle(Color(L.ink))
            Spacer(minLength: 4)
            Text(value).font(JFont.body(13.5, .semibold)).foregroundStyle(Color(L.ink))
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    // MARK: review

    private func reviewSection(_ b: Book) -> some View {
        JPanel {
            HStack {
                Text("مراجعتك" + (b.readNo > 1 ? " · القراءة \(b.readNo)" : "")).font(JFont.display(18, .semibold)).foregroundStyle(Color(L.ink))
                Spacer()
                Button { Flows.review(b.id, volume: nil) } label: { Label(b.review.isEmpty ? "اكتبها" : "تعديل", systemImage: "pencil").font(JFont.body(14)) }
                    .buttonStyle(.plain).foregroundStyle(Color(L.primary))
            }
            if b.rating > 0 { Text(Words.stars(b.rating)).foregroundStyle(Color(L.star)) }
            if !b.moods.isEmpty || !b.pace.isEmpty {
                Flow(spacing: 6) {
                    ForEach(b.moods, id: \.self) { JMeta(look: L, text: $0) }
                    if let p = Words.paces[b.pace] { JMeta(look: L, text: "الإيقاع: " + p) }
                }
            }
            if b.review.isEmpty {
                Text("ما كتبت مراجعة لهذا الكتاب بعد.").font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            } else {
                Text(b.review).font(JFont.quote(18)).foregroundStyle(Color(L.ink)).lineSpacing(6)
            }
        }
    }

    // MARK: notes

    private func notes(_ b: Book, _ k: NoteKind, _ title: String, _ shown: Int, _ empty: String) -> some View {
        let items = b.items(k).sorted { $0.at > $1.at }
        return VStack(alignment: .leading, spacing: 10) {
            sectionHead(title, count: items.count) { Flows.note(b.id, kind: k.rawValue) }
            if items.isEmpty {
                Text(empty).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            } else if k == .char {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(items.prefix(shown)) { NoteRow(book: b, item: $0, kind: k, compact: true) }
                }
            } else {
                VStack(spacing: 0) { ForEach(items.prefix(shown)) { NoteRow(book: b, item: $0, kind: k, compact: false) } }
            }
            if items.count > shown {
                Button("عرض الكل") { sheet = .list(k.rawValue) }.font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.primary))
            }
            if k == .word && !items.isEmpty {
                Button { Flows.note(b.id, kind: "review") } label: { Label("اختبار كلمات هذا الكتاب", systemImage: "rectangle.on.rectangle") }
                    .buttonStyle(JButtonStyle(look: L, small: true))
            }
        }
    }

    private func sectionHead(_ title: String, count: Int, add: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(JFont.display(20, .semibold)).foregroundStyle(Color(L.ink))
            if count > 0 { Text("\(count)").font(JFont.body(14)).foregroundStyle(Color(L.ink2)).monospacedDigit() }
            Spacer()
            if let a = add { JCircle(look: L, symbol: "plus", size: 34, label: "أضف", action: a) }
        }
    }

    // MARK: sessions

    private func sessionsSection(_ b: Book) -> some View {
        let ss = lib.state.sessions(of: b.id).sorted { $0.start > $1.start }
        return VStack(alignment: .leading, spacing: 10) {
            sectionHead("الجلسات", count: ss.count)
            if ss.isEmpty {
                Text("ما فيه جلسات بعد.").font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            } else {
                VStack(spacing: 0) { ForEach(ss.prefix(3)) { SessionRow(book: b, session: $0) { sheet = .session($0) } } }
                if ss.count > 3 { Button("عرض الكل") { sheet = .list("sess") }.font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.primary)) }
            }
        }
    }

    // MARK: reads

    private func readsSection(_ b: Book) -> some View {
        let times = b.history.count + (b.status == .done ? 1 : 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("سجل القراءات").font(JFont.display(20, .semibold)).foregroundStyle(Color(L.ink))
                Spacer()
                Text("قرأته " + Words.cnt(Double(times), Words.times)).font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
            }
            ForEach(Array(b.history.enumerated()), id: \.offset) { _, h in
                let n = h.int("n")
                Button { if openReads.contains(n) { openReads.remove(n) } else { openReads.insert(n) } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("القراءة \(n)").font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink))
                            Spacer()
                            if h.num("rating") > 0 { Text(Words.stars(h.num("rating"))).foregroundStyle(Color(L.star)) }
                        }
                        Text(readDates(h.optNum("start"), h.optNum("finish"))).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                        if !h.strs("moods").isEmpty { Flow(spacing: 6) { ForEach(h.strs("moods"), id: \.self) { JMeta(look: L, text: $0) } } }
                        if !h.str("review").isEmpty {
                            Text(h.str("review")).font(JFont.quote(16)).foregroundStyle(Color(L.ink)).lineLimit(openReads.contains(n) ? nil : 2)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                }
                .buttonStyle(.plain)
                if openReads.contains(n) {
                    Button { Present.shared.open(.readDel(b.id, n)) } label: { Label("حذف هذه القراءة", systemImage: "trash").font(JFont.body(13.5)) }
                        .buttonStyle(.plain).foregroundStyle(Color(L.danger))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("القراءة \(b.readNo)" + (b.status == .done ? "" : " (الحالية)")).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink))
                Text(readDates(b.start, b.finish)).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                Button { Present.shared.open(.readDel(b.id, b.readNo)) } label: {
                    Label(b.status == .done ? "حذف هذه القراءة" : "إلغاء هذه القراءة والرجوع للقراءة " + Words.ord(max(1, b.readNo - 1)), systemImage: "trash").font(JFont.body(13.5))
                }
                .buttonStyle(.plain).foregroundStyle(Color(L.danger))
            }
        }
    }

    private func readDates(_ s: Double?, _ f: Double?) -> String {
        var t = s.map { "بدأتها " + Words.date($0) } ?? ""
        if let f = f {
            t += (t.isEmpty ? "" : " ← ") + Words.date(f)
            if let s = s { t += " · " + Words.cnt(max(1, ((f - s) / DAY).rounded()), Words.days) }
        }
        return t
    }

    // MARK: details

    private func detailsSection(_ b: Book) -> some View {
        let st = lib.state
        let ss = st.sessions(of: b.id, read: b.readNo)
        let minutes = ss.reduce(0) { $0 + $1.minutes }
        let sp = st.speed(for: b)
        return VStack(alignment: .leading, spacing: 16) {
            Text("التفاصيل").font(JFont.display(20, .semibold)).foregroundStyle(Color(L.ink))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: 0) {
                fact(minutes > 0 ? Words.fmtMin(minutes) : "—", b.verbs.time)
                fact("\(ss.count)", ss.count >= 1 && ss.count <= 10 && ss.count != 1 ? "جلسات" : "جلسة")
                if b.unit.time { fact("×" + (b.speed == b.speed.rounded() ? String(Int(b.speed)) : String(b.speed)), "السرعة") }
                else { fact(sp.map { Words.n0($0) } ?? "—", b.unit.pl + " في الساعة") }
                fact(b.status == .done ? "—" : (st.estRemain(b).map { Words.fmtMin($0) } ?? "—"), b.unit.time ? "المتبقي من المدة" : "المتبقي بسرعتك")
            }
            VStack(spacing: 0) {
                if b.unit.time {
                    kv("مدة الكتاب", Words.fmtMin(b.sumTotal) + (b.speed != 1 && b.speed > 0 ? " (تسمعه في " + Words.fmtMin(b.sumTotal / b.speed) + ")" : ""))
                }
                if let s = b.start { kv("بدأت", Words.date(s, year: true)) }
                if let f = b.finish { kv("أنهيت", Words.date(f, year: true)) }
                if let s = b.start, let f = b.finish { kv("المدة", Words.cnt(max(1, ((f - s) / DAY).rounded()), Words.days)) }
                kv("اللغة", Words.lang(b.lang) + (b.translated ? " (مترجم من " + Words.lang(b.origLang) + ")" : " (لغته الأصلية)"))
                if b.format == .physical {
                    let p = b.purchase
                    if p.bool("gift") { kv("هدية", p.str("giftFrom").isEmpty ? "نعم" : "من " + p.str("giftFrom")) }
                    else {
                        if !p.str("where").isEmpty { kv("اشتريته من", p.str("where")) }
                        if !p.str("price").isEmpty { kv("السعر", p.str("price") + " ر.س") }
                        if !p.str("date").isEmpty { kv("تاريخ الشراء", Words.fromIso(p.str("date")).map { Words.date($0, year: true) } ?? p.str("date")) }
                    }
                } else if !b.platform.isEmpty {
                    kv("المنصة", b.platform)
                }
                if !b.isbn.isEmpty { kv("ISBN", b.isbn) }
                kv("أضفته", Words.date(b.added, year: true))
            }
            if b.format == .physical { loan(b) }
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button { Flows.editBook(b.id) } label: { Label("تعديل الكتاب", systemImage: "pencil").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
                    Button { Flows.bookCard(b.id) } label: { Label("بطاقة الكتاب", systemImage: "rectangle.portrait").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
                }
                HStack(spacing: 10) {
                    Button { Flows.pdf(b.id) } label: { Label("ملخص PDF", systemImage: "doc").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
                    Button { askDelete = true } label: { Label("حذف", systemImage: "trash").frame(maxWidth: .infinity).foregroundStyle(Color(L.danger)) }.buttonStyle(JButtonStyle(look: L))
                }
            }
        }
    }

    private func fact(_ v: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(v).font(JFont.display(19, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(JFont.body(11.5)).foregroundStyle(Color(L.ink2)).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .overlay(alignment: .leading) { Rectangle().fill(Color(L.line)).frame(width: 1) }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            Spacer()
            Text(v).font(JFont.body(14.5)).foregroundStyle(Color(L.ink)).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
    }

    private func loan(_ b: Book) -> some View {
        JPanel {
            Label("الإعارة", systemImage: "hand.raised").font(JFont.display(17, .semibold)).foregroundStyle(Color(L.ink))
            JSwitchRow(title: "أعرته لأحد", on: loanBind(b, "lent"))
            if b.loan.bool("lent") {
                loanField(b, "lentTo", "لمن")
                loanField(b, "lentDate", "متى (yyyy-mm-dd)")
            }
            JSwitchRow(title: "استعرته من أحد", on: loanBind(b, "borrowed"))
            if b.loan.bool("borrowed") {
                loanField(b, "borrowedFrom", "من")
                loanField(b, "borrowedDate", "متى (yyyy-mm-dd)")
            }
        }
    }

    private func loanBind(_ b: Book, _ k: String) -> Binding<Bool> {
        Binding(get: { b.loan.bool(k) }, set: { v in lib.changeBook(b.id) { x in var l = x.loan; l.set(k, v); x.loan = l } })
    }

    private func loanField(_ b: Book, _ k: String, _ label: String) -> some View {
        TextField(label, text: Binding(get: { b.loan.str(k) }, set: { v in lib.changeBook(b.id) { x in var l = x.loan; l.set(k, v); x.loan = l } }))
            .font(JFont.body(15)).padding(.horizontal, 12).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    // MARK: deleting (with undo)

    private func deleteBook() {
        let st = lib.state
        guard let idx = st.index(of: bookID) else { return }
        let snap = st.books[idx]
        let ss = st.sessions.filter { $0.bookId == bookID }
        let shelf = st.shelf
        let hadTimer = st.timer?.str("bookId") == bookID
        lib.change { s in
            s.books.remove(at: idx)
            s.sessions.removeAll { $0.bookId == snap.id }
            if hadTimer { s.timer = nil }
        }
        dismiss()
        ToastCenter.shared.show("تم حذف «" + snap.title + "»") {
            Library.shared.change { s in
                s.books.insert(Book(Library.fixBook(snap.raw)), at: min(idx, s.books.count))
                s.sessions.append(contentsOf: ss)
                s.shelf = shelf
            }
        }
    }
}

/// One quote, thought, word or character, as the book page and the lists show it.
struct NoteRow: View {
    let book: Book
    let item: NoteItem
    let kind: NoteKind
    var compact = false
    @Environment(\.look) private var L

    var body: some View {
        let r = item.raw
        Button { Flows.note(book.id, kind: "edit:" + kind.rawValue + ":" + item.id) } label: {
            Group {
                switch kind {
                case .char:
                    HStack(spacing: 10) {
                        Text(String(r.str("name").prefix(1))).font(JFont.display(18, .bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(Circle().fill(Color(hue: Double(abs(r.str("name").hashValue % 360)) / 360, saturation: 0.35, brightness: 0.45)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.str("name")).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1)
                            Text(r.str("alias").isEmpty ? r.str("desc") : r.str("alias")).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                case .word:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.str("word")).font(JFont.display(19, .semibold)).foregroundStyle(Color(L.ink))
                        if !r.str("tr").isEmpty { Text(r.str("tr")).font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.primary)) }
                        if !r.str("meaning").isEmpty { Text(r.str("meaning")).font(JFont.body(14)).foregroundStyle(Color(L.ink)) }
                        meta
                    }
                    .padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
                default:
                    VStack(alignment: .leading, spacing: 6) {
                        if let img = item.img, let i = Library.shared.image(img) {
                            Image(uiImage: i).resizable().scaledToFit().frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        if !r.str("text").isEmpty { Text(r.str("text")).font(JFont.quote(19)).foregroundStyle(Color(L.ink)).lineSpacing(5) }
                        if !r.str("passage").isEmpty {
                            Text(r.str("passage")).font(JFont.quote(16)).foregroundStyle(Color(L.ink2))
                                .padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(Color(L.line)).frame(width: 3) }
                        }
                        meta
                    }
                    .padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var meta: some View {
        let r = item.raw
        var parts: [String] = []
        if let loc = r.optNum("loc"), loc > 0 {
            if book.unit.time { parts.append(Words.hm(loc)) } else { parts.append(book.unit.abbr + " " + Words.n0(loc)) }
        }
        if let nv = item.nv, !nv.str("label").isEmpty { parts.append(nv.str("label")) }
        if item.at > 0 { parts.append(Words.date(item.at)) }
        return Text(parts.joined(separator: " · ")).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
    }
}

/// A session in a list: its date, its length and how much was read.
struct SessionRow: View {
    let book: Book
    let session: Session
    let edit: (String) -> Void
    @Environment(\.look) private var L

    var body: some View {
        Button { edit(session.id) } label: {
            HStack {
                Text(Words.date(session.start) + (book.history.isEmpty ? "" : " · القراءة \(session.read)")).font(JFont.body(14.5)).foregroundStyle(Color(L.ink))
                Spacer()
                Text(Words.fmtMin(session.minutes) + " · " + unitCount).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }

    private var unitCount: String {
        let u = Unit(rawValue: session.unit) ?? .page
        return u.time ? Words.fmtMin(session.units) : Words.cnt(session.units, u.forms)
    }
}

/// «موعد الانتهاء»
struct TargetSheet: View {
    let bookID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var date = Date().addingTimeInterval(14 * 86_400)
    @State private var err = ""

    var body: some View {
        if let b = lib.state.book(bookID) {
            JSheet(title: "موعد الانتهاء", subtitle: b.title) {
                DatePicker("أبي أنهيه قبل", selection: $date, in: Date()..., displayedComponents: .date).font(JFont.body(15.5)).tint(Color(L.primary))
                    .environment(\.locale, Locale(identifier: "ar@numbers=latn"))
                Text("يحسب لك كم " + b.unit.pl + " تحتاج يوميًا عشان توصل.").font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
                Button { save() } label: { Text("حفظ").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
                if !b.target.isEmpty {
                    Button { lib.changeBook(bookID) { $0.target = "" }; dismiss() } label: { Text("إلغاء الموعد").frame(maxWidth: .infinity).foregroundStyle(Color(L.danger)) }
                        .buttonStyle(JButtonStyle(look: L))
                }
            }
            .onAppear { if let t = Words.fromIso(b.target) { date = Millis.date(t) } }
        }
    }

    private func save() {
        let iso = Words.dkey(Millis.ms(date))
        lib.changeBook(bookID) { $0.target = iso }
        dismiss()
    }
}

/// «جلسة …»: its length, or delete it (with undo).
struct SessionEditSheet: View {
    let sessionID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var minutes: Double = 0
    @State private var err = ""

    var body: some View {
        if let i = lib.state.sessions.firstIndex(where: { $0.id == sessionID }) {
            let s = lib.state.sessions[i]
            let b = lib.state.book(s.bookId)
            JSheet(title: "جلسة " + Words.date(s.start), subtitle: b?.title) {
                JLabel(text: "المدة بالدقائق")
                TextField("المدة", value: $minutes, format: .number.grouping(.never).locale(Locale(identifier: "en_US_POSIX"))).keyboardType(.numberPad).font(JFont.body(18))
                    .multilineTextAlignment(.center).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                if !err.isEmpty { Text(err).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
                Button { save(i) } label: { Text("حفظ").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
                Button { delete(i) } label: { Label("حذف الجلسة", systemImage: "trash").frame(maxWidth: .infinity).foregroundStyle(Color(L.danger)) }
                    .buttonStyle(JButtonStyle(look: L))
            }
            .onAppear { minutes = s.minutes.rounded() }
        }
    }

    private func save(_ i: Int) {
        guard minutes > 0, minutes <= 1440 else { err = "اكتب مدة بين دقيقة و24 ساعة."; return }
        lib.change { $0.sessions[i].minutes = minutes.rounded() }
        dismiss()
        ToastCenter.shared.show("تم تعديل الجلسة")
    }

    private func delete(_ i: Int) {
        let s = lib.state.sessions[i]
        lib.change { $0.sessions.remove(at: i) }
        dismiss()
        ToastCenter.shared.show("تم حذف الجلسة") {
            Library.shared.change { $0.sessions.insert(s, at: min(i, $0.sessions.count)) }
        }
    }
}

/// «عرض الكل»: every quote, thought, character or word of a book, or every session.
struct ItemListSheet: View {
    let bookID: String
    let kind: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var editSession: String?

    var body: some View {
        if let b = lib.state.book(bookID) {
            let titles = ["quote": "الاقتباسات", "thought": "الأفكار", "char": "الشخصيات", "word": "الكلمات", "sess": "الجلسات"]
            JSheet(title: (titles[kind] ?? "") + " · " + b.title) {
                if kind == "sess" {
                    VStack(spacing: 0) {
                        ForEach(lib.state.sessions(of: b.id).sorted { $0.start > $1.start }) { s in SessionRow(book: b, session: s) { editSession = $0 } }
                    }
                } else if let k = NoteKind(rawValue: kind) {
                    Button { Flows.note(b.id, kind: kind) } label: { Label("أضف", systemImage: "plus") }.buttonStyle(JButtonStyle(look: L, small: true))
                    VStack(spacing: 0) { ForEach(b.items(k).sorted { $0.at > $1.at }) { NoteRow(book: b, item: $0, kind: k, compact: false) } }
                }
            }
            .sheet(item: Binding(get: { editSession.map { IDBox(id: $0) } }, set: { editSession = $0?.id })) { x in
                SessionEditSheet(sessionID: x.id).presentationDetents([.medium]).environment(\.look, L).environment(\.layoutDirection, .rightToLeft)
            }
        }
    }
}

struct IDBox: Identifiable { let id: String }
