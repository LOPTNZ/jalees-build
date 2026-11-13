import SwiftUI
import UIKit

// بطاقة الكتاب and بطاقة الاقتباس (inventory-3, 2.5–2.6): 1080 × 1350 pictures in the book's colours, drawn natively
// and saved through the share sheet (Save Image, Files, AirDrop…).

struct CardRequest: Identifiable {
    enum Kind { case book, quote }
    let id = UUID()
    let kind: Kind
    let book: String
    var quote: String? = nil
}

struct CardSheet: View {
    let request: CardRequest
    @Environment(\.look) private var L
    @State private var image: UIImage?

    var body: some View {
        JSheet(title: request.kind == .book ? "بطاقة الكتاب" : "بطاقة الاقتباس") {
            Group {
                if let i = image {
                    Image(uiImage: i).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel(request.kind == .book ? "بطاقة إحصائيات \(Library.shared.state.book(request.book)?.title ?? "")" : "بطاقة اقتباس")
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            Button { save() } label: { Label("حفظ كصورة", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                .buttonStyle(JButtonStyle(look: L, primary: true)).disabled(image == nil)
        }
        .onAppear { if image == nil { image = Cards.render(request) } }
    }

    private func save() {
        guard let d = image?.pngData() else { ToastCenter.shared.show("تعذّر حفظ الصورة"); return }
        let name = "jalees-\(request.kind == .book ? "igc" : "qcc")-\(Words.dkey(Millis.now)).png"
        Share.data(d, name: name) { done in ToastCenter.shared.show(done ? "تم حفظ الصورة" : "تم الإلغاء") }
    }
}

@MainActor
enum Cards {
    static let W: CGFloat = 1080, H: CGFloat = 1350

    static func render(_ r: CardRequest) -> UIImage? {
        guard let b = Library.shared.state.book(r.book) else { return nil }
        let view: AnyView
        switch r.kind {
        case .book: view = AnyView(BookCardArt(book: b))
        case .quote:
            guard let q = b.items(.quote).first(where: { $0.id == r.quote }) else { return nil }
            view = AnyView(QuoteCardArt(book: b, quote: q))
        }
        let renderer = ImageRenderer(content: view.frame(width: W, height: H).environment(\.layoutDirection, .rightToLeft))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// The book's colour as h, s, l (0–360, 0–100, 0–100).
    static func hsl(_ b: Book) -> (Double, Double, Double) {
        if let c = b.color, c.count >= 3 { return (c[0], c[1], c[2]) }
        return (b.hue, 38, 32)
    }

    static func color(_ h: Double, _ s: Double, _ l: Double) -> Color {
        Color(hue: h / 360, saturation: min(1, max(0, s / 100)), lightness: min(1, max(0, l / 100)))
    }

    // fonts as the web canvas used them
    static func reem(_ size: CGFloat, _ w: UIFont.Weight = .semibold) -> UIFont {
        let d = UIFontDescriptor(fontAttributes: [.family: "Reem Kufi", .traits: [UIFontDescriptor.TraitKey.weight: w]])
        return UIFont(descriptor: d, size: size)
    }
    static func plex(_ size: CGFloat, medium: Bool = false) -> UIFont {
        UIFont(name: medium ? "IBMPlexSansArabic-Medium" : "IBMPlexSansArabic-Regular", size: size) ?? .systemFont(ofSize: size)
    }
    static func amiri(_ size: CGFloat) -> UIFont { UIFont(name: "Amiri-Regular", size: size) ?? .systemFont(ofSize: size) }

    /// The web's wrapLines: words added to a line until it is wider than maxW.
    static func wrap(_ text: String, _ font: UIFont, _ maxW: CGFloat) -> [String] {
        var lines: [String] = []
        var cur = ""
        for w in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let t = cur.isEmpty ? w : cur + " " + w
            if (t as NSString).size(withAttributes: [.font: font]).width > maxW && !cur.isEmpty { lines.append(cur); cur = w } else { cur = t }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    static func speaker(_ b: Book, _ q: NoteItem) -> String {
        let sid = q.raw.str("speakerId")
        if !sid.isEmpty && sid != "__o" { return b.chars.first { $0.id == sid }?.name ?? "" }
        return q.raw.str("speakerName")
    }
}

private extension Text {
    func ui(_ f: UIFont) -> Text { font(Font(f as CTFont)) }
}

// MARK: - بطاقة الكتاب

private struct BookCardArt: View {
    let book: Book
    var body: some View {
        let (h, s, l) = Cards.hsl(book)
        let st = Library.shared.state
        let ss = st.sessions(of: book.id)
        let mins = ss.reduce(0) { $0 + $1.minutes }
        let sp = st.speed(ss, book.unit)
        let days: Int? = book.start.map { s in max(1, Int(((book.finish ?? Millis.now) - s) / DAY)) }
        let cells: [(String, String)] = [
            (days.map { "\($0)" } ?? "—", book.finish != nil ? "أيام القراءة" : "منذ البداية"),
            (mins > 0 ? Words.fmtMin(mins) : "—", book.verbs.time),
            (sp.map { Words.n0($0) } ?? "—", book.unit.pl + " في الساعة"),
            ("\(book.items(.quote).count)", "اقتباسات"),
            ("\(book.items(.thought).count)", "أفكار"),
            book.chars.isEmpty ? ("\(book.items(.word).count)", "كلمات") : ("\(book.chars.count)", "شخصيات"),
        ]
        let titleLines = Array(Cards.wrap(book.title, Cards.reem(64), 940).prefix(2))
        let ch: CGFloat = 480, cw = ch * CGFloat(book.coverAspect)
        VStack(spacing: 0) {
            BookCover(book: book, radius: 0, marks: false)
                .frame(width: cw, height: ch)
                .shadow(color: .black.opacity(0.5), radius: 25, y: 24)
                .padding(.top, 80)
            VStack(spacing: 14) {
                ForEach(titleLines.indices, id: \.self) { i in Text(titleLines[i]).ui(Cards.reem(64)).foregroundColor(.white) }
            }
            .padding(.top, 34)
            if !book.author.isEmpty {
                Text(book.author).ui(Cards.plex(32)).foregroundColor(.white.opacity(0.75)).padding(.top, 16)
            }
            if book.rating > 0 {
                let n = Int(book.rating.rounded())
                Text(String(repeating: "★", count: n) + String(repeating: "☆", count: max(0, 5 - n)))
                    .font(.system(size: 44)).foregroundColor(Color(hex: "#ffd36b")).padding(.top, 12)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer(minLength: 20)
            VStack(spacing: 20) {
                ForEach(0..<2) { row in
                    HStack(spacing: 20) {
                        ForEach(0..<3) { col in
                            let c = cells[row * 3 + col]
                            VStack(spacing: 4) {
                                Text(c.0).ui(Cards.reem(46)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.5)
                                Text(c.1).ui(Cards.plex(26)).foregroundColor(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.6)
                            }
                            .frame(width: 280, height: 130)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.08)))
                        }
                    }
                }
            }
            Text("جَليس").ui(Cards.reem(34, .bold)).foregroundColor(.white.opacity(0.85)).padding(.top, 44).padding(.bottom, 34)
        }
        .frame(width: Cards.W, height: Cards.H)
        .background(LinearGradient(colors: [Cards.color(h, s, min(40, l + 6)), Cards.color(h, s * 0.6, 8)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - بطاقة الاقتباس

private struct QuoteCardArt: View {
    let book: Book
    let quote: NoteItem
    var body: some View {
        let (h, s, l) = Cards.hsl(book)
        let sp = Cards.speaker(book, quote)
        let foot = [sp.isEmpty ? "" : "— " + sp, book.title + (book.author.isEmpty ? "" : " · " + book.author)].filter { !$0.isEmpty }
        ZStack {
            LinearGradient(colors: [Cards.color(h, s, min(34, l + 4)), Cards.color(h, s * 0.5, 9)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let id = quote.img, let photo = Library.shared.image(id) { withPhoto(photo, foot) } else { textOnly(foot) }
        }
        .frame(width: Cards.W, height: Cards.H)
    }

    private func textOnly(_ foot: [String]) -> some View {
        let text = "«" + quote.raw.str("text") + "»"
        var size: CGFloat = 64
        var lines = Cards.wrap(text, Cards.amiri(size), 880)
        while size > 34 && !(CGFloat(lines.count) * size * 1.75 < 820) {
            size -= 4
            lines = Cards.wrap(text, Cards.amiri(size), 880)
        }
        let lh = size * 1.75
        return ZStack {
            VStack(spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).ui(Cards.amiri(size)).foregroundColor(.white).frame(height: lh)
                }
            }
            .position(x: Cards.W / 2, y: Cards.H / 2)
            footer(foot, top: Cards.H - 210)
        }
    }

    private func withPhoto(_ photo: UIImage, _ foot: [String]) -> some View {
        let text = quote.raw.str("text")
        let cap = text.isEmpty ? [] : Array(Cards.wrap(text, Cards.amiri(40), 860).prefix(4))
        let capH: CGFloat = cap.isEmpty ? 0 : CGFloat(cap.count) * 64 + 30
        let boxW: CGFloat = 900, boxH = Cards.H - 150 - 260 - capH
        let sc = min(boxW / max(1, photo.size.width), boxH / max(1, photo.size.height), 3)
        let pw = photo.size.width * sc, ph = photo.size.height * sc
        let py = 130 + (boxH - ph) / 2
        return ZStack(alignment: .topLeading) {
            Image(uiImage: photo).resizable().frame(width: pw, height: ph)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white).shadow(color: .black.opacity(0.45), radius: 20, y: 14))
                .position(x: Cards.W / 2, y: py + ph / 2)
            VStack(spacing: 0) {
                ForEach(cap.indices, id: \.self) { i in Text(cap[i]).ui(Cards.amiri(40)).foregroundColor(.white).frame(height: 64) }
            }
            .frame(width: Cards.W)
            .position(x: Cards.W / 2, y: py + ph + 40 + CGFloat(cap.count) * 32)
            footer(foot, top: Cards.H - 190)
        }
        .frame(width: Cards.W, height: Cards.H)
    }

    /// "— speaker", "title · author", then جَليس at the bottom.
    private func footer(_ lines: [String], top: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).ui(Cards.plex(34, medium: true)).foregroundColor(.white.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.6).frame(width: 960, height: 56)
                }
            }
            .position(x: Cards.W / 2, y: top - 28 + CGFloat(lines.count) * 28)
            Text("جَليس").ui(Cards.reem(34, .bold)).foregroundColor(.white.opacity(0.7)).position(x: Cards.W / 2, y: Cards.H - 72)
        }
        .frame(width: Cards.W, height: Cards.H)
    }
}
