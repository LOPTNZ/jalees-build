import SwiftUI
import UIKit

// The notebook's pieces (docs/plan/notebook-2.4.md): the same cards, chips and actions in دفتري, a book's notebook
// page and the reader's «دفتر الرواية». Each takes plain values (NBEntry) and watches nothing.

// MARK: - what a tap or a held entry does

/// The sheets the notebook opens over itself (each screen holds its own, so one opens where you are: the tab, a
/// book's page, or over the reader).
enum NBSheet: Identifiable {
    case form(ItemRef)
    case note(MarkRef)
    case tags(NBEntry)
    case card(CardRequest)
    case review(String?)
    case character(String, String)

    var id: String {
        switch self {
        case .form(let r): return "f" + r.id.uuidString
        case .note(let r): return "n" + r.id.uuidString
        case .tags(let e): return "t" + e.id
        case .card(let r): return "c" + r.id.uuidString
        case .review(let b): return "r" + (b ?? "")
        case .character(let b, let c): return "h" + b + c
        }
    }
}

struct NBSheets: ViewModifier {
    @Binding var sheet: NBSheet?
    @Environment(\.look) private var L

    func body(content: Content) -> some View {
        content.sheet(item: $sheet) { s in
            Group {
                switch s {
                case .form(let r): ItemForm(ref: r)
                case .note(let r):
                    NoteSheet(text: r.mark.str("text"), note: r.mark.str("note"), dark: L.dark) { NovelLibrary.setMarkNote(r.book, r.mark.str("id"), $0) }
                case .tags(let e): TagSheet(entry: e)
                case .card(let r): CardSheet(request: r).presentationDetents([.large])
                case .review(let b): WordReview(bookID: b)
                case .character(let b, let c): CharacterCard(bookID: b, charID: c)
                }
            }
            .environment(\.look, L)
            .environment(\.layoutDirection, Lang.direction)
            .environment(\.locale, Lang.locale)
        }
    }
}

extension View {
    func nbSheets(_ sheet: Binding<NBSheet?>) -> some View { modifier(NBSheets(sheet: sheet)) }
}

/// What a tap or a held entry does: in دفتري, or in the reader's list (where the reader opens the place, forms and
/// cards over its page).
@MainActor
struct NBDo {
    var reader: NBReaderLink? = nil
    var show: (NBSheet) -> Void
    /// set where a deletion asks first (the reader's list: an undo toast would be under the reader)
    var ask: ((NBEntry) -> Void)? = nil
    /// picking several entries (the selection), or starting to
    var pick: ((NBEntry) -> Void)? = nil
    /// on a book's own notebook (no «دفتر الكتاب» in the menus)
    var inBook = false
    /// the novel's chapters where they are at hand (a book's page): a character's first appearance opens there
    var chapters: NBChapters? = nil

    /// the chapter a character first appears in, when it is known and in the novel
    func firstChapter(_ e: NBEntry) -> Int? {
        guard e.kind == .char, let map = reader?.chapters ?? chapters else { return nil }
        return map.chapter(number: e.num)
    }

    /// A tap: a passage with a place in a novel opens the text there; a character its card; anything else its form.
    func open(_ e: NBEntry) {
        switch e.kind {
        case .char: character(e)
        case .bmark: openPlace(e)
        case .word: edit(e)
        default: if canOpenPlace(e) { openPlace(e) } else { edit(e) }
        }
    }

    func canOpenPlace(_ e: NBEntry) -> Bool {
        guard e.ch != 0 else { return false }
        if let r = reader { return r.chapters.order[e.ch] != nil }
        return Library.shared.state.book(e.book)?.novel != nil
    }

    func canOpenChapter(_ ch: Int, book: String) -> Bool {
        guard ch != 0 else { return false }
        if let r = reader { return r.chapters.order[ch] != nil }
        return Library.shared.state.book(book)?.novel != nil
    }

    /// The reader, at the passage (the open one in the reader's list).
    func openPlace(_ e: NBEntry) {
        if let r = reader { r.open(e.ch, e.p); return }
        guard let n = Library.shared.state.book(e.book)?.novel else { return }
        NovelBridge.openReader(novel: n.novelID, book: e.book, index: nil, chapter: e.ch, paragraph: e.p)
    }

    /// The reader, at the start of a chapter (a chapter's heading, a character's first appearance).
    func openChapter(_ ch: Int, book: String) {
        if let r = reader { r.open(ch, 0); return }
        guard let n = Library.shared.state.book(book)?.novel else { return }
        NovelBridge.openReader(novel: n.novelID, book: book, index: nil, chapter: ch, paragraph: 0)
    }

    /// Its form (a highlight: its note), over the page in the reader.
    func edit(_ e: NBEntry) {
        switch e.kind {
        case .mark:
            guard let m = Library.shared.state.book(e.book)?.marks.first(where: { $0.str("id") == e.rawID }) else { return }
            if let r = reader, let any = JSONValue.object(m).any as? [String: Any] { r.editNote(any) } else { show(.note(MarkRef(book: e.book, mark: m))) }
        case .bmark:
            break
        default:
            if let r = reader { r.editItem(e.kind.rawValue, e.rawID) } else { show(.form(ItemRef(book: e.book, kind: e.kind.rawValue, item: e.rawID))) }
        }
    }

    func character(_ e: NBEntry) {
        if let r = reader { r.openCharacter(e.rawID) } else { show(.character(e.book, e.rawID)) }
    }

