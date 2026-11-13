import SwiftUI
import UIKit

// A character's card (inventory-2, 2.3) and reviewing words (2.4, 6.10).

struct CharacterCard: View {
    let bookID: String
    @State var charID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var edit: ItemRef?
    @State private var reveal = false

    init(bookID: String, charID: String) {
        self.bookID = bookID
        _charID = State(initialValue: charID)
    }

    var body: some View {
        if let b = lib.state.book(bookID), let c = b.chars.first(where: { $0.id == charID }) {
            let r = c.raw
            JSheet(title: c.name, action: ("تعديل", { edit = ItemRef(book: bookID, kind: "char", item: charID) })) {
                HStack(alignment: .top, spacing: 16) {
                    Avatar(name: c.name, photo: c.photo, size: 88)
                    VStack(alignment: .leading, spacing: 8) {
                        Flow(spacing: 6) {
                            if let role = ["main": "رئيسية", "secondary": "ثانوية"][c.role] { JMeta(look: L, text: role) }
                            if let g = ["m": "ذكر", "f": "أنثى"][r.str("gender")] { JMeta(look: L, text: g) }
                            if let f = c.first { JMeta(look: L, text: "أول ظهور: " + (b.unit.time ? Words.hm(f) : b.unit.abbr + " " + Words.n0(f))) }
                        }
                        Text(b.title).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                    }
                }
                VStack(spacing: 0) {
                    ForEach([("اللقب", "alias"), ("العمر", "age"), ("الأهمية", "importance")], id: \.1) { k in
                        if !r.str(k.1).isEmpty { kv(k.0, r.str(k.1)) }
                    }
                    ForEach(Array(c.custom.enumerated()), id: \.offset) { _, f in kv(f.str("k"), f.str("v")) }
                }
                ForEach([("الوصف", "desc"), ("الشكل", "appearance"), ("الصفات", "traits"), ("العيوب", "flaws")], id: \.1) { k in
                    if !r.str(k.1).isEmpty { section(k.0, r.str(k.1)) }
                }
                if !r.str("death").isEmpty {
                    let hide = lib.state.settings.raw.bool("spoilers", true) && !reveal
                    VStack(alignment: .leading, spacing: 4) {
                        Text("الموت").font(JFont.display(17, .semibold))
                        Text(r.str("death")).font(JFont.body(15)).foregroundStyle(Color(L.ink))
                            .blur(radius: hide ? 7 : 0)
                            .onTapGesture { withAnimation { reveal = true } }
                            .accessibilityLabel(hide ? "مخفي، اضغط لإظهاره" : r.str("death"))
                    }
                }
                if !c.rel.isEmpty {
                    Text("العلاقات").font(JFont.display(17, .semibold))
                    Flow(spacing: 8) {
                        ForEach(Array(c.rel.enumerated()), id: \.offset) { _, rel in
                            if let o = b.chars.first(where: { $0.id == rel.str("to") }) {
                                JChip(look: L, text: (rel.str("label").isEmpty ? "" : rel.str("label") + ": ") + o.name) { charID = o.id; reveal = false }
                            }
                        }
                    }
                }
                let quotes = b.quotes.filter { $0.raw.str("speakerId") == c.id }
                if !quotes.isEmpty {
                    Text("اقتباساتها").font(JFont.display(17, .semibold))
                    VStack(spacing: 0) { ForEach(quotes) { QuoteRow(book: b, item: $0, kind: .quote, showBook: false) } }
                }
            }
            .sheet(item: $edit) { r in ItemForm(ref: r).environment(\.look, L).environment(\.layoutDirection, .rightToLeft) }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            Spacer()
            Text(v).font(JFont.body(14.5)).foregroundStyle(Color(L.ink))
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
    }

    private func section(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(JFont.display(17, .semibold))
            Text(v).font(JFont.body(15)).foregroundStyle(Color(L.ink))
        }
    }
}

/// «مراجعة بالتكرار المتباعد» / «اختبار الكلمات»
struct WordReview: View {
    let bookID: String?
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var queue: [(book: String, id: String)] = []
    @State private var i = 0
    @State private var flipped = false
    @State private var done = 0
    @State private var known = 0
    @State private var started = false

    private var srs: Bool { lib.state.settings.raw.str("review", "srs") == "srs" }

    static func pool(_ book: String?) -> [(book: Book, item: NoteItem)] {
        Library.shared.state.books.filter { book == nil || $0.id == book }.flatMap { b in b.words.map { (b, $0) } }
    }

    static func isDue(_ w: NoteItem) -> Bool {
        guard let s = w.raw["srs"]?.object else { return true }
        return s.num("due") <= Millis.now
    }

