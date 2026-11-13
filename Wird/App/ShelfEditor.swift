import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Editing the shelf (inventory-1, sections 2.7, 3.4, 5.6): a copy of the rows to change, then save or cancel.
/// Tap a book for its pose and row; hold and drag it between books, into an empty spot (it stays there), or to a new row.
@MainActor
final class ShelfEditor: ObservableObject {
    static let shared = ShelfEditor()
    @Published private(set) var editing = false
    @Published var draft: [[ShelfItem]] = []
    /// where a dragged book would land: row, and index (or a free spot in centimetres from the row's start)
    @Published var hint: (row: Int, index: Int?, gap: Double?)?
    @Published var picked: String?
    /// the books being dragged now (one, or a pile), known from the start of the drag
    var dragIDs: [String] = []

    var hasGaps: Bool { draft.contains { $0.contains { $0.gap > 0 } } }

    func begin(width: CGFloat) {
        ShelfStore.ensure(width: width)
        draft = ShelfStore.rows()
        editing = true
    }

    func cancel() { editing = false; draft = []; hint = nil }

    func save() {
        var rows = draft.filter { !$0.isEmpty }
        if rows.isEmpty { rows = [[]] }
        ShelfStore.save(rows)
        cancel()
        ToastCenter.shared.show("تم حفظ ترتيب الرف")
    }

    func pack() { draft = draft.map { $0.map { var x = $0; x.gap = 0; return x } } }
    func addRow() { draft.append([]) }

    func find(_ id: String) -> (r: Int, i: Int)? {
        for (r, row) in draft.enumerated() { if let i = row.firstIndex(where: { $0.id == id }) { return (r, i) } }
        return nil
    }

    func setPose(_ id: String, _ pose: String) {
        guard let l = find(id) else { return }
        draft[l.r][l.i].pose = pose
    }

    func moveRow(_ id: String, by d: Int) {
        guard let l = find(id) else { return }
        var it = draft[l.r].remove(at: l.i)
        it.gap = 0
        let r = l.r + d
        if r >= draft.count { draft.append([]) }
        draft[max(0, r)].append(it)
    }

    /// Moves books (one, or a whole pile) to a row: before the book at `index`, or at a free spot `gap` cm after the last.
    func move(_ ids: [String], toRow r: Int, index: Int?, gap: Double?) {
        var items: [ShelfItem] = []
        var rows = draft
        var target = r
        var at = index
        for id in ids {
            for (ri, row) in rows.enumerated() {
                if let i = row.firstIndex(where: { $0.id == id }) {
                    if ri == target, let a = at, i < a { at = a - 1 }
                    var x = rows[ri].remove(at: i)
                    x.gap = 0
                    items.append(x)
                    break
                }
            }
        }
        guard !items.isEmpty else { return }
        if target >= rows.count { rows.append([]); target = rows.count - 1 }
        if let g = gap { items[0].gap = g }
        if let a = at { rows[target].insert(contentsOf: items, at: min(max(0, a), rows[target].count)) } else { rows[target].append(contentsOf: items) }
        draft = rows
        Haptics.play("sel")
    }

    // MARK: free placement (02-library.js places, regap, freeDrop)

    struct Slot { var off: Double; var w: Double; var items: [ShelfItem] }

    /// Where each slot of a row sits now, in centimetres from the row's start (its right side); a pile is one slot.
    static func slots(_ row: [ShelfItem]) -> [Slot] {
        let st = Library.shared.state, K = Double(ShelfSize.K)
        var out: [Slot] = []
        for it in row {
            let w = st.book(it.id).map { Double(ShelfSize.width($0, it.pose)) / K } ?? 0
            if it.pose == "flat", it.gap == 0, var last = out.last, last.items.first?.pose == "flat" {
                last.items.append(it)
                last.w = max(last.w, w)
                out[out.count - 1] = last
            } else {
                let start = (out.last.map { $0.off + $0.w + 2 / K } ?? 0) + it.gap
                out.append(Slot(off: start, w: w, items: [it]))
            }
        }
        return out
    }