    func copy(_ e: NBEntry) {
        UIPasteboard.general.string = NotebookExport.plain(e)
        Haptics.play("soft")
        Toaster.show("تم النسخ")
    }

    /// The passage as a picture in the book's colours (a quote: its own card, with its speaker or photo).
    func card(_ e: NBEntry) {
        if e.kind == .quote { show(.card(CardRequest(kind: .quote, book: e.book, quote: e.rawID))) }
        else { show(.card(CardRequest(kind: .quote, book: e.book, quote: nil, text: e.text))) }
    }

    func toggleFav(_ e: NBEntry) { NoteItems.toggleFav(e.book, e.rawID) }

    func tags(_ e: NBEntry) { show(.tags(e)) }

    /// Your friends see it in their feed (Wird/Social), when you share your reading with them.
    var canShareWithFriends: Bool { SocialStore.shared.signedIn && SocialStore.shared.shareReading }

    func shareWithFriends(_ e: NBEntry) {
        guard let b = Library.shared.state.book(e.book), !e.text.isEmpty else { return }
        SocialStore.shared.shareQuote(title: b.title, author: b.author, text: e.text)
        Haptics.play("success")
        Toaster.show("انشارك مع أصدقائك")
    }

    func openBook(_ e: NBEntry) { BookLayer.shared.open(e.book) }

    func openNotebook(_ e: NBEntry) { Router.shared.push(.notebook(e.book, ""), in: .notebook) }

    /// A highlight made a quote or a thought: its form, filled from it; once saved, the highlight is its place and
    /// its note moves into it (as «للدفتر» on a highlight in the reader).
    func promote(_ e: NBEntry, _ k: NoteKind) {
        guard e.kind == .mark, k == .quote || k == .thought else { return }
        let itemID = uid()
        var pre: [String: Any] = ["id": itemID, "mark": e.rawID]
        if e.ch != 0 { pre["nv"] = ["ch": e.ch, "p": e.p, "s": e.s, "label": e.place] as [String: Any] }
        if let n = e.num { pre["loc"] = n }
        let note = e.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if k == .quote {
            pre["text"] = e.text
            if !note.isEmpty { pre["note"] = note }
        } else {
            pre["passage"] = e.text
            if !note.isEmpty { pre["text"] = note }
        }
        if !e.tags.isEmpty { pre["tags"] = e.tags }
        NoteItems.pending[itemID] = (book: e.book, mark: e.rawID, kind: k.rawValue, moveNote: !note.isEmpty)
        show(.form(ItemRef(book: e.book, kind: k.rawValue, item: nil, prefill: pre, inReader: reader != nil)))
    }

    func delete(_ e: NBEntry) {
        if let a = ask, e.kind != .mark, e.kind != .bmark { a(e); return }
        deleteNow(e)
    }

    func deleteNow(_ e: NBEntry) {
        switch e.kind {
        case .mark:
            if reader != nil { NovelLibrary.markDel(e.book, e.rawID); Haptics.play("warn") } else { NoteItems.deleteMark(e.book, e.rawID) }
        case .bmark:
            NovelLibrary.bmarkDel(e.book, e.rawID)
            Haptics.play("warn")
        default:
            if let k = e.kind.note { NoteItems.delete(e.book, k, e.rawID) }
        }
    }
}

/// What a held entry offers, wherever it is listed.
struct NBMenu: View {
    let e: NBEntry
    let act: NBDo

    var body: some View {
        if act.canOpenPlace(e) {
            Button { act.openPlace(e) } label: { Label("افتح مكانه في القارئ", systemImage: "book") }
        }
        switch e.kind {
        case .mark:
            Button { act.edit(e) } label: { Label(e.note.isEmpty ? "إضافة ملاحظة" : "تعديل الملاحظة", systemImage: "note.text") }
            Menu {
                Button { act.promote(e, .quote) } label: { Label("اقتباس", systemImage: NoteKind.quote.symbol) }
                Button { act.promote(e, .thought) } label: { Label("فكرة", systemImage: NoteKind.thought.symbol) }
            } label: {
                Label("للدفتر", systemImage: "book.closed")
            }
        case .bmark:
            EmptyView()
        case .char:
            Button { act.character(e) } label: { Label("البطاقة", systemImage: "person.text.rectangle") }
            if let ch = act.firstChapter(e) {
                Button { act.openChapter(ch, book: e.book) } label: { Label("أول ظهور في القارئ", systemImage: "book") }
            }
            Button { act.edit(e) } label: { Label("تعديل", systemImage: "pencil") }
        default:
            Button { act.edit(e) } label: { Label("تعديل", systemImage: "pencil") }
        }
        if e.kind == .quote {
            Button { act.toggleFav(e) } label: { Label(e.fav ? "إزالة من المفضّلة" : "للمفضّلة", systemImage: e.fav ? "star.slash" : "star") }
        }
        if e.kind != .bmark {
            Button { act.copy(e) } label: { Label("نسخ", systemImage: "doc.on.doc") }
        }
        if (e.kind == .quote || e.kind == .mark) && !e.text.isEmpty {
            Button { act.card(e) } label: { Label("مشاركة كبطاقة", systemImage: "square.and.arrow.up") }
            if act.canShareWithFriends && !e.spoiler {
                Button { act.shareWithFriends(e) } label: { Label("شاركه مع أصدقائك", systemImage: "person.2") }
            }
        }
        if e.kind != .bmark {
            Button { act.tags(e) } label: { Label(e.tags.isEmpty ? "وسوم" : "تعديل الوسوم", systemImage: "number") }
        }
        if let p = act.pick {
            Button { p(e) } label: { Label("تحديد", systemImage: "checkmark.circle") }
        }
        if act.reader == nil {
            if !act.inBook {
                Button { act.openNotebook(e) } label: { Label("دفتر الكتاب", systemImage: "book.closed") }
            }
            Button { act.openBook(e) } label: { Label("صفحة الكتاب", systemImage: "info.circle") }
        }
        Divider()
        Button(role: .destructive) { act.delete(e) } label: { Label("حذف", systemImage: "trash") }
    }
}

