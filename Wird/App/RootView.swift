import SwiftUI
import UIKit

/// The look of the moment: the owner's theme and accent over the phone's light or dark mode.
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()
    @Published private(set) var look = JLook()
    private var systemDark = true

    func update(systemDark: Bool? = nil) {
        if let d = systemDark { self.systemDark = d }
        let l = Theme.look(Library.shared.state.settings, systemDark: self.systemDark)
        if l != look || l.accent != look.accent || l.surface != look.surface { look = l }
    }
}

/// The whole app: the open tab (each with its own stack of pages) above the tab bar.
struct RootView: View {
    @ObservedObject private var router = Router.shared
    @ObservedObject private var appearance = Appearance.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var present = Present.shared
    @ObservedObject private var session = SessionModel.shared
    @Environment(\.colorScheme) private var scheme
    /// tabs opened at least once stay alive, so each keeps its place
    @State private var opened: Set<Router.Tab> = [.library]
    /// grows each time a list tab is shown again, so its list is read afresh
    @State private var visits: [Router.Tab: Int] = [:]

    private var L: JLook { appearance.look }

    var body: some View {
        ZStack {
            Color(L.bg).ignoresSafeArea()
            ForEach(Router.Tab.allCases, id: \.self) { t in
                if opened.contains(t) {
                    TabRoot(tab: t, visit: visits[t] ?? 0)
                        .opacity(router.tab == t ? 1 : 0)
                        .allowsHitTesting(router.tab == t)
                        .accessibilityHidden(router.tab != t)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { TabBar() }
        .overlay(alignment: .bottom) { VStack(spacing: 10) { ToastView(); SessionChip() }.padding(.bottom, 92) }
        .fullScreenCover(isPresented: $session.showScreen) {
            SessionScreen().environment(\.look, L).environment(\.layoutDirection, .rightToLeft).environment(\.locale, Locale(identifier: "ar@numbers=latn"))
        }
        .sheet(item: $present.modal) { m in
            Group {
                switch m {
                case .bookForm(let id): BookFormView(bookID: id)
                case .multiAdd: MultiAddSheet().presentationDetents([.large])
                case .batch(let codes): BatchAddSheet(codes: codes)
                case .finish(let b, let v, let c): FinishSheet(bookID: b, volume: v, congrats: c).presentationDetents([.large])
                case .reread(let b): RereadSheet(bookID: b)
                case .readDel(let b, let n): ReadDelSheet(bookID: b, n: n)
                case .item(let r): ItemForm(ref: r)
                case .review(let b): WordReview(bookID: b)
                case .character(let b, let c): CharacterCard(bookID: b, charID: c)
                }
            }
            .environment(\.look, L)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar@numbers=latn"))
        }
        .environment(\.look, L)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "ar@numbers=latn"))
        .tint(Color(L.primary))
        .onAppear { appearance.update(systemDark: scheme == .dark) }
        .onChange(of: scheme) { appearance.update(systemDark: $0 == .dark) }
        .onReceive(library.$state) { _ in appearance.update() }
        .onChange(of: router.tab) { t in
            opened.insert(t)
            if [.updates, .downloads, .history].contains(t) { visits[t, default: 0] += 1 }
        }
    }
}

/// One tab: its first screen and the pages pushed over it.
private struct TabRoot: View {
    let tab: Router.Tab
    let visit: Int
    @ObservedObject private var router = Router.shared
    @Environment(\.look) private var L
    /// the library's covers and the pages that grow from them
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: router.path(tab)) {
            first
                .navigationDestination(for: Router.Page.self) { page in
                    switch page {
                    case .novel(let id, let book):
                        if tab == .library { NovelPageScreen(novelID: id, bookID: book).zoomDestination(book, zoom) } else { NovelPageScreen(novelID: id, bookID: book) }
                    case .book(let id):
                        if tab == .library { BookPage(bookID: id).zoomDestination(id, zoom) } else { BookPage(bookID: id) }
                    }
                }
        }
    }

    @ViewBuilder private var first: some View {
        switch tab {
        case .browse: BrowseTab(look: L)
        case .updates: UpdatesTab(look: L).id(visit)
        case .downloads: DownloadsTab(look: L).id(visit)
        case .history: HistoryTab(look: L).id(visit)
        case .library: LibraryView(ns: zoom)
        case .notebook: NotebookView()
        default: TabPlaceholder(tab: tab)
        }
    }
}

// MARK: - the tab bar: two groups, like iOS's search tab

/// Jalees's group on the right, the novels' group on the left. The open group is a capsule with its tabs; the other
/// shrinks to a round button showing the tab you left it at. Each keeps its side.
struct TabBar: View {
    @ObservedObject private var router = Router.shared
    @Environment(\.look) private var L
    @Namespace private var pill

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width - 28 - 10 - 58
            HStack(spacing: 10) {
                group(.main, Router.Tab.main, width: wide)
                group(.novels, Router.Tab.novels, width: wide)
            }
            .padding(.horizontal, 14)
            .frame(width: g.size.width, height: 58)
        }
        .frame(height: 58)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(L.bg).ignoresSafeArea(edges: .bottom))
        .animation(.spring(response: 0.46, dampingFraction: 0.86), value: router.group)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: router.tab)
    }

    private func group(_ gr: Router.Group, _ tabs: [Router.Tab], width: CGFloat) -> some View {
        let on = router.group == gr
        let cur = gr == .main ? router.mainTab : router.novelsTab
        return HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { t in
                if on || t == cur {
                    Button { router.select(t) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 20, weight: .medium))
                            if on { Text(t.title).font(JFont.body(11.5, t == cur ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8) }
                        }
                        .foregroundStyle(Color(on && t == cur ? L.primary : (on ? L.ink2 : L.ink)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if on && t == cur {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color(L.primary).opacity(0.18))
                                    .padding(4)
                                    .matchedGeometryEffect(id: "pill-" + gr.rawValue, in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.title)
                    .accessibilityAddTraits(on && t == cur ? [.isSelected] : [])
                }
            }
        }
        .frame(width: on ? width : 58, height: 58)
        .background(Capsule().fill(Color(L.surface)))
        .overlay(Capsule().strokeBorder(Color(L.line), lineWidth: 1))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.28), radius: 11, y: 8)
    }
}

// MARK: - pages still to come (phases 2 to 7); never shipped

private struct TabPlaceholder: View {
    let tab: Router.Tab
    @Environment(\.look) private var L
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: tab.icon).font(.system(size: 34)).foregroundStyle(Color(L.primary))
            Text(tab.title).font(JFont.display(26)).foregroundStyle(Color(L.ink))
            Text("\(Library.shared.state.books.count) كتاب").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(L.bg).ignoresSafeArea())
        .navigationTitle(tab.title)
    }
}

/// The swipe from the edge keeps working on pages that hide the system bar.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        g == interactivePopGestureRecognizer ? viewControllers.count > 1 : true
    }
}

/// The app's root: the SwiftUI app inside a UIKit controller (the reader and the site are presented from it).
final class RootController: UIHostingController<AnyView> {
    init() {
        super.init(rootView: AnyView(RootView()))
        view.backgroundColor = .black
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("no storyboard") }
}
