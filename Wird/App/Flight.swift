import SwiftUI
import UIKit

// The book layer (the web app's carousel details, cvOpen, and its book page with pull-to-close, inventory-1 §5 and
// inventory-3 §3.5; the owner's model is Bookly): a book's page opens over the library in place, driven by one
// progress value from 0 (the library) to 1 (the page). A finger moves it (swipe the carousel's cover up, pull the
// page down at its top) or an animation does (a tap, the back button). From that one value, every frame: the
// library fades under a scrim, the cover travels between its place in the library and its place on the page, and
// the page's content fades in near the end. Let go early and it goes back.

/// Where each cover is on screen right now, and in which tab (only a cover in the tab you are looking at counts).
@MainActor
final class CoverFrames {
    static let shared = CoverFrames()
    struct Spot { let rect: CGRect; let tab: Router.Tab? }
    private(set) var spots: [String: Spot] = [:]

    func set(_ id: String, _ rect: CGRect, _ tab: Router.Tab?) { spots[id] = Spot(rect: rect, tab: tab) }
    func clear(_ id: String) { spots[id] = nil }

    /// A cover that is on screen in the open tab.
    func visible(_ id: String) -> CGRect? {
        guard let s = spots[id], s.tab == nil || s.tab == Router.shared.tab, s.rect.width > 8, s.rect.height > 8 else { return nil }
        return s.rect.intersects(UIScreen.main.bounds) ? s.rect : nil
    }
}

private struct FlightTabKey: EnvironmentKey { static let defaultValue: Router.Tab? = nil }
private struct PageCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    /// the tab a view lives in (set by each tab's root), so a cover's place belongs to its tab
    var flightTab: Router.Tab? {
        get { self[FlightTabKey.self] }
        set { self[FlightTabKey.self] = newValue }
    }
    /// how a book's page goes back when it is in the book layer (otherwise it is a pushed page and dismisses)
    var pageClose: (() -> Void)? {
        get { self[PageCloseKey.self] }
        set { self[PageCloseKey.self] = newValue }
    }
}

/// The progress alone, watched only by the layer's stage, so a finger's every move redraws nothing else.
@MainActor
final class LayerProgress: ObservableObject {
    static let shared = LayerProgress()
    @Published var p: CGFloat = 0
}

@MainActor
final class BookLayer: ObservableObject {
    static let shared = BookLayer()
    /// the book whose page is in the layer (nil: none)
    @Published private(set) var bookID: String?
    /// the page's own cover is hidden while the copy travels (not at rest at 1)
    @Published private(set) var travelling = false
    private(set) var source: CGRect = .zero
    private(set) var live = false
    private var token = 0
    private var progress: LayerProgress { .shared }

    // the web's timing: 640 ms forwards (EASE_MOVE), back a little quicker (EASE_OUT); a finger's release springs
    static let openAnimation = Animation.timingCurve(0.42, 0, 0.16, 1, duration: 0.62)
    static let closeAnimation = Animation.timingCurve(0.3, 0.55, 0.2, 1, duration: 0.5)
    static let releaseAnimation = Animation.interactiveSpring(response: 0.42, dampingFraction: 0.88)

    var isOpen: Bool { bookID != nil }

    /// Starts the layer for a book whose cover is on screen in the library. False when it can't (the caller opens
    /// the page the plain way).
    @discardableResult
    func begin(_ id: String) -> Bool {
        guard bookID == nil || bookID == id, Router.shared.tab == .library, let src = CoverFrames.shared.visible(id),
              Library.shared.state.book(id) != nil else { return false }
        token += 1
        source = src
        if bookID == nil {
            setP(0)
            bookID = id
            Library.shared.changeBook(id) { $0.opened = Millis.now }
            Library.shared.change { $0.lastBook = id }
        }
        travelling = true
        return true
    }

