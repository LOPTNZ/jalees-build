import SwiftUI
import UIKit

// Finishing a book or a volume (its review), reading it again, and removing a read (inventory-2, 3.2–3.4, 6.11).

/// «مبروك، أنهيته» / «أنهيت المجلد» / «مراجعتك»
struct FinishSheet: View {
    let bookID: String
    let volume: String?
    let congrats: Bool
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var rating: Double = 0
    @State private var review = ""
    @State private var moods: [String] = []
    @State private var pace = ""
    @State private var finish = Date()
    @State private var err = ""
    @State private var loaded = false
    @State private var spoiler = false

    var body: some View {
        if let b = lib.state.book(bookID) {
            let vi = volume.flatMap { v in b.volumes.firstIndex { $0.id == v } }
            JSheet(title: congrats ? (vi != nil ? "أنهيت المجلد" : "مبروك، أنهيته") : "مراجعتك") {
                HStack(spacing: 14) {
                    BookCover(book: b, radius: 6, marks: false).frame(width: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vi.map { "المجلد \($0 + 1)" + (b.volumes[$0].title.isEmpty ? "" : " · " + b.volumes[$0].title) } ?? b.title).font(JFont.body(16, .semibold))
                        if vi != nil { Text(b.title).font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
                        else if b.readNo > 1 { Text("القراءة \(Words.ord(b.readNo))").font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
                    }
                }
                HStack { JLabel(text: "تقييمك"); Spacer(); JStars(value: $rating) }
                if vi == nil {
                    JLabel(text: "كيف كان الكتاب؟")
                    Flow(spacing: 8) {
                        ForEach(Vocab.moods, id: \.self) { m in
                            JChip(look: L, text: m, on: moods.contains(m)) { if let i = moods.firstIndex(of: m) { moods.remove(at: i) } else { moods.append(m) } }
                        }
                    }
                    JLabel(text: "الإيقاع")
                    JSeg(options: [("slow", "بطيء"), ("mid", "متوسط"), ("fast", "سريع"), ("", "غير محدد")], value: $pace)
                }
                JLabel(text: vi != nil ? "مراجعتك للمجلد" : "مراجعتك")
                TextEditor(text: $review).font(JFont.quote(18)).frame(minHeight: 140).scrollContentBackground(.hidden).padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                    .overlay(alignment: .topLeading) {
                        if review.isEmpty { Text("وش عجبك؟ وش ما عجبك؟ لمن تنصح فيه؟").font(JFont.quote(17)).foregroundStyle(Color(L.ink2).opacity(0.7)).padding(14).allowsHitTesting(false) }
                    }
                if !review.isEmpty { JSwitchRow(title: "المراجعة فيها حرق", sub: "تتغطى لين تضغط عليها", on: $spoiler) }
                if vi == nil {
                    DatePicker("تاريخ الانتهاء", selection: $finish, displayedComponents: .date).font(JFont.body(15)).environment(\.locale, Lang.locale)
                }
                if !err.isEmpty { Text(err).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
                Button { save(b, vi) } label: { Text("حفظ").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
                if congrats { Button { dismiss() } label: { Text("لاحقًا").frame(maxWidth: .infinity) }.buttonStyle(.plain).foregroundStyle(Color(L.ink2)) }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let v = volume {
                    let rv = b.volReviews[v]?.object ?? [:]
                    rating = rv.num("rating"); review = rv.str("review")
                } else {
                    rating = b.rating; review = b.review; moods = b.moods; pace = b.pace; spoiler = b.raw.bool("reviewSpoiler")
                    finish = Millis.date(b.finish ?? Millis.now)
                }
            }
        }
    }

    private func save(_ b: Book, _ vi: Int?) {
        if let v = volume {
            lib.changeBook(b.id) { x in
                var r = x.volReviews
                r[v] = .object(["rating": .number(rating), "review": .string(review.trimmingCharacters(in: .whitespacesAndNewlines)), "at": .number(Millis.now)])
                x.volReviews = r
            }
        } else {
            let fi = Millis.ms(finish)
            if let s = b.start, fi < s - DAY { err = "تاريخ الانتهاء قبل تاريخ البدء."; return }
            lib.changeBook(b.id) { x in
                x.rating = rating
                x.review = review.trimmingCharacters(in: .whitespacesAndNewlines)
                x.raw.set("reviewSpoiler", spoiler && !x.review.isEmpty)
                x.moods = moods
                x.pace = pace
                if x.status == .done { x.finish = fi }
            }
        }
        dismiss()
        Achievements.check()
        ToastCenter.shared.show("تم حفظ المراجعة")
    }
}

/// «ابدأ قراءة جديدة»: this read goes to the log; progress starts from zero.
struct RereadSheet: View {
    let bookID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L

    var body: some View {
        if let b = lib.state.book(bookID) {
            JSheet(title: b.verbs.again) {
                Text("تبدأ القراءة \(Words.ord(b.readNo + 1)) لـ«\(b.title)»؟").font(JFont.body(16)).foregroundStyle(Color(L.ink))
                Text("تقدمك يرجع للصفر، وقراءتك \(Words.ord(b.readNo)) بتواريخها وتقييمها ومراجعتها تنحفظ في سجل القراءات. الاقتباسات والشخصيات والكلمات تبقى للكتاب.")
                    .font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
                Button { go(true) } label: { Label("ابدأ " + b.verbs.sess + " الآن", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L, primary: true))
                Button { go(false) } label: { Text("ابدأ بدون جلسة").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
            }
            .presentationDetents([.medium])
        }
    }

    private func go(_ withSession: Bool) {
        Reads.again(bookID)
        dismiss()
        Achievements.check()
        if withSession {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SessionModel.shared.start(bookID) }
        } else if let b = lib.state.book(bookID) {
            ToastCenter.shared.show("بدأت القراءة \(Words.ord(b.readNo))")
        }
    }
}

/// «إلغاء القراءة» / «حذف القراءة»
struct ReadDelSheet: View {
    let bookID: String
    let n: Int
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L

    var body: some View {
        if let b = lib.state.book(bookID) {
            let cur = n == b.readNo
            let k = lib.state.sessions.filter { $0.bookId == b.id && $0.read == n }.count
            let prev = cur ? b.history.last : nil
            JSheet(title: cur && b.status != .done ? "إلغاء القراءة \(Words.ord(n))".tr : "حذف القراءة \(Words.ord(n))".tr) {
                Text(cur ? "ترجع قراءتك \(Words.ord(prev?.int("n") ?? 1)) لـ«\(b.title)» كما انتهت، بتاريخها وتقييمها ومراجعتها، وكأنك ما بدأت هذه القراءة."
                         : "تنشال القراءة \(Words.ord(n)) من سجل «\(b.title)»، والقراءات بعدها يتعدل ترقيمها.")
                    .font(JFont.body(15.5))
                Text((k > 0 ? "تنحذف جلساتها (" + Words.cnt(Double(k), Words.sessions) + ") من الإحصائيات. " : "") + "الاقتباسات والأفكار والكلمات تبقى للكتاب. وتقدر تتراجع بعدها مباشرة.")
                    .font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                Button { remove() } label: { Label(cur && b.status != .done ? "ألغِ القراءة" : "احذف القراءة", systemImage: "trash").foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.danger))) }
                    .buttonStyle(.plain)
                Button { dismiss() } label: { Text("رجوع").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
            }
            .presentationDetents([.medium])
        }
    }

    private func remove() {
        if SessionModel.shared.timer?.str("bookId") == bookID { ToastCenter.shared.show("أنهِ الجلسة الجارية أولًا"); return }
        guard let snap = Reads.snapshot(bookID), let msg = Reads.remove(bookID, n) else { dismiss(); return }
        dismiss()
        ToastCenter.shared.show(msg) { Reads.restore(snap) }
    }
}

@MainActor
enum Reads {
    /// Start a new read: the finished one goes to the log (rereadDo).
    static func again(_ id: String) {
        let st = Library.shared.state
        guard let b = st.book(id) else { return }
        let ss = st.sessions(of: id, read: b.readNo)
        Library.shared.changeBook(id) { x in
            var h = x.history
            h.append(["n": .number(Double(x.readNo)), "start": x.start.map { .number($0) } ?? .null, "finish": x.finish.map { .number($0) } ?? .null,
                      "rating": .number(x.rating), "review": .string(x.review), "moods": .array(x.moods.map { .string($0) }), "pace": .string(x.pace),
                      "volReviews": .object(x.volReviews), "minutes": .number(ss.reduce(0) { $0 + $1.minutes }), "sessions": .number(Double(ss.count)),
                      "status": .string(x.status.rawValue), "pos": .number(x.pos), "vi": .number(Double(x.vi))])
            x.history = h
            x.readNo += 1
            x.status = .reading
            x.start = Millis.now
            x.finish = nil
            x.rating = 0; x.review = ""; x.moods = []; x.pace = ""; x.volReviews = [:]
            x.vi = 0; x.pos = 0
        }
    }