    var body: some View {
        JSheet(title: srs ? "مراجعة بالتكرار المتباعد" : "اختبار الكلمات") {
            let pool = Self.pool(bookID)
            if pool.isEmpty {
                Text("ما فيه كلمات للمراجعة.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
            } else if queue.isEmpty && started {
                VStack(spacing: 10) {
                    Text("ما فيه كلمات مستحقة اليوم").font(JFont.display(19, .semibold))
                    Text("كل كلمة ترجع لك لما يحين موعدها.").font(JFont.body(14)).foregroundStyle(Color(L.ink2))
                    Button("راجع الكل الآن") { load(all: true) }.buttonStyle(JButtonStyle(look: L, primary: true))
                }
                .frame(maxWidth: .infinity)
            } else if i >= queue.count && started {
                VStack(spacing: 10) {
                    Text("انتهت المراجعة").font(JFont.display(19, .semibold))
                    Text("راجعت " + Words.cnt(Double(done), ["كلمة واحدة", "كلمتين", "كلمات", "كلمة"]) + (srs ? "" : " · عرفت \(known)")).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
                    HStack {
                        Button("مرة ثانية") { load(all: true) }.buttonStyle(JButtonStyle(look: L))
                        Button("تم") { dismiss() }.buttonStyle(JButtonStyle(look: L, primary: true))
                    }
                }
                .frame(maxWidth: .infinity)
            } else if queue.indices.contains(i), let b = lib.state.book(queue[i].book), let w = b.words.first(where: { $0.id == queue[i].id }) {
                Text("\(i + 1) من \(queue.count)").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                card(b, w)
                if !flipped {
                    Button { withAnimation(.easeInOut(duration: 0.45)) { flipped = true } } label: { Text("أظهر المعنى").frame(maxWidth: .infinity) }
                        .buttonStyle(JButtonStyle(look: L, primary: true))
                } else if srs {
                    HStack(spacing: 8) {
                        grade("مرة أخرى", "again", b, w); grade("صعبة", "hard", b, w); grade("جيدة", "good", b, w); grade("سهلة", "easy", b, w)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button { next(knew: false) } label: { Text("ما عرفتها").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
                        Button { next(knew: true) } label: { Text("عرفتها").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
                    }
                }
            }
        }
        .onAppear { if !started { load(all: false) } }
    }

    private func load(all: Bool) {
        let pool = Self.pool(bookID)
        var list: [(book: String, id: String)]
        if srs && !all {
            list = pool.filter { Self.isDue($0.item) }.sorted { ($0.item.raw["srs"]?.object?.num("due") ?? 0) < ($1.item.raw["srs"]?.object?.num("due") ?? 0) }.map { ($0.book.id, $0.item.id) }
        } else {
            list = pool.map { ($0.book.id, $0.item.id) }.shuffled()
        }
        queue = list; i = 0; done = 0; known = 0; flipped = false; started = true
    }

    private func card(_ b: Book, _ w: NoteItem) -> some View {
        let r = w.raw
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(L.surface2))
            if flipped {
                VStack(spacing: 8) {
                    if !r.str("tr").isEmpty { Text(r.str("tr")).font(JFont.display(26, .semibold)).foregroundStyle(Color(L.primary)) }
                    if !r.str("meaning").isEmpty { Text(r.str("meaning")).font(JFont.body(16)) }
                    if !r.str("ex").isEmpty { Text("«" + r.str("ex") + "»").font(JFont.quote(16)).foregroundStyle(Color(L.ink2)) }
                    Text(NoteItems.locLabel(b, w)).font(JFont.body(12)).foregroundStyle(Color(L.ink2))
                }
                .multilineTextAlignment(.center).padding(20)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            } else {
                VStack(spacing: 8) {
                    Text(r.str("word")).font(JFont.display(30, .bold))
                    Text([Words.lang(r.str("lang")), b.title].filter { !$0.isEmpty }.joined(separator: " · ")).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                    Text("اضغط لتقلب").font(JFont.body(12)).foregroundStyle(Color(L.ink2))
                }
                .padding(20)
            }
        }
        .frame(maxWidth: 360, minHeight: 230)
        .frame(maxWidth: .infinity)
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .onTapGesture { withAnimation(.easeInOut(duration: 0.45)) { flipped.toggle() } }
    }

    private func grade(_ label: String, _ g: String, _ b: Book, _ w: NoteItem) -> some View {
        let n = Self.schedule(w.raw["srs"]?.object, g)
        return Button {
            lib.changeBook(b.id) { x in
                var list = x.raw.objs("words")
                if let j = list.firstIndex(where: { $0.str("id") == w.id }) { list[j]["srs"] = .object(n) }
                x.raw.set("words", objects: list)
            }
            if g == "again" { queue.append(queue[i]) }
            next(knew: g != "again")
        } label: {
            VStack(spacing: 2) {
                Text(label).font(JFont.body(14, .semibold))
                Text(g == "again" ? "10 د" : Words.cnt(n.num("ivl"), Words.days)).font(JFont.body(11)).foregroundStyle(Color(L.ink2))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(L.line), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func next(knew: Bool) {
        done += 1
        if knew { known += 1 }
        flipped = false
        i += 1
        Haptics.play("sel")
    }

    /// The next review of a word (srsNext): again in 10 minutes; hard, good, easy further each time.
    static func schedule(_ s: JSONObject?, _ g: String) -> JSONObject {
        var ease = s?.num("ease", 2.5) ?? 2.5, ivl = s?.num("ivl") ?? 0, reps = s?.num("reps") ?? 0
        if ease == 0 { ease = 2.5 }
        switch g {
        case "again":
            return ["ease": .number(max(1.3, ease - 0.2)), "ivl": .number(0), "reps": .number(0), "due": .number(Millis.now + 600_000)]
        case "hard":
            ivl = max(1, ((ivl > 0 ? ivl : 1) * 1.2).rounded()); ease = max(1.3, ease - 0.15)
        case "good":
            ivl = reps == 0 ? 1 : (reps == 1 ? 3 : (ivl * ease).rounded()); reps += 1
        default:
            ivl = reps == 0 ? 3 : (max(1, ivl) * ease * 1.3).rounded(); ease += 0.15; reps += 1
        }
        return ["ease": .number(ease), "ivl": .number(ivl), "reps": .number(reps), "due": .number(Millis.now + ivl * DAY)]
    }
}