// MARK: - small pieces

/// A chip of the notebook's filters. What a reader of the screen (and a walk-through test) hears is its name; the
/// count is its value.
struct NBChip: View {
    let text: String
    var count: Int? = nil
    var dot: UIColor? = nil
    var symbol: String? = nil
    var on = false
    let action: () -> Void
    @Environment(\.look) private var L

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let d = dot { Circle().fill(Color(d)).frame(width: 9, height: 9) }
                if let s = symbol { Image(systemName: s).font(.system(size: 11.5, weight: .semibold)) }
                Text(text).font(JFont.body(14, on ? .semibold : .regular)).lineLimit(1)
                if let c = count { Text(verbatim: "\(c)").font(JFont.body(12.5, .medium)).opacity(0.7).monospacedDigit() }
            }
            .foregroundStyle(Color(on ? L.onPrimary : L.ink))
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(Capsule().fill(on ? Color(L.primary) : Color(L.surface)))
            .overlay(Capsule().strokeBorder(Color(on ? L.primary : L.line), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityValue(Text(verbatim: count.map { "\($0)" } ?? ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A section's title on the notebook's pages, with a count and a line under it.
struct NBTitle: View {
    let title: String
    var count: Int? = nil
    var sub: String? = nil
    @Environment(\.look) private var L

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(JFont.display(20, .semibold)).foregroundStyle(Color(L.ink))
                if let c = count, c > 0 { Text(verbatim: "\(c)").font(JFont.body(14, .medium)).foregroundStyle(Color(L.ink2)).monospacedDigit() }
            }
            if let s = sub, !s.isEmpty { Text(s).font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
        }
    }
}

/// A card pressed in a little.
struct NBPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The tick of an entry while several are being picked.
struct NBCheck: View {
    let on: Bool
    @Environment(\.look) private var L

    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(on ? Color(L.primary) : Color(L.ink2))
            .background(Circle().fill(Color(L.surface)).padding(2))
    }
}

/// A book's small cover and title above an entry listed among other books'.
struct NBBookLine: View {
    let book: Book
    @Environment(\.look) private var L

    var body: some View {
        HStack(spacing: 8) {
            BookCover(book: book, radius: 3, marks: false).frame(width: 18)
            Text(verbatim: book.title).font(JFont.body(12.5, .semibold)).foregroundStyle(Color(L.ink2)).lineLimit(1)
        }
    }
}

/// An entry's tags.
struct NBTags: View {
    let tags: [String]
    @Environment(\.look) private var L

    var body: some View {
        Flow(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                Text(verbatim: "#" + t).font(JFont.body(12, .medium)).foregroundStyle(Color(L.accentInk))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color(L.accentSoft)))
            }
        }
    }
}

/// A word's review, as a name and a colour: new, learning, known.
enum NBStage {
    static func name(_ s: Int) -> String { ["جديدة", "أتعلّمها", "حفظتها"][min(max(s, 0), 2)] }
    static func color(_ s: Int, _ L: JLook) -> Color { s <= 0 ? Color(L.ink2) : (s == 1 ? Color(L.accent) : Color(L.primary)) }
}

/// A word's review as a small ring (empty, half, full), with a dot when it is due.
struct NBStageDot: View {
    let stage: Int
    let due: Bool
    @Environment(\.look) private var L

