import SwiftUI
import UIKit

// MARK: - the reader's menu, arranged by its reader (reader 2.4, docs/plan/reader-menu-2.4.md)

/// Every action the reader's menu (≡) can hold. Each one sits in the menu's rows, among its round buttons, in
/// «المزيد», or is hidden; the owner arranges them in «خصّص القائمة». Saved by its raw value: a name never changes.
enum ReaderMenuItem: String, CaseIterable, Identifiable, Hashable {
    case contents, notebook, aloud, rules, themes, chapters
    case search, theme, brightness, fontSize, pageStyle
    case bookmark, guide, autoScroll, lock
    case site, mirror, refetch, share, comments
    case reading, customize

    var id: String { rawValue }

    /// An action closes the menu and does its thing. A switch shows whether it is on. An adjustment (the theme, the
    /// brightness, the font size, how pages move) changes the page behind the menu, and the menu stays open.
    enum Kind { case action, toggle, adjust }

    var kind: Kind {
        switch self {
        case .bookmark, .guide, .autoScroll, .lock: return .toggle
        case .theme, .brightness, .fontSize, .pageStyle: return .adjust
        default: return .action
        }
    }

    /// what it is about: «المزيد» draws a line where one kind ends and the next begins
    enum Group { case reading, look, tools, chapter, settings }

    var group: Group {
        switch self {
        case .contents, .notebook, .aloud, .rules, .themes, .chapters, .search: return .reading
        case .theme, .brightness, .fontSize, .pageStyle: return .look
        case .bookmark, .guide, .autoScroll, .lock: return .tools
        case .site, .mirror, .refetch, .share, .comments: return .chapter
        case .reading, .customize: return .settings
        }
    }

    /// its words in the menu (an EPUB says «الكتاب» where a web novel says «الرواية»)
    func title(epub: Bool) -> String {
        switch self {
        case .contents: return "المحتويات"
        case .notebook: return epub ? "دفتر الكتاب" : "دفتر الرواية"
        case .aloud: return "القراءة الصوتية"
        case .rules: return "قواعد الاستبدال"
        case .themes: return "السمات والإعدادات"
        case .chapters: return "الفصل السابق والتالي"
        case .search: return epub ? "بحث في الكتاب" : "بحث في الرواية"
        case .theme: return "السمة"
        case .brightness: return "السطوع"
        case .fontSize: return "حجم الخط"
        case .pageStyle: return "طريقة القراءة"
        case .bookmark: return "وقفة"
        case .guide: return "دليل السطر"
        case .autoScroll: return "تمرير تلقائي"
        case .lock: return "قفل الاتجاه الرأسي"
        case .site: return "افتح الفصل في الموقع"
        case .mirror: return "الفصل من مصدر ثاني"
        case .refetch: return "حمّل الفصل من جديد"
        case .share: return "مشاركة رابط الفصل"
        case .comments: return "تعليقات الفصل"
        case .reading: return "إعدادات القراءة"
        case .customize: return "تخصيص السمة"
        }
    }

    var symbol: String {
        switch self {
        case .contents: return "list.bullet"
        case .notebook: return "book.closed"
        case .aloud: return "speaker.wave.2"
        case .rules: return "character.cursor.ibeam"
        case .themes: return "textformat.size"
        case .chapters: return "arrow.left.arrow.right"
        case .search: return "magnifyingglass"
        case .theme: return "circle.lefthalf.filled"
        case .brightness: return "sun.max"
        case .fontSize: return "textformat.size.larger"
        case .pageStyle: return "book.pages"
        case .bookmark: return "bookmark"
        case .guide: return "text.line.first.and.arrowtriangle.forward"
        case .autoScroll: return "play.circle"
        case .lock: return "lock.rotation"
        case .site: return "safari"
        case .mirror: return "arrow.triangle.2.circlepath"
        case .refetch: return "arrow.clockwise"
        case .share: return "square.and.arrow.up"
        case .comments: return "bubble.left.and.bubble.right"
        case .reading: return "gearshape"
        case .customize: return "paintbrush"
        }
    }

    /// round buttons it takes: a pair (previous and next, smaller and larger) takes two
    var width: Int { self == .fontSize || self == .chapters ? 2 : 1 }