    /// Gaps from wanted positions, in reading order; books never overlap (2 points apart); gaps under 0.25 cm close.
    static func regap(_ pl: [Slot]) -> [ShelfItem] {
        let K = Double(ShelfSize.K)
        var end = 0.0
        var out: [ShelfItem] = []
        for p in pl.sorted(by: { $0.off < $1.off }) {
            var g = max(0, p.off - end)
            if g < 0.25 { g = 0 }
            g = (g * 10).rounded() / 10
            for (k, var it) in p.items.enumerated() { it.gap = k == 0 ? g : 0; out.append(it) }
            end = end + g + p.w + 2 / K
        }
        return out
    }

    /// Drops books into empty space on a row: they stay where dropped, and every other book keeps its place.
    func freeDrop(_ ids: [String], toRow r: Int, at: Double) {
        var rows = draft
        let moving = ids.compactMap { id in rows.joined().first { $0.id == id } }
        guard !moving.isEmpty else { return }
        let set = Set(ids)
        let src = find(ids[0])?.r
        func keep(_ row: [ShelfItem]) -> [Slot] {
            Self.slots(row).compactMap { s in
                var x = s
                x.items = s.items.filter { !set.contains($0.id) }
                return x.items.isEmpty ? nil : x
            }
        }
        let w = Self.slots(moving.map { var x = $0; x.gap = 0; return x }).map(\.w).max() ?? 0
        if r >= rows.count { rows.append([]) }
        if let s = src, s != r { rows[s] = Self.regap(keep(rows[s])) }
        var dest = keep(rows[r])
        dest.append(Slot(off: max(0, at), w: w, items: moving))
        rows[r] = Self.regap(dest)
        draft = rows
        Haptics.play("sel")
    }
}

/// Drops on a row: the place comes from where the finger is, measured from the row's start (its right side).
struct ShelfRowDrop: DropDelegate {
    let row: Int
    let width: CGFloat
    @ObservedObject var editor: ShelfEditor

    /// Over a book (or pile): before or after it, by its middle. Over empty space: a free spot, in centimetres from
    /// the row's start, for the dragged books' middle to sit under the finger.
    private func place(_ x: CGFloat) -> (index: Int?, gap: Double?) {
        let items = editor.draft.indices.contains(row) ? editor.draft[row] : []
        let K = Double(ShelfSize.K)
        let fromStart = Double(width - x - 12) / K
        let moving = Set(editor.dragIDs)
        for s in ShelfEditor.slots(items) {
            let left = s.items.filter { !moving.contains($0.id) }
            guard !left.isEmpty else { continue }
            if fromStart >= s.off - 1 / K && fromStart <= s.off + s.w {
                let first = items.firstIndex { $0.id == left.first!.id } ?? 0
                let last = items.firstIndex { $0.id == left.last!.id } ?? first
                return fromStart < s.off + s.w / 2 ? (first, nil) : (last + 1, nil)
            }
        }
        let dragged = editor.draft.joined().filter { moving.contains($0.id) }.map { var x = $0; x.gap = 0; return x }
        let w = ShelfEditor.slots(dragged).map(\.w).max() ?? 0
        return (nil, max(0, fromStart - w / 2))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let p = place(info.location.x)
        editor.hint = (row, p.index, p.gap)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { editor.hint = nil }

    func performDrop(info: DropInfo) -> Bool {
        let p = place(info.location.x)
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String else { return }
            let ids = s.split(separator: ",").map(String.init)
            Task { @MainActor in
                editor.hint = nil
                editor.dragIDs = []
                if let i = p.index { editor.move(ids, toRow: row, index: i, gap: nil) } else { editor.freeDrop(ids, toRow: row, at: p.gap ?? 0) }
            }
        }
        return true
    }
}

