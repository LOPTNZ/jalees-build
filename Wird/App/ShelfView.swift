import SwiftUI
import UIKit

// The wooden shelf (inventory-1, sections 1.6, 2.7, 5.6): books standing (spine), facing out (cover) or lying in piles.

/// Sizes in centimetres, drawn at 8.2 points a centimetre, like the web app.
enum ShelfSize {
    static let K: CGFloat = 8.2

    static func autoThick(_ b: Book) -> Double {
        if b.unit == .page { return min(7.5, max(1.6, b.sumTotal * 0.0062 + 0.7)) }
        return min(7.5, max(1.8, 2.6 + Double(b.series ? b.volumes.count : 0) * 0.45))
    }

    static func defH(_ b: Book) -> Double {
        guard b.unit == .page else { return 21 }
        return ((21 + min(2.6, max(-1.6, (b.sumTotal - 300) / 220))) * 10).rounded() / 10
    }

    /// height, width, thickness
    static func dims(_ b: Book) -> (h: Double, w: Double, t: Double) {
        let d = b.dims ?? [:]
        let h = d.optNum("h") ?? defH(b)
        let w = d.optNum("w") ?? (b.coverRatio.map { $0 * h } ?? 0.66 * h)
        let t = d.optNum("t") ?? (b.spineRatio.map { $0 * h } ?? autoThick(b))
        return (h, w, t)
    }

    static func width(_ b: Book, _ pose: String) -> CGFloat {
        let d = dims(b)
        switch pose {
        case "face": return CGFloat(d.w) * K
        case "flat": return CGFloat(d.h) * K
        default: return max(18, CGFloat(d.t) * K)
        }
    }
}

/// One place on the shelf.
struct ShelfItem: Hashable {
    var id: String
    var pose: String
    var gap: Double

    init(_ o: JSONObject) { id = o.str("id"); pose = o.str("pose", "spine"); gap = o.num("gap") }
    var json: JSONObject {
        var o: JSONObject = ["id": .string(id), "pose": .string(pose)]
        if gap > 0 { o.set("gap", gap) }
        return o
    }
}

@MainActor
enum ShelfStore {
    static func rows() -> [[ShelfItem]] {
        (Library.shared.state.shelf?["rows"]?.array ?? []).map { r in (r.array ?? []).compactMap { $0.object.map(ShelfItem.init) } }
    }

    static func save(_ rows: [[ShelfItem]]) {
        Library.shared.change { $0.shelf = ["rows": .array(rows.map { .array($0.map { .object($0.json) }) })] }
    }

    /// Books missing from the shelf join the last rows (wrapping at the shelf's width); books gone leave it (ensureShelf).
    static func ensure(width: CGFloat) {
        let st = Library.shared.state
        let old = rows()
        var seen = Set<String>()
        var rows = old.map { r in r.filter { st.book($0.id) != nil && seen.insert($0.id).inserted } }.filter { !$0.isEmpty }
        let missing = st.books.filter { !seen.contains($0.id) }.sorted { $0.added < $1.added }
        if rows.isEmpty { rows = [[]] }
        let avail = min(width, 812) - 64
        func used(_ r: [ShelfItem]) -> CGFloat { r.reduce(0) { a, it in a + (st.book(it.id).map { ShelfSize.width($0, it.pose) } ?? 0) + CGFloat(it.gap) * ShelfSize.K + 2 } }
        for b in missing {
            let w = ShelfSize.width(b, "spine")
            if used(rows[rows.count - 1]) + w > avail && !rows[rows.count - 1].isEmpty { rows.append([]) }
            rows[rows.count - 1].append(ShelfItem(["id": .string(b.id), "pose": .string("spine")]))
        }
        if rows != old { save(rows) }
    }
}

struct ShelfView: View {
    let books: [Book]
    let ns: Namespace.ID
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(Words.cnt(Double(books.count), Words.books)).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
                        Spacer()
                        Button("تعديل الرف") { Flows.shelfStyle() }.font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.primary))
                    }
                    ShelfBoard(books: books, ns: ns, width: g.size.width - 32)
                }
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
            .onAppear { ShelfStore.ensure(width: g.size.width) }
            .onChange(of: lib.state.books.count) { _ in ShelfStore.ensure(width: g.size.width) }
        }
    }
}

/// The wood with its rows of books.
struct ShelfBoard: View {
    let books: [Book]
    let ns: Namespace.ID
    let width: CGFloat
    @ObservedObject private var lib = Library.shared

    private var theme: (wall: [Color], top: Color, front: [Color], gold: Color?) {
        if lib.state.settings.shelfTheme == "library" {
            return ([Color(hex: "#1f3a33"), Color(hex: "#152923")], Color(hex: "#8a4630"), [Color(hex: "#62301e"), Color(hex: "#3d1c10")], Color(hex: "#c9a24a"))
        }
        return ([Color(hex: "#2e2119"), Color(hex: "#211812")], Color(hex: "#9a6a43"), [Color(hex: "#6f482b"), Color(hex: "#452b19")], nil)
    }

