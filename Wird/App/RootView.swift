import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The look of the moment: the owner's theme and accent over the phone's light or dark mode.
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()
    @Published private(set) var look = JLook()
    private var systemDark = true

    func update(systemDark: Bool? = nil) {
        if let d = systemDark { self.systemDark = d }
        let s = Library.shared.state.settings
        // light or dark by choice: the whole window follows, so system parts (keyboard, menus, sheets) match
        let style: UIUserInterfaceStyle = s.theme == "dark" ? .dark : s.theme == "light" ? .light : .unspecified
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows where w.overrideUserInterfaceStyle != style { w.overrideUserInterfaceStyle = style }
        }
        let l = Theme.look(s, systemDark: self.systemDark)
        JFont.scale = l.fs / 15
        if l != look || l.accent != look.accent || l.surface != look.surface { look = l }
    }
}

/// The whole app: the open tab (each with its own stack of pages) above the tab bar.
struct RootView: View {
    @ObservedObject private var router = Router.shared
    @ObservedObject private var appearance = Appearance.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var present = Present.shared
    @ObservedObject private var backup = BackupImport.shared
    @ObservedObject private var lang = LangState.shared
    @Environment(\.colorScheme) private var scheme
    /// tabs opened at least once stay alive, so each keeps its place
    @State private var opened: Set<Router.Tab> = [.library]
    /// grows each time a list tab is shown again, so its list is read afresh
    @State private var visits: [Router.Tab: Int] = [:]
    /// the launch splash, once per launch
    @State private var splash = true
    @ObservedObject private var keyboard = KeyboardWatch.shared

    private var L: JLook { appearance.look }

    var body: some View {
        ZStack {
            Color(L.bg).ignoresSafeArea()
            ForEach(Router.Tab.allCases, id: \.self) { t in
                if opened.contains(t) {
                    TabRoot(tab: t, visit: visits[t] ?? 0)
                        // (the tab under an open book page stays drawn: hiding it made it draw itself again, all at
                        // once, the moment the page closed)
                        .opacity(router.tab == t ? 1 : 0)
                        .allowsHitTesting(router.tab == t)
                        .accessibilityHidden(router.tab != t)
                }
            }
            // a book's page over the library, opened in place (Flight.swift)
            BookLayerView()
        }
        // a tab changes at once, as the system's tab bars do (a fade made every change feel slow)
        // a new language: every page is drawn again in it
        .id(lang.english)
        // the bar goes under the keyboard, as the system's does (it rode up on top of it)
        .safeAreaInset(edge: .bottom, spacing: 0) { if !keyboard.up { TabBar().id(lang.english) } }
        .overlay(alignment: .bottom) { VStack(spacing: 10) { ToastView(); if router.group == .novels { SessionChip() } }.padding(.bottom, 92) }
        .overlay { if splash { SplashView { splash = false }.environment(\.look, L) } }
        .modifier(SessionCover(look: L))
        .sheet(item: $present.modal, onDismiss: { present.dismissed() }) { m in
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
                case .card(let r): CardSheet(request: r).presentationDetents([.large])
                case .pdf(let b): PDFSummarySheet(bookID: b).presentationDetents([.large])
                case .restore(let f): RestoreSheet(file: f).presentationDetents([.medium])
                }
            }
            .environment(\.look, L)
            .environment(\.layoutDirection, Lang.direction)
            .environment(\.locale, Lang.locale).environment(\.calendar, Calendar.greg)
        }
        .environment(\.look, L)
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, Lang.locale).environment(\.calendar, Calendar.greg)
        .tint(Color(L.primary))
        .onAppear {
            appearance.update(systemDark: scheme == .dark)
            // as the web app did after loading: unlock what the saved data already reached (quietly on the first run)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Achievements.check(); Reminder.sync() }
        }
        .onChange(of: scheme) { appearance.update(systemDark: $0 == .dark) }
        .onReceive(library.$state) { _ in appearance.update() }
        .fileImporter(isPresented: $backup.picking, allowedContentTypes: [.json, .data, .item]) { r in
            if case .success(let url) = r { Backup.open(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // back in the app: today's goal may be met now, and the reminders run three weeks ahead
            Reminder.sync()
            WidgetFeed.update()
            Task { await ServerLink.backupIfDue() }
            // new chapters: at most once an hour when Jalees comes up
            Task { await NewChapters.checkIfDue() }
            // links shared from Safari while Jalees was closed
            SharedAdd.process()
            // the main tabs are built quietly once the library is up, so even a first visit opens at once
            // (one at a time, so no single moment is heavy)
            for (i, t) in Router.Tab.main.enumerated() where !opened.contains(t) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(i) * 0.6) { opened.insert(t) }
            }
        }
        .onChange(of: router.tab) { t in
            opened.insert(t)
            if [.updates, .downloads, .history].contains(t) { visits[t, default: 0] += 1 }
        }
    }
}

/// The session screen over everything. It watches the session itself, so the clock's ticks do not redraw the whole app.
private struct SessionCover: ViewModifier {
    let look: JLook
    @ObservedObject private var session = SessionModel.shared

    func body(content: Content) -> some View {
        // a full-height card (as Apple Music's player): a swipe down minimises it to the chip, as its chevron does
        content.sheet(isPresented: $session.showScreen, onDismiss: {
            if SessionModel.shared.timer != nil { SessionModel.shared.minimize() }
        }) {
            SessionScreen().environment(\.look, look).environment(\.layoutDirection, Lang.direction).environment(\.locale, Lang.locale).environment(\.calendar, Calendar.greg)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
                        NovelPageScreen(novelID: id, bookID: book)
                    case .book(let id):
                        BookPage(bookID: id)
                    case .notebook(let id, let section):
                        BookNotebookPage(bookID: id, start: section)
                    }
                }
        }
        // the covers' places belong to this tab (Flight.swift)
        .environment(\.flightTab, tab)
    }

    @ViewBuilder private var first: some View {
        switch tab {
        case .browse: BrowseTab(look: L)
        case .updates: UpdatesTab(look: L, visit: visit)
        case .downloads: DownloadsTab(look: L, visit: visit)
        case .history: HistoryTab(look: L, visit: visit)
        case .library: LibraryView(ns: zoom)
        case .notebook: NotebookView()
        // the goals and stats work out all 40 achievements: only while the tab is open, not on every save behind it
        case .progress: ProgressTab()
        case .settings: SettingsView()
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
            // on an iPad the bar keeps a phone's proportions, in the middle
            let w = min(g.size.width, 640)
            let wide = w - 28 - 10 - 58
            HStack(spacing: 10) {
                group(.main, Router.Tab.main, width: wide)
                group(.novels, Router.Tab.novels, width: wide)
            }
            .padding(.horizontal, 14)
            .frame(width: w, height: 58)
            .frame(width: g.size.width)
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

/// Whether the keyboard is up (a real one: an iPad's hardware keyboard only shows a small bar).
@MainActor
final class KeyboardWatch: NSObject, ObservableObject {
    static let shared = KeyboardWatch()
    @Published private(set) var up = false

    private override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(hidden), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func changed(_ n: Notification) {
        let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let shown = end.height > 120 && end.minY < UIScreen.main.bounds.height - 1
        if up != shown { up = shown }
    }

    @objc private func hidden() { if up { up = false } }
}