    var body: some View {
        let parts: [CGFloat] = [0.08, 0.5, 1]
        ZStack {
            Circle().stroke(Color(L.line), lineWidth: 2.5)
            Circle().trim(from: 0, to: parts[min(max(stage, 0), 2)])
                .stroke(NBStage.color(stage, L), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if due && Library.shared.state.settings.raw.str("review", "srs") == "srs" {
                Circle().fill(Color(L.accent)).frame(width: 6, height: 6)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityElement()
        .accessibilityLabel(NBStage.name(stage))
    }
}

// MARK: - a passage

/// A passage (a quote, a highlight, a thought) as a card: its words in the book's type, your note under them, the
/// colour it was highlighted in, its tags, and its place. A tap opens the text there (a novel), or its form.
struct PassageCard: View {
    let e: NBEntry
    let act: NBDo
    var book: Book? = nil
    var showBook = false
    var compact = false
    /// nil: not picking; else whether this one is picked
    var picked: Bool? = nil
    @Environment(\.look) private var L

    var body: some View {
        Button {
            if picked != nil, let p = act.pick { p(e) } else { act.open(e) }
        } label: {
            card
        }
        .buttonStyle(NBPress())
        .contextMenu { NBMenu(e: e, act: act) }
    }

    private var tint: Color {
        if let c = e.color, let m = MarkColor(rawValue: c) { return Color(hex: m.hex) }
        return e.kind == .thought ? Color(L.accent) : Color(L.primary)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showBook, let b = book { NBBookLine(book: b) }
            if let img = e.img, let i = Library.shared.image(img) {
                Image(uiImage: i).resizable().scaledToFit().frame(maxHeight: compact ? 180 : 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !e.text.isEmpty { words }
            if e.kind == .thought && !e.sub.isEmpty {
                Text(verbatim: e.sub).font(JFont.quote(15.5)).foregroundStyle(Color(L.ink2)).lineSpacing(4).lineLimit(compact ? 3 : nil)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(L.line)).frame(width: 3) }
            }
            if e.kind == .quote && !e.sub.isEmpty {
                Text(verbatim: "— " + e.sub).font(JFont.body(13.5, .medium)).foregroundStyle(Color(L.ink2))
            }
            if !e.note.isEmpty && e.kind != .thought { noteBox }
            if !e.tags.isEmpty { NBTags(tags: e.tags) }
            footer
        }
        .padding(.vertical, 14).padding(.leading, 20).padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(L.surface)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint).frame(width: 4).padding(.vertical, 14).padding(.leading, 8)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(picked == true ? L.primary : L.line), lineWidth: picked == true ? 2 : 1))
        .overlay(alignment: .topTrailing) { if let p = picked { NBCheck(on: p).padding(10) } }
    }

    private var words: some View {
        let quoted = e.kind == .quote && e.img == nil
        return Text(verbatim: quoted ? "«" + e.text + "»" : e.text)
            .font(e.kind == .thought ? JFont.body(16) : JFont.quote(compact ? 17.5 : 19))
            .foregroundStyle(Color(L.ink))
            .lineSpacing(e.kind == .thought ? 3 : 6)
            .lineLimit(compact ? 5 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .spoiler(e.spoiler)
    }

    private var noteBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble").font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).padding(.top, 3)
            Text(verbatim: e.note).font(JFont.body(14.5)).foregroundStyle(Color(L.ink)).lineLimit(compact ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(L.surface2).opacity(0.7)))
    }

    private var footer: some View {
        let open = act.canOpenPlace(e)
        return HStack(spacing: 6) {
            Image(systemName: e.kind.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(verbatim: meta(open)).font(JFont.body(12)).foregroundStyle(Color(L.ink2)).lineLimit(1)
            Spacer(minLength: 4)
            if e.fav { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color(L.star)) }
            if open {
                HStack(spacing: 3) {
                    Text(verbatim: shortPlace).font(JFont.body(12, .medium)).lineLimit(1)
                    Image(systemName: "chevron.forward").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color(L.primary))
            }
        }
    }

    /// «اقتباس · معلومة · 12 نوفمبر», the place too when it does not open the reader
    private func meta(_ open: Bool) -> String {
        var parts: [String] = []
        if e.kind == .mark, let c = e.color { parts.append(NotebookExport.colorName(c)) } else { parts.append(e.kind.name.tr) }
        if e.kind != .mark, let c = e.color { parts.append(NotebookExport.colorName(c)) }
        if !open && !e.place.isEmpty { parts.append(e.place.tr) }
        parts.append(Words.date(e.at))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// «الفصل 37» (without its title)
    private var shortPlace: String {
        let head = e.place.split(separator: ":").first.map(String.init) ?? e.place
        return String(head.trimmingCharacters(in: .whitespaces).prefix(24)).tr
    }
}

/// A passage to read again today: the book's colours, its words large, where it is.
struct TodayCard: View {
    let e: NBEntry
    let book: Book?
    let act: NBDo
    @Environment(\.look) private var L

    var body: some View {
        Button { act.open(e) } label: { face }
            .buttonStyle(NBPress())
            .contextMenu { NBMenu(e: e, act: act) }
            // heard as its words and its book (its kind's name first would sound like the + fan's items)
            .accessibilityLabel(Text(verbatim: [e.text, e.note, book?.title ?? "", e.place.tr].filter { !$0.isEmpty }.joined(separator: "، ")))
    }