    /// A tap: the page opens with the animation.
    func open(_ id: String) -> Bool {
        guard begin(id) else { return false }
        live = false
        // one frame for the page to be laid out under the scrim (its cover's place is where the copy goes)
        DispatchQueue.main.async {
            withAnimation(Self.openAnimation) { self.progress.p = 1 }
            self.settle(open: true, after: 0.64)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Haptics.play("soft") }
        return true
    }

    /// A finger moves it (0…1).
    func drag(_ value: CGFloat) {
        guard bookID != nil else { return }
        live = true
        travelling = true
        setP(min(1, max(0, value)))
    }

    /// The finger lets go: to the page or back to the library.
    func release(open: Bool) {
        guard bookID != nil else { return }
        live = false
        if open { Haptics.play("soft") }
        withAnimation(Self.releaseAnimation) { progress.p = open ? 1 : 0 }
        settle(open: open, after: 0.5)
    }

    /// The back button: home with the animation.
    func close() {
        guard bookID != nil else { return }
        live = false
        travelling = true
        withAnimation(Self.closeAnimation) { progress.p = 0 }
        settle(open: false, after: 0.52)
    }

    /// Straight away, no animation (the book was deleted, or the library changed under it).
    func dismissNow() {
        token += 1
        live = false
        travelling = false
        bookID = nil
        setP(0)
    }

    private func settle(open: Bool, after: Double) {
        token += 1
        let mine = token
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard mine == self.token, !self.live else { return }
            if open {
                self.travelling = false
            } else {
                self.travelling = false
                self.bookID = nil
            }
        }
    }

    private func setP(_ v: CGFloat) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { progress.p = v }
    }
}

// MARK: - the layer on screen

/// Over the library tab (RootView): the scrim, the page, the travelling cover.
struct BookLayerView: View {
    @ObservedObject private var layer = BookLayer.shared
    @ObservedObject private var progress = LayerProgress.shared
    @ObservedObject private var router = Router.shared
    @ObservedObject private var lib = Library.shared

    var body: some View {
        if let id = layer.bookID, router.tab == .library, let b = lib.state.book(id) {
            LayerStage(p: progress.p, book: b, source: layer.source, travelling: layer.travelling)
                .onChange(of: router.paths[.library]?.count ?? 0) { n in if n > 0 { layer.dismissNow() } }
        }
    }
}

/// Everything the progress moves, worked out on every frame (Animatable: SwiftUI hands it each in-between value).
private struct LayerStage: View, Animatable {
    var p: CGFloat
    let book: Book
    let source: CGRect
    let travelling: Bool
    @Environment(\.look) private var L

    var animatableData: CGFloat {
        get { p }
        set { p = newValue }
    }

    var body: some View {
        // the library fades out early (like Bookly: the other covers and the words go first)
        let scrim = min(1, p / 0.4)
        // the page's words come in at the end, as the cover lands
        let content = max(0, (p - 0.55) / 0.45)
        let hero = CoverFrames.shared.spots["hero:" + book.id]?.rect ?? defaultHero
        let r = lerp(source, hero, curve(p))
        ZStack(alignment: .topLeading) {
            Color(L.bg).opacity(scrim).ignoresSafeArea()
            page
                .opacity(content)
                .allowsHitTesting(p > 0.98)
        }
        .overlay {
            // the covers' places are in screen points; this layer starts below the status bar
            GeometryReader { g in
                let o = g.frame(in: .global).origin
                if travelling || p < 0.999 {
                    BookCover(book: book, radius: 6 + 5 * (1 - p), marks: p < 0.5)
                        .frame(width: r.width, height: r.height)
                        .shadow(color: .black.opacity(0.45 * Double(1 - content * 0.4)), radius: 14, y: 10)
                        .position(x: r.midX - o.x, y: r.midY - o.y)
                }
            }
            .allowsHitTesting(false)
        }
        .environment(\.pageClose, { BookLayer.shared.close() })
    }

