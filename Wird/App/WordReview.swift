import SwiftUI
import AVFoundation

/// «مراجعة بالتكرار المتباعد» / «اختبار الكلمات»: flash cards, multiple choice, or typing the word.
struct WordReview: View {
    enum Mode { case cards, choice, typed }

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
    @State private var mode: Mode = .cards
    @State private var reverse = false
    @State private var sel: String?
    @State private var missed: [(book: String, id: String)] = []
    @State private var options: [String] = []
    @State private var picked: String?
    @State private var typed = ""
    @State private var result: Bool?
    @State private var flash: Color = .clear
    @FocusState private var typing: Bool

    /// One synthesizer for the whole screen, so a new word cuts off the old one.
    private static let synth = AVSpeechSynthesizer()

    init(bookID: String?) {
        self.bookID = bookID
        _sel = State(initialValue: bookID)
    }

    private var srs: Bool { lib.state.settings.raw.str("review", "srs") == "srs" }
    /// Multiple choice needs three wrong meanings from other words.
    private var canChoice: Bool { Self.pool(nil).count >= 4 }

    static func pool(_ book: String?) -> [(book: Book, item: NoteItem)] {
        Library.shared.state.books.filter { book == nil || $0.id == book }.flatMap { b in b.words.map { (b, $0) } }
    }

    static func isDue(_ w: NoteItem) -> Bool {
        guard let s = w.raw["srs"]?.object else { return true }
        return s.num("due") <= Millis.now
    }

    /// The meaning to test: the translation if there is one, else the written meaning.
    static func answerText(_ r: JSONObject) -> String {
        r.str("tr").isEmpty ? r.str("meaning") : r.str("tr")
    }