    private var face: some View {
        let hsl: (Double, Double, Double) = book.map { Cards.hsl($0) } ?? (160, 38, 32)
        let top = Cards.color(hsl.0, hsl.1, min(40, hsl.2 + 6))
        let bottom = Cards.color(hsl.0, hsl.1 * 0.6, 10)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: e.kind.symbol).font(.system(size: 11, weight: .bold))
                Text(e.kind == .mark ? (e.color.map { NotebookExport.colorName($0) } ?? e.kind.name) : e.kind.name).font(JFont.body(12, .semibold))
                if let c = e.color, let m = MarkColor(rawValue: c) { Circle().fill(Color(hex: m.hex)).frame(width: 8, height: 8) }
                Spacer(minLength: 0)
                if e.fav { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color(hex: "#ffd36b")) }
            }
            .foregroundStyle(Color.white.opacity(0.78))
            Spacer(minLength: 0)
            if let img = e.img, e.text.isEmpty, let i = Library.shared.image(img) {
                Image(uiImage: i).resizable().scaledToFit().frame(maxHeight: 150).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !e.text.isEmpty {
                Text(verbatim: e.kind == .quote ? "«" + e.text + "»" : e.text)
                    .font(e.kind == .thought ? JFont.body(17, .medium) : JFont.quote(21))
                    .foregroundStyle(Color.white).lineSpacing(6).lineLimit(6).minimumScaleFactor(0.8)
            }
            if !e.note.isEmpty && e.kind != .thought {
                Text(verbatim: e.note).font(JFont.body(13.5)).foregroundStyle(Color.white.opacity(0.8)).lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if let b = book { BookCover(book: b, radius: 3, marks: false).frame(width: 24) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: book?.title ?? "").font(JFont.body(13, .semibold)).foregroundStyle(Color.white).lineLimit(1)
                    if !e.place.isEmpty { Text(e.place).font(JFont.body(11.5)).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if act.canOpenPlace(e) {
                    Image(systemName: "book.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white)
                        .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.16)))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260, alignment: .topLeading)
        .background(LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - a word, a character, a line

/// A word as a card: the word, its translation and meaning, its sentence from the book, its review.
struct WordTile: View {
    let e: NBEntry
    let act: NBDo
    var book: Book? = nil
    var showBook = false
    var picked: Bool? = nil
    @Environment(\.look) private var L

    var body: some View {
        Button {
            if picked != nil, let p = act.pick { p(e) } else { act.open(e) }
        } label: {
            tile
        }
        .buttonStyle(NBPress())
        .contextMenu { NBMenu(e: e, act: act) }
        .accessibilityIdentifier("nb-word-" + e.rawID)
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: e.text).font(JFont.display(20, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                NBStageDot(stage: e.stage, due: e.due)
            }
            if !e.alt.isEmpty { Text(verbatim: e.alt).font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.primary)).lineLimit(1) }
            if !e.sub.isEmpty { Text(verbatim: e.sub).font(JFont.body(13.5)).foregroundStyle(Color(L.ink)).lineLimit(3) }
            if !e.note.isEmpty { Text(verbatim: "«" + e.note + "»").font(JFont.quote(14)).foregroundStyle(Color(L.ink2)).lineLimit(2) }
            Spacer(minLength: 0)
            Text(verbatim: meta).font(JFont.body(11.5)).foregroundStyle(Color(L.ink2)).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(picked == true ? L.primary : L.line), lineWidth: picked == true ? 2 : 1))
        .overlay(alignment: .topTrailing) { if let p = picked { NBCheck(on: p).padding(6) } }
    }

    private var meta: String {
        [NBStage.name(e.stage).tr, e.place.tr, showBook ? (book?.title ?? "") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A character in the gallery: its face, name, alias, first appearance.
struct CharacterTile: View {
    let e: NBEntry
    let act: NBDo
    var book: Book? = nil
    var showBook = false
    var picked: Bool? = nil
    @Environment(\.look) private var L

    var body: some View {
        Button {
            if picked != nil, let p = act.pick { p(e) } else { act.open(e) }
        } label: {
            VStack(spacing: 6) {
                Avatar(name: e.text, photo: e.photo, size: 62)
                    .overlay(Circle().strokeBorder(e.role == "main" ? Color(L.primary) : Color.clear, lineWidth: 2.5))
                Text(verbatim: e.text).font(JFont.body(14, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1)
                if !e.sub.isEmpty { Text(verbatim: e.sub).font(JFont.body(12)).foregroundStyle(Color(L.ink2)).lineLimit(1) }
                if !e.place.isEmpty { Text("أول ظهور: " + e.place).font(JFont.body(11.5, .medium)).foregroundStyle(Color(L.primary)).lineLimit(1) }
                if showBook, let b = book { Text(verbatim: b.title).font(JFont.body(11.5)).foregroundStyle(Color(L.ink2)).lineLimit(1) }
            }
            .padding(.vertical, 14).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(picked == true ? L.primary : L.line), lineWidth: picked == true ? 2 : 1))
            .overlay(alignment: .topTrailing) { if let p = picked { NBCheck(on: p).padding(6) } }
        }
        .buttonStyle(NBPress())
        .contextMenu { NBMenu(e: e, act: act) }
    }
}

/// One entry on a line: the timeline, the newest on the home, the bookmarks.
struct NBRow: View {
    let e: NBEntry
    let act: NBDo
    var book: Book? = nil
    var showBook = false
    /// as a card of its own (among passage cards), not a line of a list
    var boxed = false
    @Environment(\.look) private var L

    var body: some View {
        Button { act.open(e) } label: {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: headline).font(headFont).foregroundStyle(Color(L.ink)).lineLimit(3).lineSpacing(3)
                    if !detail.isEmpty { Text(verbatim: detail).font(JFont.body(13)).foregroundStyle(Color(L.ink2)).lineLimit(2) }
                    Text(verbatim: meta).font(JFont.body(11.5)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, boxed ? 12 : 11)
            .padding(.horizontal, boxed ? 14 : 0)
            .contentShape(Rectangle())
            .background { if boxed { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(L.surface)) } }
            .overlay {
                if boxed { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1) }
            }
            .overlay(alignment: .bottom) { if !boxed { Rectangle().fill(Color(L.line)).frame(height: 1) } }
        }
        .buttonStyle(NBPress())
        .contextMenu { NBMenu(e: e, act: act) }
    }

    private var tint: Color {
        if let c = e.color, let m = MarkColor(rawValue: c) { return Color(hex: m.hex) }
        switch e.kind {
        case .thought: return Color(L.accent)
        case .bmark: return Color(L.danger)
        default: return Color(L.primary)
        }
    }

    @ViewBuilder private var icon: some View {
        if e.kind == .char {
            Avatar(name: e.text, photo: e.photo, size: 36)
        } else {
            Image(systemName: e.kind.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(tint.opacity(0.16)))
        }
    }

    private var headFont: Font {
        switch e.kind {
        case .quote, .mark: return JFont.quote(17)
        case .word, .char: return JFont.body(15.5, .semibold)
        default: return JFont.body(15)
        }
    }

    private var headline: String {
        switch e.kind {
        case .quote: return "«" + e.text + "»"
        case .bmark: return "وقفة".tr + (e.place.isEmpty ? "" : " · " + e.place.tr)
        default: return e.text
        }
    }

    private var detail: String {
        switch e.kind {
        case .word: return [e.alt, e.sub].filter { !$0.isEmpty }.joined(separator: " · ")
        case .char: return e.sub.isEmpty ? e.note : e.sub
        case .mark, .quote: return e.note
        case .thought: return e.sub
        case .bmark: return ""
        }
    }

    private var meta: String {
        var parts: [String] = [e.kind == .mark ? (e.color.map { NotebookExport.colorName($0) } ?? e.kind.name.tr) : e.kind.name.tr]
        if e.kind != .bmark && !e.place.isEmpty { parts.append(e.place.tr) }
        if showBook, let b = book { parts.append(b.title) }
        parts.append(Words.date(e.at))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A book on the shelf of notebooks: its cover, its title, what was kept from it.
struct BookNotebookCard: View {
    let book: Book
    let info: NBBook
    @Environment(\.look) private var L

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BookCover(book: book, radius: 6, marks: false)
                .frame(width: min(100, 150 * CGFloat(book.coverAspect)))
                .shadow(color: .black.opacity(0.28), radius: 8, y: 6)
                .frame(width: 100, height: 150, alignment: .bottom)
            Text(verbatim: book.title).font(JFont.body(13.5, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(2)
                .frame(width: 100, alignment: .leading)
            HStack(spacing: 9) {
                stat("quote.opening", info.n(.quote) + info.n(.mark) + info.n(.thought))
                stat("person", info.n(.char))
                stat("character.book.closed", info.n(.word))
            }
            .frame(width: 100, alignment: .leading)
        }
        .frame(width: 100, alignment: .topLeading)
    }

    @ViewBuilder private func stat(_ s: String, _ n: Int) -> some View {
        if n > 0 {
            HStack(spacing: 2) {
                Image(systemName: s).font(.system(size: 9.5, weight: .semibold))
                Text(verbatim: "\(n)").font(JFont.body(11.5, .medium)).monospacedDigit()
            }
            .foregroundStyle(Color(L.ink2))
        }
    }
}

// MARK: - words' review

/// How the words are doing (new, learning, known) and the review.
struct NBReviewPanel: View {
    let stats: NBIndex.WordStats
    let review: () -> Void
    var anki: (() -> Void)? = nil
    @Environment(\.look) private var L

    var body: some View {
        let srs = Library.shared.state.settings.raw.str("review", "srs") == "srs"
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(L.primary))
                Text("مراجعة الكلمات").font(JFont.body(15.5, .semibold)).foregroundStyle(Color(L.ink))
                Spacer(minLength: 4)
                if srs {
                    Text(stats.due > 0 ? "\(stats.due) مستحقة" : "ما فيه مستحق اليوم").font(JFont.body(13, .medium))
                        .foregroundStyle(Color(stats.due > 0 ? L.accentInk : L.ink2))
                }
            }
            NBStageBar(stats: stats)
            HStack(spacing: 14) {
                legend(0, stats.fresh)
                legend(1, stats.learning)
                legend(2, stats.known)
            }
            HStack(spacing: 8) {
                Button(action: review) { Text(srs && stats.due > 0 ? "مراجعة المستحقة" : "مراجعة").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L, primary: true))
                if let a = anki {
                    Button(action: a) { Text("تصدير لـ Anki") }.buttonStyle(JButtonStyle(look: L))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(L.surface)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    private func legend(_ s: Int, _ n: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(s == 0 ? Color(L.line) : NBStage.color(s, L)).frame(width: 8, height: 8)
            Text(NBStage.name(s)).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
            Text(verbatim: "\(n)").font(JFont.body(12.5, .semibold)).foregroundStyle(Color(L.ink)).monospacedDigit()
        }
    }
}