    @ViewBuilder private var page: some View {
        if let n = book.novel {
            NovelPageScreen(novelID: n.novelID, bookID: book.id)
        } else {
            BookPage(bookID: book.id)
        }
    }

    /// a soft start and landing over the whole path
    private func curve(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// until the page has said where its cover is: about where a book page puts it
    private var defaultHero: CGRect {
        let w: CGFloat = 116, h = w / CGFloat(book.coverAspect)
        let top = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.top ?? 47) + 60
        let screen = UIScreen.main.bounds.width
        return Lang.english ? CGRect(x: screen - 16 - w, y: top, width: w, height: h) : CGRect(x: 16, y: top, width: w, height: h)
    }
}

// MARK: - pull the page down to close it (the web's pull-to-close, Bookly's swipe down)

/// Sits in a book page's scrolling content and listens to its scroll view's own pan: pulled down while at the top,
/// the layer follows the finger; let go past the point (or quickly) and the page closes, otherwise it stays.
struct PullToClose: UIViewRepresentable {
    let bookID: String

    func makeUIView(context: Context) -> Hook { Hook(bookID: bookID) }
    func updateUIView(_ v: Hook, context: Context) { v.bookID = bookID }

    final class Hook: UIView {
        var bookID: String
        private weak var scroll: UIScrollView?
        private var engaged = false
        private var bounced = true

        init(bookID: String) {
            self.bookID = bookID
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("no storyboard") }

        deinit { scroll?.panGestureRecognizer.removeTarget(self, action: nil) }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, scroll == nil else { return }
            var v = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            guard let s = v as? UIScrollView else { return }
            scroll = s
            s.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
        }

        @MainActor @objc private func pan(_ g: UIPanGestureRecognizer) {
            guard let s = scroll, BookLayer.shared.bookID == bookID else { return }
            let top = -s.adjustedContentInset.top
            switch g.state {
            case .began:
                engaged = s.contentOffset.y <= top + 2 && g.velocity(in: s).y > 0
                if engaged { bounced = s.bounces; s.bounces = false }
            case .changed:
                guard engaged else { return }
                let ty = g.translation(in: s).y
                BookLayer.shared.drag(1 - max(0, ty) / 340)
            case .ended, .cancelled, .failed:
                guard engaged else { return }
                engaged = false
                s.bounces = bounced
                let ty = g.translation(in: s).y, vy = g.velocity(in: s).y
                let p = 1 - max(0, ty) / 340
                BookLayer.shared.release(open: !(p < 0.72 || vy > 650))
            default: break
            }
        }
    }
}

// MARK: - the pieces the views wear

private struct CoverSpot: ViewModifier {
    let id: String
    @Environment(\.flightTab) private var tab
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { CoverFrames.shared.set(id, g.frame(in: .global), tab) }
                .onChange(of: g.frame(in: .global)) { CoverFrames.shared.set(id, $0, tab) }
        })
    }
}

private struct LayerHidden: ViewModifier {
    let id: String
    let hero: Bool
    @ObservedObject private var layer = BookLayer.shared
    func body(content: Content) -> some View {
        // the library's cover gives way to the travelling copy while the layer is up; the page's cover while it travels
        let hidden = layer.bookID == id && (hero ? layer.travelling : true)
        return content.opacity(hidden ? 0 : 1)
    }
}

extension View {
    /// A cover a book's page can open from (and come back to).
    func coverSpot(_ bookID: String) -> some View { modifier(CoverSpot(id: bookID)).modifier(LayerHidden(id: bookID, hero: false)) }
    /// The cover at the top of a book's page.
    func heroSpot(_ bookID: String) -> some View { modifier(CoverSpot(id: "hero:" + bookID)).modifier(LayerHidden(id: bookID, hero: true)) }
    /// (kept for the pages that used it; the layer fades the page itself now)
    func flightArrive(_ bookID: String) -> some View { self }
}
