import SwiftUI
import UIKit

/// The library tab (inventory-1, section 2): a header with add, view, options and search; the books as a carousel,
/// a shelf or a grid; a welcome page when there are none.
struct LibraryView: View {
    let ns: Namespace.ID
    @ObservedObject private var lib = Library.shared
    @ObservedObject private var center = CarouselCenter.shared
    @Environment(\.look) private var L
    @State private var searching = false
    @State private var query = ""
    @State private var sheet: LibSheet?
    @FocusState private var searchFocus: Bool

    enum LibSheet: Identifiable {
        case add, view, options, status, progress(String), note(String)
        var id: String {
            switch self {
            case .add: return "add"
            case .view: return "view"
            case .options: return "options"
            case .status: return "status"
            case .progress(let b): return "p" + b
            case .note(let b): return "n" + b
            }
        }
    }

    private var view: String { lib.state.settings.view }
    private var filterActive: Bool {
        let f = lib.state.settings.filter
        return f.str("format", "all") != "all" || !f.str("genre").isEmpty || f.str("series", "all") != "all" || f.bool("hideDone") || !f.str("col").isEmpty
    }

    var body: some View {
        let books = lib.state.libList(query: query)
        let carousel = view == "carousel" && !lib.state.books.isEmpty
        VStack(spacing: 0) {
            header(over: carousel)
            if lib.state.books.isEmpty {
                WelcomeView()
            } else if books.isEmpty && view != "shelf" {
                emptyFilter
            } else if view == "grid" {
                LibraryGrid(books: books, ns: ns)
            } else if view == "shelf" {
                ShelfView(books: books, ns: ns)
            } else {
                CarouselView(books: books, ns: ns, sheet: $sheet)
            }
        }
        .background {
            if carousel { CarouselBand(book: lib.state.book(center.id ?? "") ?? books.first) } else { Color(L.bg).ignoresSafeArea() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .add: AddMenu()
                case .view: ViewMenu()
                case .options: LibOptions()
                case .status: StatusMenu()
                case .progress(let id): QuickProgress(bookID: id)
                case .note(let id): AddNoteMenu(bookID: id)
                }
            }
            .environment(\.look, L)
            .environment(\.layoutDirection, .rightToLeft)
            .presentationDetents(s.id == "options" ? [.large] : [.medium, .large])
        }
    }

    // MARK: header

    private func header(over: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                headerButton("plus", "إضافة كتاب", over) { sheet = .add }
                if !lib.state.books.isEmpty {
                    headerButton(["carousel": "rectangle.stack", "shelf": "books.vertical", "grid": "square.grid.3x3"][view] ?? "rectangle.stack",
                                 "طريقة العرض", over) { sheet = .view }
                }
                Spacer()
                Text("جَليس").font(JFont.display(27, .bold)).foregroundStyle(over ? Color.white : Color(L.ink))
                    .shadow(color: over ? .black.opacity(0.35) : .clear, radius: 3, y: 1)
                Spacer()
                if !lib.state.books.isEmpty {
                    headerButton("slider.horizontal.3", "خيارات المكتبة", over, dot: filterActive) { sheet = .options }
                    headerButton("magnifyingglass", "بحث", over) {
                        withAnimation(.easeOut(duration: 0.2)) { searching.toggle() }
                        if searching { searchFocus = true } else { query = "" }
                    }
                }
            }
            if !lib.state.books.isEmpty {
                if searching {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Color(L.ink2))
                            TextField("العنوان، المؤلف، المجموعة…", text: $query).font(JFont.body(16)).submitLabel(.search).focused($searchFocus)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 12).frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                        Button("إلغاء") { withAnimation { searching = false }; query = "" }
                            .font(JFont.body(15, .medium)).foregroundStyle(over ? Color.white : Color(L.primary))
                    }
                } else {
                    Button { sheet = .status } label: {
                        HStack(spacing: 6) {
                            Text(statusTitle).font(JFont.body(15, .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(over ? Color.white : Color(L.ink))
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Capsule().fill(over ? Color.black.opacity(0.26) : Color(L.surface)))
                        .overlay(Capsule().strokeBorder(over ? Color.white.opacity(0.14) : Color(L.line), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("عرض: " + statusTitle)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }

    private var statusTitle: String {
        let f = lib.state.settings.filter
        let col = f.str("col")
        if !col.isEmpty { return col }
        return LibraryFilters.label[f.str("status", "all")] ?? "كل الكتب"
    }

    private func headerButton(_ symbol: String, _ label: String, _ over: Bool, dot: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .foregroundStyle(over ? Color.white : Color(L.ink))
                .frame(width: 44, height: 44)
                .background(Circle().fill(over ? Color.black.opacity(0.26) : Color(L.surface)))
                .overlay(Circle().strokeBorder(over ? Color.white.opacity(0.14) : Color(L.line), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if dot { Circle().fill(Color(L.accent)).frame(width: 9, height: 9).offset(x: -3, y: 3) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var emptyFilter: some View {
        VStack(spacing: 14) {
            Text("ما فيه كتب تطابق البحث أو التصفية.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
            Button("إظهار كل الكتب") { LibraryFilters.clear(); query = ""; searching = false }.buttonStyle(JButtonStyle(look: L))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum LibraryFilters {
    static let label: [String: String] = ["all": "كل الكتب", "reading": "أقرأه الآن", "want": "أريد قراءته", "done": "أنهيته", "dnf": "توقفت عنه", "lent": "المعارة والمستعارة"]
    static let order = ["all", "reading", "want", "done", "dnf", "lent"]

    @MainActor static func clear() {
        Library.shared.change { $0.settings.filter = Settings.defaults().obj("f") }
    }

    @MainActor static func set(_ path: String, _ v: JSONValue) {
        Library.shared.change { st in
            var s = st.settings.raw
            let parts = path.split(separator: ".").map(String.init)
            if parts.count == 2 {
                var o = s.obj(parts[0])
                o[parts[1]] = v
                s[parts[0]] = .object(o)
            } else {
                s[path] = v
            }
            st.settings = Settings(s)
        }
    }
}

// MARK: - the welcome page (no books yet)

struct WelcomeView: View {
    @Environment(\.look) private var L

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("جَليس").font(JFont.display(46, .bold)).foregroundStyle(Color(L.primary)).padding(.top, 30)
                Text("رفّك ينتظر أول كتاب").font(JFont.display(22, .semibold)).foregroundStyle(Color(L.ink))
                Text("أضف الكتب اللي تقرأها الحين، وكل جلسة ومقطع يعجبك يصير له مكان هنا.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                VStack(spacing: 10) {
                    item("barcode.viewfinder", "امسح الباركود", "من ظهر الكتاب") { Flows.scanAdd() }
                    item("square.stack.3d.down.right", "مسح متتابع", "كتاب ورا كتاب، مناسب لمكتبتك الورقية") { Flows.scanBatch() }
                    item("magnifyingglass", "ابحث أو أضفه يدويًا", "بالعنوان أو المؤلف") { Flows.addBook() }
                    item("arrow.clockwise.icloud", "استعادة نسخة احتياطية", "من ملف صدّرته قبل") { Flows.importBackup() }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 30)
        }
    }

    private func item(_ icon: String, _ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color(L.primary)).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(JFont.body(16, .semibold)).foregroundStyle(Color(L.ink))
                    Text(sub).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                }
                Spacer()
                Image(systemName: "chevron.backward").foregroundStyle(Color(L.ink2))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - opening a book from the library

@MainActor
enum OpenBook {
    /// A book's page (a novel's own page for web novels and EPUB books), pushed in the library tab.
    static func open(_ b: Book) {
        Library.shared.changeBook(b.id) { $0.opened = Millis.now }
        Library.shared.change { $0.lastBook = b.id }
        if let n = b.novel { Router.shared.openNovel(n.novelID, book: b.id) } else { Router.shared.push(.book(b.id)) }
        // the web's soft tap when the details have finished opening
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Haptics.play("soft") }
    }
}

extension View {
    /// The cover a book page grows from (iOS 18's zoom); nothing on older systems.
    @ViewBuilder func zoomSource(_ id: String, _ ns: Namespace.ID) -> some View {
        if #available(iOS 18, *) { self.matchedTransitionSource(id: id, in: ns) } else { self }
    }

    /// A page that grows from its book's cover, and shrinks back into it when you swipe down or go back.
    @ViewBuilder func zoomDestination(_ id: String, _ ns: Namespace.ID) -> some View {
        if #available(iOS 18, *) { self.navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }
}

// MARK: - the grid

struct LibraryGrid: View {
    let books: [Book]
    let ns: Namespace.ID
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L

    var body: some View {
        let cols = max(2, min(4, lib.state.settings.cols))
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: cols), spacing: 20) {
                ForEach(books) { b in
                    Button { OpenBook.open(b) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            BookCover(book: b).frame(maxWidth: .infinity).zoomSource(b.id, ns)
                                .shadow(color: .black.opacity(0.3), radius: 7, y: 6)
                            Text(b.title).font(JFont.body(cols == 4 ? 12 : 13.5, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(2)
                            Text(b.author.isEmpty ? b.status.label : b.author).font(JFont.body(cols == 4 ? 11 : 12)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(b.title)
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 30)
        }
    }
}
