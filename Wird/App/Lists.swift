import SwiftUI

// «القوائم» (answers-round2 س61): your own lists, each with an emoji, and a book or novel in as many as you like.
// They are the library's collections (Book.cols), so the library's «عرض» menu and filters show them too; the emoji of
// each list is kept in the settings (colEmoji), so a backup carries them.

extension AppState {
    func colEmoji(_ c: String) -> String { settings.raw.obj("colEmoji").str(c) }
    /// "📚 مكتبة البيت", or the name alone when the list has no emoji
    func colLabel(_ c: String) -> String {
        let e = colEmoji(c)
        return e.isEmpty ? c : e + " " + c
    }
}

@MainActor
enum Lists {
    static let emojis = ["⭐️", "❤️", "🔥", "📚", "⏳", "🌙", "🏆", "🧠", "😂", "😢", "⚔️", "🐉", "🕵️", "💞", "👑", "🌱"]

    static func setEmoji(_ c: String, _ e: String) {
        Library.shared.change { st in
            var s = st.settings.raw
            var o = s.obj("colEmoji")
            o[c] = e.isEmpty ? nil : .string(e)
            s["colEmoji"] = .object(o)
            st.settings = Settings(s)
        }
    }

    static func toggle(_ book: String, _ c: String) {
        Library.shared.changeBook(book) { b in
            if b.cols.contains(c) { b.cols.removeAll { $0 == c } } else { b.cols.append(c) }
        }
        Haptics.play("sel")
    }

    /// Deletes a list: it leaves every book (the books stay).
    static func remove(_ c: String) {
        Library.shared.change { st in
            for i in st.books.indices where st.books[i].cols.contains(c) { st.books[i].cols.removeAll { $0 == c } }
            var s = st.settings.raw
            var o = s.obj("colEmoji")
            o[c] = nil
            s["colEmoji"] = .object(o)
            st.settings = Settings(s)
        }
    }
}

/// The lists a book or novel is in, as chips with a button to change them (the novel page and the book page).
struct ListsRow: View {
    let bookID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var open = false

    var body: some View {
        let cols = lib.state.book(bookID)?.cols ?? []
        Flow(spacing: 8) {
            ForEach(cols, id: \.self) { c in
                Text(lib.state.colLabel(c)).font(JFont.body(13.5))
                    .foregroundStyle(Color(L.accentInk)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color(L.accentSoft)))
            }
            Button { open = true } label: {
                Label(cols.isEmpty ? "أضف لقائمة" : "القوائم", systemImage: cols.isEmpty ? "plus" : "square.stack")
                    .font(JFont.body(13.5, .medium))
                    .foregroundStyle(Color(L.ink)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().strokeBorder(Color(L.line), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $open) {
            ListsSheet(bookID: bookID).environment(\.look, L).environment(\.layoutDirection, Lang.direction)
                .presentationDetents([.medium, .large])
        }
    }
}

struct ListsSheet: View {
    let bookID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var name = ""
    @State private var emoji = "⭐️"
    @State private var editing: String?

    var body: some View {
        let st = lib.state
        let mine = st.book(bookID)?.cols ?? []
        let all = Array(Set(st.allCols.keys).union(mine)).sorted()
        JSheet(title: "القوائم") {
            if all.isEmpty {
                Text("ما عندك قوائم بعد. سوّ وحدة، مثل «⭐️ المفضّلة» أو «⏳ أكملها بعدين».").font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            } else {
                VStack(spacing: 0) {
                    ForEach(all, id: \.self) { c in
                        HStack(spacing: 10) {
                            Button { editing = c } label: {
                                Text(st.colEmoji(c).isEmpty ? "＋" : st.colEmoji(c)).font(.system(size: 22)).frame(width: 40, height: 40)
                                    .background(Circle().fill(Color(L.surface2)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("غيّر إيموجي القائمة")
                            Button { Lists.toggle(bookID, c) } label: {
                                HStack {
                                    Text(c).font(JFont.body(15.5)).foregroundStyle(Color(L.ink))
                                    Text("\(st.allCols[c] ?? 0)").font(JFont.body(13)).foregroundStyle(Color(L.ink2)).monospacedDigit()
                                    Spacer()
                                    Image(systemName: mine.contains(c) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20)).foregroundStyle(mine.contains(c) ? Color(L.primary) : Color(L.ink2))
                                }
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(st.colLabel(c))
                            .accessibilityAddTraits(mine.contains(c) ? [.isSelected] : [])
                        }
                        .contextMenu {
                            Button("احذف القائمة", role: .destructive) { Lists.remove(c) }
                        }
                    }
                }
                Text("اضغط الإيموجي لتغييره، واضغط مطوّلًا على قائمة لحذفها.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
            }

            JLabel(text: "قائمة جديدة")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Lists.emojis, id: \.self) { e in
                        Button { emoji = e } label: {
                            Text(e).font(.system(size: 22)).frame(width: 40, height: 40)
                                .background(Circle().fill(emoji == e ? Color(L.accentSoft) : Color(L.surface2)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                Text(emoji).font(.system(size: 22))
                TextField("اسم القائمة", text: $name).font(JFont.body(15)).padding(.horizontal, 12).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                    .onSubmit { add() }
                Button("أضف") { add() }.buttonStyle(JButtonStyle(look: L, small: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog("إيموجي القائمة", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), titleVisibility: .visible) {
            ForEach(Lists.emojis, id: \.self) { e in Button(e) { if let c = editing { Lists.setEmoji(c, e) }; editing = nil } }
            Button("بدون إيموجي") { if let c = editing { Lists.setEmoji(c, "") }; editing = nil }
            Button("إلغاء", role: .cancel) { editing = nil }
        }
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        Lists.setEmoji(n, emoji)
        if !(lib.state.book(bookID)?.cols.contains(n) ?? true) { Lists.toggle(bookID, n) }
        name = ""
    }
}