    var body: some View {
        let visible = Set(books.map(\.id))
        let rows = ShelfStore.rows().map { $0.filter { visible.contains($0.id) } }.filter { !$0.isEmpty }
        let lights = lib.state.settings.lights
        VStack(spacing: 0) {
            if lights {
                LinearGradient(colors: [Color(hex: "#ffe2a8"), Color(hex: "#ffc46e").opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 14)
            }
            if rows.isEmpty {
                Text("ما فيه كتب تطابق التصفية").font(JFont.body(14)).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity).padding(30)
            }
            ForEach(rows.indices, id: \.self) { r in
                row(rows[r], lights: lights)
            }
        }
        .padding(.top, 10)
        .background(LinearGradient(colors: theme.wall, startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func row(_ items: [ShelfItem], lights: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(groups(items), id: \.self) { g in
                    if g.count > 1 || g.first?.pose == "flat" {
                        pile(g)
                    } else if let it = g.first, let b = lib.state.book(it.id) {
                        standing(b, it)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 14)
            .background(alignment: .bottom) {
                if lights { RadialGradient(colors: [Color(hex: "#ffc46e").opacity(0.36), .clear], center: .top, startRadius: 0, endRadius: 140).frame(height: 160) }
            }
            ZStack(alignment: .top) {
                LinearGradient(colors: theme.front, startPoint: .top, endPoint: .bottom)
                theme.top.frame(height: 3)
                if let gold = theme.gold { gold.frame(height: 1).padding(.top, 5) }
            }
            .frame(height: 15)
            .shadow(color: .black.opacity(0.6), radius: 7, y: 10)
        }
    }

    /// Consecutive flat books form one pile.
    private func groups(_ items: [ShelfItem]) -> [[ShelfItem]] {
        var out: [[ShelfItem]] = []
        for it in items {
            if it.pose == "flat", let last = out.last, last.first?.pose == "flat", it.gap == 0 { out[out.count - 1].append(it) } else { out.append([it]) }
        }
        return out
    }

    private func standing(_ b: Book, _ it: ShelfItem) -> some View {
        let d = ShelfSize.dims(b)
        return Button { OpenBook.open(b) } label: {
            Group {
                if it.pose == "face" {
                    BookCover(book: b, radius: 3, marks: false).frame(width: CGFloat(d.w) * ShelfSize.K, height: CGFloat(d.h) * ShelfSize.K)
                } else {
                    Spine(book: b, width: ShelfSize.width(b, "spine"), height: CGFloat(d.h) * ShelfSize.K)
                }
            }
            .overlay(alignment: .top) { badge(b) }
            .zoomSource(b.id, ns)
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(it.gap) * ShelfSize.K)
        .accessibilityLabel(b.title)
    }

    private func pile(_ g: [ShelfItem]) -> some View {
        VStack(spacing: 1) {
            ForEach(g, id: \.self) { it in
                if let b = lib.state.book(it.id) {
                    let d = ShelfSize.dims(b)
                    Button { OpenBook.open(b) } label: {
                        FlatSpine(book: b, width: CGFloat(d.h) * ShelfSize.K, height: max(12, CGFloat(d.t) * ShelfSize.K))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(b.title)
                }
            }
        }
        .padding(.leading, CGFloat(g.first?.gap ?? 0) * ShelfSize.K)
    }

    @ViewBuilder private func badge(_ b: Book) -> some View {
        if lib.state.settings.show.bool("shelfBadge"), b.format == .audio || b.format == .ebook {
            Image(systemName: b.format == .audio ? "headphones" : "ipad").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(Color.black.opacity(0.6))).padding(.top, 4)
        }
    }
}

/// A book standing: its spine picture, or one drawn in its colour with its title (and author when there is room).
struct Spine: View {
    let book: Book
    let width: CGFloat
    let height: CGFloat
    @ObservedObject private var lib = Library.shared

    var body: some View {
        let c = UIColor.hslParts(book.hslString) ?? .darkGray
        ZStack {
            if let img = lib.image(book.spine) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(c).opacity(0.8), Color(c), Color(c).opacity(0.75)], startPoint: .leading, endPoint: .trailing)
                VStack(spacing: 0) {
                    rule
                    Spacer(minLength: 0)
                    rule
                }
                .padding(.vertical, 10)
                HStack(spacing: 6) {
                    Text(book.title).font(JFont.display(min(14, max(9.5, width * 0.42)), .semibold)).lineLimit(1)
                    if height > 160, !book.author.isEmpty { Text(book.author).font(JFont.body(min(10, max(7.5, width * 0.3)))).opacity(0.8).lineLimit(1) }
                }
                .foregroundStyle(.white)
                .fixedSize()
                .frame(width: height - 34)
                .rotationEffect(.degrees(lib.state.settings.spineUp ? -90 : 90))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 1, x: -1)
    }

    private var rule: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Color(red: 232 / 255, green: 200 / 255, blue: 120 / 255).opacity(0.75)).frame(height: 1)
            Rectangle().fill(Color(red: 232 / 255, green: 200 / 255, blue: 120 / 255).opacity(0.75)).frame(height: 1)
        }
    }
}

/// A book lying flat in a pile.
struct FlatSpine: View {
    let book: Book
    let width: CGFloat
    let height: CGFloat
    @ObservedObject private var lib = Library.shared

    var body: some View {
        let c = UIColor.hslParts(book.hslString) ?? .darkGray
        ZStack {
            if let img = lib.image(book.spine) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: height, height: width).rotationEffect(.degrees(90))
            } else {
                LinearGradient(colors: [Color(c).opacity(0.8), Color(c)], startPoint: .top, endPoint: .bottom)
                Text(book.title).font(JFont.display(min(12, max(8, height * 0.55)), .semibold)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}