    /// said under it in the editor: how it works, or in which books it shows
    var hint: String? {
        switch self {
        case .chapters: return "اضغط الرقم وتنتقل لأي فصل"
        case .theme: return "السمات كلها بضغطة، بدون ما تفتح الإعدادات"
        case .fontSize: return "القائمة تبقى مفتوحة وأنت تكبّر وتصغّر"
        case .site, .refetch, .share: return "في روايات المواقع"
        case .mirror: return "لما يكون للرواية مصدر ثاني"
        case .comments: return "في ملوك الروايات، والتعليقات مشغّلة"
        case .lock: return "تلقاه أيضًا في إعدادات القراءة"
        default: return nil
        }
    }
}

/// Where an item sits in the menu.
enum MenuSpot: String, CaseIterable {
    case rows, buttons, more, hidden

    var title: String {
        switch self {
        case .rows: return "الصفوف"
        case .buttons: return "الأزرار الدائرية"
        case .more: return "المزيد"
        case .hidden: return "مخفية"
        }
    }

    var moveTitle: String {
        switch self {
        case .rows: return "إلى الصفوف"
        case .buttons: return "إلى الأزرار الدائرية"
        case .more: return "إلى «المزيد»"
        case .hidden: return "إخفاء"
        }
    }

    var symbol: String {
        switch self {
        case .rows: return "list.bullet"
        case .buttons: return "circle.grid.3x3"
        case .more: return "ellipsis.circle"
        case .hidden: return "eye.slash"
        }
    }
}

/// How pages move, as the menu offers it (the novels' five ways, or an EPUB's three).
struct ReaderPageStyle {
    let name: String
    let icon: String
    let on: Bool
    let pick: () -> Void
}

/// The menu as the owner arranged it. Saved in the database (kv `reader.menu`, JSON); nothing is saved while it is
/// the default, so a better default in a later version reaches whoever never changed it.
struct ReaderMenuLayout: Equatable {
    var rows: [ReaderMenuItem]
    var buttons: [ReaderMenuItem]
    var more: [ReaderMenuItem]
    var hidden: [ReaderMenuItem]
    /// Apple Books' tall chapter scrubber beside the menu. Off by default: in a novel of thousands of chapters each
    /// point of it is several chapters, and previous, next and the chapter's number do that job exactly.
    var scrubber = false

    static let key = "reader.menu"
    /// rows a phone held upright shows; the rest go to «المزيد» (and fewer show on a short screen, sideways)
    static let maxRows = 8
    /// round buttons beside «المزيد» (a pair takes two): six round buttons fill the menu's width
    static let buttonSlots = 5

    /// The study's answer (docs/plan/reader-menu-2.4.md): what a reader of long machine-translated novels uses every
    /// session is one tap away (the contents, the book's notebook, reading aloud, the replacement rules, the themes,
    /// the chapter before and after, search, a quick theme and brightness); what is rare or set once is in «المزيد».
    static let standard = ReaderMenuLayout(
        rows: [.contents, .notebook, .aloud, .rules, .themes, .chapters],
        buttons: [.search, .theme, .brightness],
        more: [.bookmark, .guide, .autoScroll, .fontSize, .pageStyle, .site, .mirror, .refetch, .share, .comments, .reading, .customize],
        hidden: [.lock])

    /// an arrangement shown without being saved (a picture route)
    static var preview: ReaderMenuLayout?

    static var current: ReaderMenuLayout { preview ?? load() }

    static func load() -> ReaderMenuLayout { parse(DB.shared.get(key)) }

    func save() { DB.shared.set(ReaderMenuLayout.key, self == .standard ? nil : json) }

    func items(_ s: MenuSpot) -> [ReaderMenuItem] {
        switch s {
        case .rows: return rows
        case .buttons: return buttons
        case .more: return more
        case .hidden: return hidden
        }
    }

    mutating func set(_ s: MenuSpot, _ list: [ReaderMenuItem]) {
        switch s {
        case .rows: rows = list
        case .buttons: buttons = list
        case .more: more = list
        case .hidden: hidden = list
        }
    }