/// The bar over the shelf while editing.
struct ShelfEditBar: View {
    @ObservedObject var editor = ShelfEditor.shared
    @Environment(\.look) private var L
    @State private var style = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { editor.cancel() } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }
                    .buttonStyle(.plain).foregroundStyle(Color(L.ink)).background(Circle().fill(Color(L.surface2))).accessibilityLabel("إلغاء التعديل")
                Spacer()
                Text("تعديل الرف").font(JFont.display(19, .semibold)).foregroundStyle(Color(L.ink))
                Spacer()
                Button { editor.save() } label: { Image(systemName: "checkmark").frame(width: 36, height: 36) }
                    .buttonStyle(.plain).foregroundStyle(Color(L.onPrimary)).background(Circle().fill(Color(L.primary))).accessibilityLabel("حفظ الرف")
            }
            Text("اضغط على كتاب لتعديله · اسحبه بين الكتب لترتيبها، أو لأي مكان فاضي على الرف ويبقى فيه").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
            HStack(spacing: 8) {
                if editor.hasGaps { Button("رصّ") { editor.pack() }.buttonStyle(JButtonStyle(look: L, small: true)) }
                Button { style = true } label: { Label("الشكل", systemImage: "paintpalette") }.buttonStyle(JButtonStyle(look: L, small: true))
            }
        }
        .sheet(isPresented: $style) { ShelfStyleSheet().presentationDetents([.medium, .large]).environment(\.look, L).environment(\.layoutDirection, .rightToLeft) }
    }
}

/// A book on the shelf while editing: its pose, its row, its details.
struct ShelfItemSheet: View {
    let bookID: String
    @ObservedObject var editor = ShelfEditor.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let l = editor.find(bookID)
        let pose = l.map { editor.draft[$0.r][$0.i].pose } ?? "spine"
        JSheet(title: Library.shared.state.book(bookID)?.title ?? "") {
            VStack(spacing: 0) {
                JMenuRow(icon: "rectangle.portrait", title: "وقوف عمودي (الكعب)", checked: pose == "spine") { editor.setPose(bookID, "spine"); dismiss() }
                JMenuRow(icon: "book.closed", title: "الغلاف للأمام", checked: pose == "face") { editor.setPose(bookID, "face"); dismiss() }
                JMenuRow(icon: "square.stack", title: "تكديس أفقي", checked: pose == "flat") { editor.setPose(bookID, "flat"); dismiss() }
                if let l = l, l.r > 0 { JMenuRow(icon: "arrow.up", title: "انقله للصف السابق") { editor.moveRow(bookID, by: -1); dismiss() } }
                JMenuRow(icon: "arrow.down", title: "انقله للصف التالي") { editor.moveRow(bookID, by: 1); dismiss() }
                JMenuRow(icon: "pencil", title: "تعديل الكتاب", sub: "الصور والأبعاد والتفاصيل") { dismiss(); Flows.editBook(bookID) }
            }
        }
    }
}

/// «شكل الرف»: the wood, the lights, the badges, which way spine titles read.
struct ShelfStyleSheet: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L

    var body: some View {
        let s = lib.state.settings
        JSheet(title: "شكل الرف", action: ("تم", { dismiss() })) {
            HStack(spacing: 12) {
                theme("walnut", "خشب داكن", [Color(hex: "#2e2119"), Color(hex: "#211812")], Color(hex: "#6f482b"), s.shelfTheme)
                theme("library", "مكتبة كلاسيكية", [Color(hex: "#1f3a33"), Color(hex: "#152923")], Color(hex: "#62301e"), s.shelfTheme)
            }
            JLabel(text: "إضافات")
            JSwitchRow(title: "إضاءة LED تحت الرفوف", on: Binding(get: { s.lights }, set: { v in lib.change { $0.settings.lights = v } }))
            JSwitchRow(title: "شارة الصوتي والإلكتروني على الكعب", on: Binding(get: { s.show.bool("shelfBadge") }, set: { LibraryFilters.set("show.shelfBadge", .bool($0)) }))
            JSwitchRow(title: "عنوان الكعب من أسفل لأعلى", on: Binding(get: { s.spineUp }, set: { v in lib.change { $0.settings.spineUp = v } }))
        }
    }

    private func theme(_ id: String, _ name: String, _ wall: [Color], _ plank: Color, _ cur: String) -> some View {
        Button { lib.change { $0.settings.shelfTheme = id } } label: {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach([("#7a3b2e", 52), ("#2f5c53", 60), ("#c9a24a", 46), ("#3c4785", 56), ("#7a2e5c", 50)], id: \.0) { c in
                            Rectangle().fill(Color(hex: c.0)).frame(width: 12, height: CGFloat(c.1))
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 10)
                    plank.frame(height: 8)
                }
                .background(LinearGradient(colors: wall, startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(name).font(JFont.body(14, cur == id ? .semibold : .regular)).foregroundStyle(Color(L.ink))
            }
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(cur == id ? L.primary : L.line), lineWidth: cur == id ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}