/// The words' share of each stage, as one bar.
struct NBStageBar: View {
    let stats: NBIndex.WordStats
    @Environment(\.look) private var L

    var body: some View {
        GeometryReader { g in
            let t = CGFloat(max(1, stats.total))
            let w = max(0, g.size.width - 4)
            HStack(spacing: 2) {
                if stats.known > 0 { Capsule().fill(NBStage.color(2, L)).frame(width: max(6, w * CGFloat(stats.known) / t)) }
                if stats.learning > 0 { Capsule().fill(NBStage.color(1, L)).frame(width: max(6, w * CGFloat(stats.learning) / t)) }
                Capsule().fill(Color(L.line)).frame(maxWidth: .infinity)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: - the characters' map

/// The book's characters and how they are related: each face on a ring (the main ones nearer the middle), a line
/// for each relation with its name. A face opens its card.
struct RelationMap: View {
    struct Node: Identifiable {
        let id: String
        let name: String
        let photo: String?
        let main: Bool
    }

    struct Link: Identifiable {
        let a: String
        let b: String
        var label: String
        var id: String { a + "|" + b }
    }

    let nodes: [Node]
    let links: [Link]
    let open: (String) -> Void
    @Environment(\.look) private var L

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let pos = Self.layout(nodes, side: side, width: g.size.width)
            ZStack(alignment: .topLeading) {
                Path { p in
                    for l in links {
                        if let a = pos[l.a], let b = pos[l.b] { p.move(to: a); p.addLine(to: b) }
                    }
                }
                .stroke(Color(L.primary).opacity(0.45), lineWidth: 1.5)
                ForEach(links) { l in
                    if !l.label.isEmpty, let a = pos[l.a], let b = pos[l.b] {
                        Text(verbatim: l.label).font(JFont.body(10.5, .medium)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(L.surface)))
                            .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    }
                }
                ForEach(nodes) { n in
                    if let c = pos[n.id] {
                        Button { open(n.id) } label: {
                            VStack(spacing: 3) {
                                Avatar(name: n.name, photo: n.photo, size: n.main ? 46 : 38)
                                    .overlay(Circle().strokeBorder(n.main ? Color(L.primary) : Color(L.line), lineWidth: 2))
                                Text(verbatim: n.name).font(JFont.body(11, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1).frame(maxWidth: 80)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(n.name)
                        .position(x: c.x, y: c.y + 8)
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        // laid out left to right: in Arabic, .position would mirror x
        .environment(\.layoutDirection, .leftToRight)
    }

    static func layout(_ nodes: [Node], side: CGFloat, width: CGFloat) -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        let c = CGPoint(x: width / 2, y: side / 2)
        func ring(_ l: [Node], _ r: CGFloat, _ start: Double) {
            for (i, n) in l.enumerated() {
                let a = start + Double(i) / Double(max(1, l.count)) * 2 * Double.pi
                out[n.id] = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            }
        }
        guard !nodes.isEmpty else { return out }
        if nodes.count == 1 { out[nodes[0].id] = c; return out }
        let inner = nodes.filter(\.main), outer = nodes.filter { !$0.main }
        if inner.isEmpty || outer.isEmpty || nodes.count <= 4 {
            ring(nodes, side * 0.36, -Double.pi / 2)
        } else {
            if inner.count == 1 { out[inner[0].id] = c } else { ring(inner, side * 0.17, -Double.pi / 2) }
            ring(outer, side * 0.39, -Double.pi / 2 + Double.pi / Double(max(2, outer.count)))
        }
        return out
    }

    /// A book's characters with at least one relation (up to 24), and their relations, each pair once.
    static func of(_ book: Book) -> (nodes: [Node], links: [Link]) {
        let chars = book.chars
        let ids = Set(chars.map(\.id))
        var links: [Link] = []
        var at: [String: Int] = [:]
        for c in chars {
            for r in c.rel {
                let to = r.str("to")
                guard ids.contains(to), to != c.id else { continue }
                let key = [c.id, to].sorted().joined(separator: "|")
                let label = r.str("label").trimmingCharacters(in: .whitespaces)
                if let i = at[key] {
                    if links[i].label.isEmpty && !label.isEmpty { links[i].label = label }
                    continue
                }
                at[key] = links.count
                links.append(Link(a: c.id, b: to, label: label))
            }
        }
        var degree: [String: Int] = [:]
        for l in links { degree[l.a, default: 0] += 1; degree[l.b, default: 0] += 1 }
        let kept = chars.filter { degree[$0.id] != nil }
            .sorted { (degree[$0.id] ?? 0) > (degree[$1.id] ?? 0) }
            .prefix(24)
        let keptIDs = Set(kept.map(\.id))
        let nodes = chars.filter { keptIDs.contains($0.id) }.map { Node(id: $0.id, name: $0.name, photo: $0.photo, main: $0.role == "main") }
        return (nodes, links.filter { keptIDs.contains($0.a) && keptIDs.contains($0.b) })
    }
}

// MARK: - tags

/// An entry's tags: the owner's own collections (حبكة، فلسفة، للمراجعة…).
struct TagSheet: View {
    let entry: NBEntry
    @State private var tags: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L

    init(entry: NBEntry) {
        self.entry = entry
        _tags = State(initialValue: entry.tags)
    }

    var body: some View {
        JSheet(title: "الوسوم", subtitle: String(entry.text.prefix(60)), action: ("حفظ", { NoteItems.setTags(entry, tags); dismiss() })) {
            Text("الوسوم تجمع ما تحفظه على طريقتك: «حبكة»، «فلسفة»، «للمراجعة»… وتصفّي بها في دفتري.")
                .font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
            TagField(tags: $tags, suggestions: NotebookStore.shared.ix.tags)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Tags typed in (Return adds one), with the ones already used offered under the field.
struct TagField: View {
    @Binding var tags: [String]
    var suggestions: [String] = []
    @State private var typed = ""
    @Environment(\.look) private var L

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                Flow(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        Button { tags.removeAll { $0 == t } } label: {
                            HStack(spacing: 4) {
                                Text(verbatim: "#" + t)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .font(JFont.body(13, .medium)).foregroundStyle(Color(L.accentInk))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color(L.accentSoft)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("إزالة الوسم")
                        .accessibilityValue(Text(verbatim: t))
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "number").foregroundStyle(Color(L.ink2))
                TextField("وسم جديد", text: $typed).font(JFont.body(15.5)).autocorrectionDisabled().submitLabel(.done).onSubmit(add)
                if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("أضف", action: add).font(JFont.body(14.5, .semibold)).foregroundStyle(Color(L.primary)).buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
            let more = Array(suggestions.filter { !tags.contains($0) && (typed.isEmpty || $0.localizedCaseInsensitiveContains(typed)) }.prefix(14))
            if !more.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(more, id: \.self) { s in
                            Button { tags.append(s); typed = "" } label: {
                                Text(verbatim: "#" + s).font(JFont.body(13)).foregroundStyle(Color(L.ink))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().strokeBorder(Color(L.line), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let t = typed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let x = String(t.prefix(30))
        if !tags.contains(x) { tags.append(x) }
        typed = ""
    }
}

// MARK: - picking several

/// The bar while several entries are picked: all of them, copy, share as text or Markdown, delete.
struct NBSelectBar: View {
    let count: Int
    let all: () -> Void
    let copy: () -> Void
    let shareText: () -> Void
    let shareMarkdown: () -> Void
    let delete: () -> Void
    let done: () -> Void
    @Environment(\.look) private var L

    var body: some View {
        HStack(spacing: 4) {
            Button(action: done) { Text("إلغاء").font(JFont.body(15, .medium)).foregroundStyle(Color(L.primary)).padding(.horizontal, 8).frame(height: 44) }
                .buttonStyle(.plain)
            Text("\(count) محدد").font(JFont.body(14, .semibold)).foregroundStyle(Color(L.ink)).monospacedDigit()
            Spacer(minLength: 4)
            icon("checklist", "تحديد الكل", all)
            icon("doc.on.doc", "نسخ", copy).disabled(count == 0)
            Menu {
                Button(action: shareText) { Label("نص", systemImage: "doc.plaintext") }
                Button(action: shareMarkdown) { Label("Markdown", systemImage: "number.square") }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .medium)).foregroundStyle(Color(L.ink)).frame(width: 40, height: 44)
            }
            .disabled(count == 0)
            .accessibilityLabel("مشاركة")
            icon("trash", "حذف", delete).disabled(count == 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background(Capsule().fill(Color(L.surface)).shadow(color: .black.opacity(0.3), radius: 12, y: 8))
        .overlay(Capsule().strokeBorder(Color(L.line), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 16 + 70)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func icon(_ s: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: s).font(.system(size: 17, weight: .medium)).foregroundStyle(Color(s == "trash" ? L.danger : L.ink)).frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - the floating +

/// The notebook's floating +: a tap fans out the kinds (and a photographed quote); held 0.3 s, the form of the list
/// you are on opens with the finger still down.
struct NotebookFab: View {
    @Binding var open: Bool
    var dim = false
    /// the kind a hold adds, and the one lit in the fan
    let current: String
    let pick: (String) -> Void
    @Environment(\.look) private var L
    @State private var holdWork: DispatchWorkItem?
    @State private var holdDone = false

    static let items: [(String, String, String)] = [("char", "شخصية", "person"), ("word", "كلمة", "character.book.closed"),
                                                    ("thought", "فكرة", "lightbulb"), ("photo", "صوّر اقتباس", "camera"),
                                                    ("quote", "اقتباس", "quote.opening")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if open {
                ForEach(Array(Self.items.enumerated()), id: \.element.0) { i, it in
                    Button { pick(it.0) } label: { row(it) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(it.1)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.9))
                                                    .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(Double(Self.items.count - 1 - i) * 0.03)),
                                                removal: .opacity.animation(.easeOut(duration: 0.15))))
                }
                .padding(.leading, 6)
            }
            plus
        }
        .padding(.leading, 16).padding(.bottom, 16 + 70)
    }

    private func row(_ it: (String, String, String)) -> some View {
        let cur = it.0 == current
        return HStack(spacing: 10) {
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
        .contentShape(Rectangle())
    }

    private var plus: some View {
        Image(systemName: "plus").font(.system(size: 24, weight: .semibold))
            .rotationEffect(.degrees(open ? 135 : 0))
            .foregroundStyle(Color(L.onPrimary))
            .frame(width: 58, height: 58)
            .background(Circle().fill(Color(L.primary)))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 10)
            .contentShape(Circle())
            // one touch: a tap opens the fan; held 0.3 s, the form for the list you are on opens right then, with the
            // finger still down (SwiftUI's tap + long press pair fired late or not at all)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if holdWork == nil && !holdDone {
                        let w = DispatchWorkItem {
                            holdDone = true
                            Haptics.play("soft")
                            pick(NotebookFab.items.contains { $0.0 == current } ? current : "quote")
                        }
                        holdWork = w
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
                    } else if hypot(g.translation.width, g.translation.height) > 14 {
                        holdWork?.cancel()
                    }
                }
                .onEnded { g in
                    holdWork?.cancel()
                    holdWork = nil
                    if !holdDone && hypot(g.translation.width, g.translation.height) <= 14 { toggle(!open) }
                    holdDone = false
                })
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(open ? "إغلاق القائمة" : "إضافة للدفتر")
            .accessibilityHint("اضغط مطوّلًا لإضافة " + (NoteKind(rawValue: current)?.name ?? "اقتباس"))
            .accessibilityAction { toggle(!open) }
            .opacity(dim && !open ? 0.38 : 1)
            .scaleEffect(dim && !open ? 0.88 : 1)
    }

    private func toggle(_ on: Bool) {
        if on { Haptics.play("soft") }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { open = on }
    }
}

// MARK: - paging rows (iOS 17: a card at a time)

struct NBPagingRow: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollTargetBehavior(.viewAligned).safeAreaPadding(.horizontal, 16)
        } else {
            content
        }
    }
}

struct NBPagingTargets: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollTargetLayout()
        } else {
            content.padding(.horizontal, 16)
        }
    }
}