    func spot(of i: ReaderMenuItem) -> MenuSpot? { MenuSpot.allCases.first { items($0).contains(i) } }

    /// To the end of a place (out of wherever it was).
    mutating func move(_ i: ReaderMenuItem, to s: MenuSpot) {
        for x in MenuSpot.allCases { set(x, items(x).filter { $0 != i }) }
        set(s, items(s) + [i])
    }

    /// Every item once: one listed twice keeps its first place, and one not listed at all (an item a later Jalees
    /// added) goes to «المزيد», where it can be found.
    func completed() -> ReaderMenuLayout {
        var seen = Set<ReaderMenuItem>()
        var out = ReaderMenuLayout(rows: [], buttons: [], more: [], hidden: [], scrubber: scrubber)
        for s in MenuSpot.allCases { out.set(s, items(s).filter { seen.insert($0).inserted }) }
        out.more += ReaderMenuItem.allCases.filter { !seen.contains($0) }
        return out
    }

    /// The round buttons that fit beside «المزيد», in order, and the ones that go into it.
    static func fit(_ list: [ReaderMenuItem]) -> (kept: [ReaderMenuItem], spill: [ReaderMenuItem]) {
        var used = 0
        var kept: [ReaderMenuItem] = []
        var spill: [ReaderMenuItem] = []
        for b in list {
            if used + b.width <= buttonSlots { kept.append(b); used += b.width } else { spill.append(b) }
        }
        return (kept, spill)
    }

    var json: String {
        let o: [String: Any] = ["v": 1, "rows": rows.map(\.rawValue), "buttons": buttons.map(\.rawValue), "more": more.map(\.rawValue),
                                "hidden": hidden.map(\.rawValue), "scrubber": scrubber]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    /// What was saved, read safely: a name it does not know (from a newer Jalees) is left out, and the rest is
    /// completed (every item once). Nothing saved, or something unreadable, is the default.
    static func parse(_ s: String?) -> ReaderMenuLayout {
        guard let s = s, let d = s.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .standard }
        func list(_ k: String) -> [ReaderMenuItem] {
            ((o[k] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(ReaderMenuItem.init(rawValue:)) }
        }
        return ReaderMenuLayout(rows: list("rows"), buttons: list("buttons"), more: list("more"), hidden: list("hidden"),
                                scrubber: (o["scrubber"] as? Bool) ?? false).completed()
    }
}

// MARK: - «خصّص القائمة»

/// The menu is the owner's: every item can be dragged between the rows, the round buttons and «المزيد», reordered, or
/// hidden. A picture of the menu at the top follows every change. «خصّص القائمة» itself stays last in «المزيد», so
/// the way back here is never lost.
struct MenuEditorView: View {
    var epub = false
    /// the open book reads right to left (the chapter arrows in the picture go its way, as the menu's do)
    var bookRTL = true
    var close: () -> Void
    /// pushed inside the reading settings (back to them), or a sheet of its own over the page
    var embedded = false
    @State private var layout = ReaderMenuLayout.load()
    @State private var askReset = false

    private enum Line: Hashable, Identifiable {
        case head(MenuSpot)
        case item(ReaderMenuItem)
        /// «خصّص القائمة», always last in «المزيد»
        case fixed

        var id: String {
            switch self {
            case .head(let s): return "head." + s.rawValue
            case .item(let i): return i.rawValue
            case .fixed: return "fixed"
            }
        }
    }

    /// One list with the places as headings, so an item is dragged from one place to another.
    private var lines: [Line] {
        var out: [Line] = []
        for s in MenuSpot.allCases {
            out.append(.head(s))
            out += layout.items(s).map { Line.item($0) }
            if s == .more { out.append(.fixed) }
        }
        return out
    }

    /// what the menu cannot hold (past the rows' or the buttons' room): it shows in «المزيد»
    private var overflow: Set<ReaderMenuItem> {
        var out = Set(layout.rows.dropFirst(ReaderMenuLayout.maxRows))
        out.formUnion(ReaderMenuLayout.fit(layout.buttons).spill)
        return out
    }

