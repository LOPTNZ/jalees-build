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
            .sheet(item: $edit) { r in ItemForm(ref: r).environment(\.look, L).environment(\.layoutDirection, Lang.direction) }
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