    /// For loose comparison: no diacritics, alef/yaa/taa-marbuta forms unified, lower case, trimmed.
    static func norm(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { u in
            let v = u.value
            return !((0x064B...0x065F).contains(v) || v == 0x0670 || v == 0x0640)
        }
        var t = String(String.UnicodeScalarView(kept))
        for (a, b) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ى", "ي"), ("ة", "ه")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - body

    var body: some View {
        JSheet(title: srs ? "مراجعة بالتكرار المتباعد" : "اختبار الكلمات") {
            let pool = Self.pool(bookID)
            if pool.isEmpty {
                Text("ما فيه كلمات للمراجعة.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
            } else if !started {
                startView
            } else if queue.isEmpty {
                VStack(spacing: 10) {
                    Text("ما فيه كلمات تناسب هذه الطريقة").font(JFont.display(19, .semibold))
                    Text("الكلمات هنا بلا معنى مسجّل.").font(JFont.body(14)).foregroundStyle(Color(L.ink2))
                    Button("رجوع") { started = false }.buttonStyle(JButtonStyle(look: L, primary: true))
                }
                .frame(maxWidth: .infinity)
            } else if i >= queue.count {
                endView
            } else if queue.indices.contains(i), let b = lib.state.book(queue[i].book), let w = b.words.first(where: { $0.id == queue[i].id }) {
                reviewView(b, w)
            }
        }
    }

    // MARK: - start screen

    @ViewBuilder private var startView: some View {
        let pool = Self.pool(sel)
        let due = pool.filter { Self.isDue($0.item) }.count
        if bookID == nil { bookMenu }
        HStack(spacing: 10) {
            stat(due, "مستحقة", Color(L.primary))
            stat(pool.count, "كل الكلمات", Color(L.ink))
        }
        Text("طريقة المراجعة").font(JFont.display(17, .semibold))
        VStack(spacing: 8) {
            modeRow(.cards, "rectangle.on.rectangle", "بطاقات", "اقلب البطاقة وقيّم نفسك")
            if canChoice { modeRow(.choice, "list.bullet", "اختيار من متعدد", "اختر المعنى الصحيح من أربعة") }
            modeRow(.typed, "keyboard", "اكتبها", "شاهد المعنى واكتب الكلمة")
        }
        if mode == .cards {
            HStack(spacing: 8) {
                dirButton("الكلمة ← المعنى", !reverse) { reverse = false }
                dirButton("المعنى ← الكلمة", reverse) { reverse = true }
            }
        }
        if srs && due > 0 {
            Button { load(all: false) } label: { HStack(spacing: 6) { Text("ابدأ المستحقة"); Text(verbatim: "(\(due))") }.frame(maxWidth: .infinity) }
                .buttonStyle(JButtonStyle(look: L, primary: true))
            Button { load(all: true) } label: { HStack(spacing: 6) { Text("راجع الكل"); Text(verbatim: "(\(pool.count))") }.frame(maxWidth: .infinity) }
                .buttonStyle(JButtonStyle(look: L))
        } else {
            Button { load(all: true) } label: { HStack(spacing: 6) { Text(srs ? "راجع الكل" : "ابدأ"); Text(verbatim: "(\(pool.count))") }.frame(maxWidth: .infinity) }
                .buttonStyle(JButtonStyle(look: L, primary: true))
        }
    }

    private var bookMenu: some View {
        let books = lib.state.books.filter { !$0.words.isEmpty }
        return Menu {
            Button("كل الكتب") { sel = nil }
            ForEach(books, id: \.id) { b in Button(b.title) { sel = b.id } }
        } label: {
            HStack {
                Text(sel.flatMap { lib.state.book($0)?.title } ?? "كل الكتب").font(JFont.body(15)).foregroundStyle(Color(L.ink))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(Color(L.ink2))
            }
            .padding(.horizontal, 14).frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface2)))
        }
    }

    private func stat(_ n: Int, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(n)").font(JFont.display(26, .bold)).foregroundStyle(tint)
            Text(label).font(JFont.body(12)).foregroundStyle(Color(L.ink2))
        }
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface2)))
    }

    private func modeRow(_ m: Mode, _ icon: String, _ title: String, _ sub: String) -> some View {
        let on = mode == m
        return Button { mode = m } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Color(on ? L.primary : L.ink2)).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink))
                    Text(sub).font(JFont.body(12)).foregroundStyle(Color(L.ink2))
                }
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(L.primary)) }
            }
            .padding(.horizontal, 14).frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(on ? L.primary : L.line), lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func dirButton(_ t: String, _ on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(t).frame(maxWidth: .infinity) }
            .buttonStyle(JButtonStyle(look: L, primary: on, small: true))
    }

    // MARK: - one question

    private func reviewView(_ b: Book, _ w: NoteItem) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("\(i + 1) من \(queue.count)").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(L.line))
                        Capsule().fill(Color(L.primary)).frame(width: g.size.width * CGFloat(i) / CGFloat(max(1, queue.count)))
                    }
                }
                .frame(height: 4)
            }
            switch mode {
            case .cards: cardBody(b, w)
            case .choice: choiceBody(b, w)
            case .typed: typedBody(b, w)
            }
            if mode == .cards ? flipped : result != nil { detail(b, w) }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(flash).opacity(0.25).allowsHitTesting(false))
    }

    /// Example sentence and where the word came from, once the answer is known.
    private func detail(_ b: Book, _ w: NoteItem) -> some View {
        let ex = w.raw.str("ex")
        let loc = NoteItems.locLabel(b, w)
        return VStack(spacing: 4) {
            if !ex.isEmpty { Text("«" + ex + "»").font(JFont.quote(16)).foregroundStyle(Color(L.ink2)) }
            Text(b.title + (loc.isEmpty ? "" : " · " + loc)).font(JFont.body(12)).foregroundStyle(Color(L.ink2))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func speakButton(_ w: NoteItem) -> some View {
        JCircle(look: L, symbol: "speaker.wave.2.fill", size: 38, label: "انطق الكلمة") { Self.speak(w.raw) }
    }

    // cards

    private func cardBody(_ b: Book, _ w: NoteItem) -> some View {
        VStack(spacing: 14) {
            card(b, w)
            if !flipped {
                Button { withAnimation(.easeInOut(duration: 0.45)) { flipped = true } } label: { Text(reverse ? "أظهر الكلمة" : "أظهر المعنى").frame(maxWidth: .infinity) }
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

    private func meaningFace(_ r: JSONObject) -> some View {
        VStack(spacing: 8) {
            if !r.str("tr").isEmpty { Text(r.str("tr")).font(JFont.display(26, .semibold)).foregroundStyle(Color(L.primary)) }
            if !r.str("meaning").isEmpty { Text(r.str("meaning")).font(JFont.body(16)) }
        }
    }

    private func wordFace(_ b: Book, _ w: NoteItem, subtitle: Bool) -> some View {
        VStack(spacing: 8) {
            Text(w.raw.str("word")).font(JFont.display(30, .bold))
            if subtitle {
                Text([Words.lang(w.raw.str("lang")), b.title].filter { !$0.isEmpty }.joined(separator: " · ")).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
            }
            speakButton(w)
        }
    }

    private func card(_ b: Book, _ w: NoteItem) -> some View {
        let r = w.raw
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(L.surface2))
            if flipped {
                Group {
                    if reverse { wordFace(b, w, subtitle: false) } else { meaningFace(r) }
                }
                .multilineTextAlignment(.center).padding(20)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            } else {
                VStack(spacing: 8) {
                    if reverse { meaningFace(r) } else { wordFace(b, w, subtitle: true) }
                    Text("اضغط لتقلب").font(JFont.body(12)).foregroundStyle(Color(L.ink2))
                }
                .multilineTextAlignment(.center).padding(20)
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
            saveSRS(b, w, g)
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

    // multiple choice

    private func choiceBody(_ b: Book, _ w: NoteItem) -> some View {
        let correct = Self.answerText(w.raw)
        return VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(L.surface2))
                VStack(spacing: 8) {
                    Text(w.raw.str("word")).font(JFont.display(30, .bold))
                    speakButton(w)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            ForEach(options, id: \.self) { o in
                Button { pick(o, b, w) } label: {
                    HStack {
                        Text(o).font(JFont.body(16)).foregroundStyle(Color(L.ink)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if result != nil && o == correct { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(L.primary)) }
                        if result != nil && o == picked && o != correct { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(L.danger)) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(choiceBorder(o, correct), lineWidth: result == nil ? 1 : 1.5))
                }
                .buttonStyle(.plain)
                .disabled(result != nil)
            }
            if result != nil { nextButton }
        }
    }

    private func choiceBorder(_ o: String, _ correct: String) -> Color {
        guard result != nil else { return Color(L.line) }
        if o == correct { return Color(L.primary) }
        if o == picked { return Color(L.danger) }
        return Color(L.line)
    }

    private func pick(_ o: String, _ b: Book, _ w: NoteItem) {
        guard result == nil else { return }
        picked = o
        finish(o == Self.answerText(w.raw), b, w)
    }

    // typing

    private func typedBody(_ b: Book, _ w: NoteItem) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(L.surface2))
                meaningFace(w.raw).multilineTextAlignment(.center).padding(20)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            if let ok = result {
                HStack(spacing: 10) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(Color(ok ? L.primary : L.danger))
                    Text(w.raw.str("word")).font(JFont.display(24, .bold)).foregroundStyle(Color(ok ? L.primary : L.danger))
                    speakButton(w)
                }
                if !ok && !typed.isEmpty { Text(typed).font(JFont.body(14)).foregroundStyle(Color(L.ink2)).strikethrough() }
                nextButton
            } else {
                TextField("اكتب الكلمة", text: $typed)
                    .font(JFont.body(18)).foregroundStyle(Color(L.ink))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($typing).submitLabel(.done).onSubmit { check(b, w) }
                    .padding(.horizontal, 14).frame(minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface2)))
                HStack(spacing: 8) {
                    Button { finish(false, b, w) } label: { Text("ما أعرفها").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
                    Button { check(b, w) } label: { Text("تحقق").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func check(_ b: Book, _ w: NoteItem) {
        guard result == nil, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        typing = false
        finish(Self.norm(typed) == Self.norm(w.raw.str("word")), b, w)
    }

    private var nextButton: some View {
        Button { advance() } label: { Text("التالي").frame(maxWidth: .infinity) }
            .buttonStyle(JButtonStyle(look: L, primary: true))
    }

    // MARK: - end screen

    private var endView: some View {
        VStack(spacing: 14) {
            Text("انتهت المراجعة").font(JFont.display(19, .semibold))
            HStack(spacing: 10) {
                stat(known, "صح", Color(L.primary))
                stat(max(0, done - known), "غلط", Color(L.danger))
            }
            if !missed.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("الكلمات التي أخطأت فيها").font(JFont.display(16, .semibold)).padding(.bottom, 6)
                    ForEach(Array(missed.enumerated()), id: \.offset) { _, m in
                        if let b = lib.state.book(m.book), let w = b.words.first(where: { $0.id == m.id }) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(w.raw.str("word")).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink))
                                Spacer(minLength: 8)
                                Text(Self.answerText(w.raw)).font(JFont.body(14)).foregroundStyle(Color(L.ink2)).multilineTextAlignment(.trailing)
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
                        }
                    }
                }
                Button { reviewMissed() } label: { Text("راجع الغلطات").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L, primary: true))
            }
            HStack {
                Button("مرة ثانية") { load(all: true) }.buttonStyle(JButtonStyle(look: L))
                Button("تم") { dismiss() }.buttonStyle(JButtonStyle(look: L, primary: !missed.isEmpty ? false : true))
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { Haptics.play(missed.isEmpty ? "success" : "soft") }
    }

    // MARK: - flow

    private func load(all: Bool) {
        var pool = Self.pool(sel)
        // The other two ways need a meaning to show or to pick.
        if mode != .cards { pool = pool.filter { !Self.answerText($0.item.raw).isEmpty } }
        var list: [(book: String, id: String)]
        if srs && !all {
            list = pool.filter { Self.isDue($0.item) }.sorted { ($0.item.raw["srs"]?.object?.num("due") ?? 0) < ($1.item.raw["srs"]?.object?.num("due") ?? 0) }.map { ($0.book.id, $0.item.id) }
        } else {
            list = pool.map { ($0.book.id, $0.item.id) }.shuffled()
        }
        begin(list)
    }

    private func reviewMissed() { begin(missed) }

    private func begin(_ list: [(book: String, id: String)]) {
        queue = list; i = 0; done = 0; known = 0; flipped = false; started = true; missed = []
        prepare()
    }

    /// Sets up the question at `i`: the four choices, or an empty answer box.
    private func prepare() {
        picked = nil; result = nil; typed = ""
        guard mode == .choice, queue.indices.contains(i), let b = lib.state.book(queue[i].book),
              let w = b.words.first(where: { $0.id == queue[i].id }) else { options = []; return }
        let correct = Self.answerText(w.raw)
        let others = Set(Self.pool(nil).map { Self.answerText($0.item.raw) }.filter { !$0.isEmpty && $0 != correct })
        options = (Array(others.shuffled().prefix(3)) + [correct]).shuffled()
    }

    /// The SRS save the card buttons use; right and wrong answers of the other ways go through it too.
    private func saveSRS(_ b: Book, _ w: NoteItem, _ g: String) {
        let n = Self.schedule(w.raw["srs"]?.object, g)
        lib.changeBook(b.id) { x in
            var list = x.raw.objs("words")
            if let j = list.firstIndex(where: { $0.str("id") == w.id }) { list[j]["srs"] = .object(n) }
            x.raw.set("words", objects: list)
        }
    }

    /// An answer in the choice or typing way: schedule it like «عرفتها» / «مرة أخرى», but wait for «التالي».
    private func finish(_ ok: Bool, _ b: Book, _ w: NoteItem) {
        guard result == nil else { return }
        result = ok
        if srs {
            saveSRS(b, w, ok ? "good" : "again")
            if !ok { queue.append(queue[i]) }
        }
        record(ok)
    }

    /// Counts the answer and gives the feedback (haptic, colour flash).
    private func record(_ ok: Bool) {
        done += 1
        if ok {
            known += 1
        } else if queue.indices.contains(i), !missed.contains(where: { $0.book == queue[i].book && $0.id == queue[i].id }) {
            missed.append(queue[i])
        }
        Haptics.play(ok ? "success" : "warn")
        withAnimation(.easeOut(duration: 0.15)) { flash = Color(ok ? L.primary : L.danger) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { withAnimation(.easeIn(duration: 0.3)) { flash = .clear } }
    }

    private func next(knew: Bool) {
        record(knew)
        advance()
    }

    private func advance() {
        flipped = false
        i += 1
        prepare()
    }

    // MARK: - speech

    /// Says the word in its language: the word's own language, else Arabic for Arabic letters and English otherwise.
    private static func speak(_ r: JSONObject) {
        let word = r.str("word")
        guard !word.isEmpty else { return }
        let code = r.str("lang")
        let tags = ["en": "en-US", "ar": "ar-SA", "fr": "fr-FR", "es": "es-ES", "de": "de-DE", "tr": "tr-TR", "it": "it-IT",
                    "ru": "ru-RU", "ja": "ja-JP", "ko": "ko-KR", "zh": "zh-CN", "pt": "pt-BR"]
        let isArabic = word.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        let tag = code.isEmpty ? (isArabic ? "ar-SA" : "en-US") : (tags[code.lowercased()] ?? code)
        // The silent switch would mute plain speech; mix so the ambient sounds keep going.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: word)
        u.voice = AVSpeechSynthesisVoice(language: tag)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synth.speak(u)
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