    var body: some View {
        MaybeStack(on: !embedded) {
            List {
                Section {
                    MenuPreview(layout: layout, epub: epub, bookRTL: bookRTL)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("اسحب العناصر بين الصفوف والأزرار الدائرية و«المزيد»، أو انقلها بالزر اللي جنبها، أو أخفِ اللي ما تحتاجه. اللي ما يتّسع على الشاشة يروح لـ«المزيد» بنفسه.")
                }
                Section {
                    ForEach(lines) { x in
                        line(x)
                            .moveDisabled(!isItem(x))
                            .listRowBackground(isHead(x) ? Color.clear : nil)
                    }
                    .onMove(perform: moved)
                }
                Section {
                    Toggle("شريط التنقل العمودي بجانب القائمة", isOn: $layout.scrubber)
                } footer: {
                    Text("شريط أبل بجانب القائمة. في رواية فيها آلاف الفصول ما يوقف على فصل واحد، فالسابق والتالي ورقم الفصل أدق.")
                }
                Section {
                    Button("رجّع الافتراضي", role: .destructive) { askReset = true }
                        .buttonStyle(.borderless)
                        .disabled(layout == .standard)
                }
            }
            // the handles show without an «تعديل» first
            .environment(\.editMode, .constant(.active))
            .navigationTitle("خصّص القائمة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم", action: close) } }
            .confirmationDialog("ترجع القائمة مثل ما كانت أول مرة؟", isPresented: $askReset, titleVisibility: .visible) {
                Button("رجّع الافتراضي", role: .destructive) { withAnimation { layout = .standard } }
                Button("إلغاء", role: .cancel) {}
            }
            // saved as it changes: the next time the menu opens, it is this
            .onChange(of: layout) { $0.save() }
        }
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, Lang.locale)
        .preferredColorScheme(.dark)
    }

    private func isItem(_ x: Line) -> Bool {
        if case .item = x { return true }
        return false
    }

    private func isHead(_ x: Line) -> Bool {
        if case .head = x { return true }
        return false
    }

    @ViewBuilder private func line(_ x: Line) -> some View {
        switch x {
        case .head(let s): header(s)
        case .item(let i): itemRow(i)
        case .fixed: fixedRow
        }
    }

    /// A drag ends: each item belongs to the heading above it (one dropped above the first heading is a row).
    private func moved(from: IndexSet, to: Int) {
        var x = lines
        x.move(fromOffsets: from, toOffset: to)
        var l = ReaderMenuLayout(rows: [], buttons: [], more: [], hidden: [], scrubber: layout.scrubber)
        var spot = MenuSpot.rows
        for line in x {
            switch line {
            case .head(let s): spot = s
            case .item(let i): l.set(spot, l.items(spot) + [i])
            case .fixed: break
            }
        }
        layout = l
    }

    private func header(_ s: MenuSpot) -> some View {
        let n = layout.items(s).count
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(s.title).font(.system(size: 13, weight: .semibold))
                if s == .rows {
                    Text("·")
                    Text("\(min(n, ReaderMenuLayout.maxRows)) من \(ReaderMenuLayout.maxRows)").monospacedDigit()
                } else if s == .buttons {
                    Text("·")
                    Text("\(min(layout.buttons.reduce(0) { $0 + $1.width }, ReaderMenuLayout.buttonSlots)) من \(ReaderMenuLayout.buttonSlots)").monospacedDigit()
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.secondary)
            if n == 0 && s != .more {
                Text("فاضي، اسحب عنصر هنا").font(.caption).foregroundStyle(Color.secondary.opacity(0.7))
            }
        }
        .padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private func itemRow(_ i: ReaderMenuItem) -> some View {
        let spot = layout.spot(of: i) ?? .more
        let title = i.title(epub: epub)
        let spills = overflow.contains(i)
        return HStack(spacing: 12) {
            Image(systemName: i.symbol).font(.system(size: 16)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if spills {
                    Text("ما يتّسع، يظهر في «المزيد»").font(.caption).foregroundStyle(Color.orange)
                } else if let h = i.hint {
                    Text(h).font(.caption).foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(MenuSpot.allCases.filter { $0 != spot }, id: \.self) { s in
                    Button { withAnimation { layout.move(i, to: s) } } label: { Label(s.moveTitle, systemImage: s.symbol) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle").font(.system(size: 20)).frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .accessibilityLabel("انقل «" + title + "»")
        }
        .foregroundStyle(spot == .hidden ? Color.secondary : Color.primary)
    }

    private var fixedRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("خصّص القائمة")
                Text("آخر «المزيد» دايم، عشان ترجع لهنا").font(.caption)
            }
        }
        .foregroundStyle(Color.secondary)
    }
}