    typealias Snap = (book: Book, sessions: [Session])

    static func snapshot(_ id: String) -> Snap? {
        let st = Library.shared.state
        guard let b = st.book(id) else { return nil }
        return (b, st.sessions.filter { $0.bookId == id })
    }

    static func restore(_ s: Snap) {
        Library.shared.change { st in
            guard let i = st.index(of: s.book.id) else { return }
            st.books[i] = s.book
            st.sessions = (st.sessions.filter { $0.bookId != s.book.id } + s.sessions).sorted { $0.start < $1.start }
        }
    }

    /// Cancel the current read (back to how the one before ended) or delete a past one (readDelDo). Returns the message.
    static func remove(_ id: String, _ n: Int) -> String? {
        guard let b = Library.shared.state.book(id) else { return nil }
        var msg: String?
        Library.shared.change { st in
            guard let i = st.index(of: id) else { return }
            var x = st.books[i]
            func move(_ map: [Int: Int]) {
                for j in st.sessions.indices where st.sessions[j].bookId == id { if let to = map[st.sessions[j].read] { st.sessions[j].read = to } }
                for k in ["quotes", "thoughts", "words"] {
                    x.raw.set(k, objects: x.raw.objs(k).map { o in var o = o; if let to = map[o.int("read", 1)] { o.set("read", to) }; return o })
                }
            }
            if n == b.readNo {
                var hist = x.history
                guard let h = hist.popLast() else { return }
                x.history = hist
                st.sessions.removeAll { $0.bookId == id && $0.read == n }
                x.readNo = h.int("n", 1)
                let hs = h.str("status")
                x.status = BookStatus(rawValue: !hs.isEmpty && hs != "reading" ? hs : "done") ?? .done
                x.start = h.optNum("start"); x.finish = h.optNum("finish"); x.rating = h.num("rating"); x.review = h.str("review")
                x.moods = h.strs("moods"); x.pace = h.str("pace"); x.volReviews = h.obj("volReviews")
                if let p = h.optNum("pos") { x.pos = p; x.vi = h.int("vi") }
                move([n: h.int("n", 1)])
                msg = "ألغيت القراءة \(Words.ord(n))"
            } else {
                var hist = x.history
                guard let idx = hist.firstIndex(where: { $0.int("n") == n }) else { return }
                hist.remove(at: idx)
                st.sessions.removeAll { $0.bookId == id && $0.read == n }
                var map: [Int: Int] = [:]
                for (k, h) in hist.enumerated() { map[h.int("n")] = k + 1 }
                map[x.readNo] = hist.count + 1
                map[n] = min(idx + 1, hist.count + 1)
                x.history = hist.enumerated().map { k, h in var h = h; h.set("n", k + 1); return h }
                move(map)
                x.readNo = hist.count + 1
                msg = "حذفت القراءة \(Words.ord(n))"
            }
            st.books[i] = x
        }
        return msg
    }
}