/// A small picture of the menu as it is arranged (rows, the chapter bar, the round buttons, the scrubber), on the
/// page's black: what changes in the editor shows at once.
struct MenuPreview: View {
    let layout: ReaderMenuLayout
    var epub = false
    var bookRTL = true

    var body: some View {
        let rows = Array(layout.rows.prefix(ReaderMenuLayout.maxRows))
        let buttons = ReaderMenuLayout.fit(layout.buttons).kept
        // the menu stands on the right, above its button, with the scrubber on its left (in both languages)
        VStack(alignment: .trailing, spacing: 5) {
            ForEach(rows) { row($0) }
            HStack(spacing: 6) {
                ForEach(buttons) { round($0) }
                circle("ellipsis")
            }
            .environment(\.layoutDirection, Lang.direction)
        }
        .frame(width: 206)
        .padding(.leading, layout.scrubber ? 34 : 0)
        .background(alignment: .leading) {
            if layout.scrubber {
                Capsule().fill(Color.white.opacity(0.14)).frame(width: 26)
                    .overlay(alignment: .top) { Capsule().fill(Color.white.opacity(0.85)).frame(width: 14, height: 3).padding(.top, 24) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("صورة القائمة")
    }

    @ViewBuilder private func content(_ i: ReaderMenuItem) -> some View {
        switch i {
        case .chapters:
            // the previous chapter first, in the book's direction: arrows pointing outwards
            HStack {
                Image(systemName: bookRTL ? "chevron.right" : "chevron.left")
                Spacer()
                Text("690 من 2334").monospacedDigit().environment(\.layoutDirection, Lang.direction)
                Spacer()
                Image(systemName: bookRTL ? "chevron.left" : "chevron.right")
            }
            .environment(\.layoutDirection, bookRTL ? .rightToLeft : .leftToRight)
        case .theme:
            HStack(spacing: 7) {
                ForEach(ReaderTheme.builtIn) { t in
                    Circle().fill(Color(UIColor(hex: t.bg)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .frame(width: 15, height: 15)
                }
            }
            .frame(maxWidth: .infinity)
        case .brightness:
            HStack(spacing: 6) {
                Image(systemName: "sun.min.fill")
                Capsule().fill(Color.white.opacity(0.55)).frame(height: 3)
                Image(systemName: "sun.max.fill")
            }
        case .fontSize:
            HStack(spacing: 8) {
                Text(i.title(epub: epub)).lineLimit(1)
                Spacer(minLength: 4)
                Text("ع").font(.system(size: 10, weight: .semibold))
                Text("22").monospacedDigit()
                Text("ع").font(.system(size: 14, weight: .semibold))
            }
        default:
            HStack(spacing: 6) {
                Text(i.title(epub: epub)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: i.symbol)
            }
        }
    }

    private func row(_ i: ReaderMenuItem) -> some View {
        content(i)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .background(Color.white.opacity(0.14), in: Capsule())
            .environment(\.layoutDirection, Lang.direction)
    }

    private func round(_ i: ReaderMenuItem) -> some View {
        Group {
            if i.width == 2 {
                HStack(spacing: 12) {
                    Image(systemName: i == .chapters ? (bookRTL ? "chevron.right" : "chevron.left") : "textformat.size.smaller")
                    Image(systemName: i == .chapters ? (bookRTL ? "chevron.left" : "chevron.right") : "textformat.size.larger")
                }
                .environment(\.layoutDirection, i == .chapters ? (bookRTL ? .rightToLeft : .leftToRight) : Lang.direction)
                .frame(width: 58, height: 26)
                .background(Color.white.opacity(0.14), in: Capsule())
            } else {
                circle(i.symbol)
            }
        }
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 26, height: 26)
            .background(Color.white.opacity(0.14), in: Circle())
    }
}
