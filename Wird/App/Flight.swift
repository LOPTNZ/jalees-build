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
    /// where, in which tab, and drawn which way (the carousel draws its covers left to right): the travelling copy
    /// matches it, so its marks don't jump corners when it hands over
    struct Spot { let rect: CGRect; let tab: Router.Tab?; var dir: LayoutDirection = .rightToLeft }
    private(set) var spots: [String: Spot] = [:]

    func set(_ id: String, _ rect: CGRect, _ tab: Router.Tab?, _ dir: LayoutDirection) { spots[id] = Spot(rect: rect, tab: tab, dir: dir) }
    func clear(_ id: String) { spots[id] = nil }

    /// A cover that is on screen in the open tab.
    func visible(_ id: String) -> CGRect? {
        guard let s = spots[id], s.tab == nil || s.tab == Router.shared.tab, s.rect.width > 8, s.rect.height > 8 else { return nil }
        return s.rect.intersects(UIScreen.main.bounds) ? s.rect : nil
    }
}

private struct FlightTabKey: EnvironmentKey { static let defaultValue: Router.Tab? = nil }
private struct InBookLayerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// the tab a view lives in (set by each tab's root), so a cover's place belongs to its tab
    var flightTab: Router.Tab? {
        get { self[FlightTabKey.self] }
        set { self[FlightTabKey.self] = newValue }
    }
    /// a book's page in the book layer: back closes the layer (otherwise it is a pushed page and dismisses). A flag,
    /// not a closure: the stage is drawn on every frame, and a new closure each time redrew the whole page each frame.
    var inBookLayer: Bool {
        get { self[InBookLayerKey.self] }
        set { self[InBookLayerKey.self] = newValue }
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

    /// What the layer shows: a book's page, or a novel's page (its book may be "" while it is only being looked at,
    /// before «أضف لمكتبتك»).
    enum Item: Hashable {
        case book(String)
        case novel(Int, String)
        var bookID: String {
            switch self {
            case .book(let b): return b
            case .novel(_, let b): return b
            }
        }
    }

    @Published private(set) var item: Item?
    /// the tab it was opened in (it shows there, and stays there while you look at another tab)
    @Published private(set) var tab: Router.Tab = .library
    /// the page's own cover is hidden while the copy travels (not at rest at 1)
    @Published private(set) var travelling = false
    /// the page is open and still: the tab underneath can stop being drawn (RootView)
    @Published private(set) var covering = false
    /// where the cover starts in the tab underneath; nil: nothing travels, the page fades in place
    private(set) var source: CGRect?
    private var progress: LayerProgress { .shared }

    // the web's timing: 620 ms forwards (EASE_MOVE), back a little quicker (EASE_OUT); a finger's release eases out
    // from where it let go. Every frame is set here (a display link), as the finger does: SwiftUI's own interpolation
    // lost every in-between frame of this layer on the simulator's recordings (it opened and closed in one frame).
    private static let openCurve = Bezier(0.42, 0, 0.16, 1)
    private static let closeCurve = Bezier(0.3, 0.55, 0.2, 1)
    private static let releaseCurve = Bezier(0.2, 0.75, 0.25, 1)

    var isOpen: Bool { item != nil }
    var bookID: String? { item?.bookID }

    /// Starts the layer in the open tab. The cover travels when it is on screen there.
    @discardableResult
    func begin(_ it: Item) -> Bool {
        if let cur = item, cur != it { dismissNow() }
        let id = it.bookID
        source = id.isEmpty ? nil : CoverFrames.shared.visible(id)
        if item == nil {
            stop()
            setP(0)
            tab = Router.shared.tab
            item = it
            stageReady = false
        }
        travelling = source != nil
        return true
    }

    /// Once the page is open: it becomes the last book opened (written now, not while it moves: a write redraws the
    /// whole app).
    private func markOpened() {
        guard let id = bookID, !id.isEmpty, Library.shared.state.book(id) != nil else { return }
        Library.shared.changeBook(id) { $0.opened = Millis.now }
        Library.shared.change { $0.lastBook = id }
    }

    /// The page has been built and laid out: an animation waiting for it starts now, so none of its frames are lost
    /// to building the page.
    private(set) var stageReady = false
    private var whenReady: (() -> Void)?
    private var readyToken = 0

    func stageAppeared() {
        // two more turns: what the page does as it appears (a novel reads its chapters) is drawn too, and the frame
        // with the built page is on screen before the first moving one
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                self.stageReady = true
                let f = self.whenReady
                self.whenReady = nil
                f?()
            }
        }
    }

    /// Runs `f` once the page is built; never later than half a second (a page that did not say so).
    private func wait(_ f: @escaping () -> Void) {
        if stageReady { f(); return }
        whenReady = f
        readyToken += 1
        let mine = readyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard mine == self.readyToken, let g = self.whenReady else { return }
            self.whenReady = nil
            g()
        }
    }

    /// The carousel's swipe up: a book whose cover is on screen, its page following the finger.
    @discardableResult
    func beginBook(_ id: String) -> Bool {
        guard let b = Library.shared.state.book(id), CoverFrames.shared.visible(id) != nil else { return false }
        return begin(b.novel.map { .novel($0.novelID, id) } ?? .book(id))
    }

    /// A book from anywhere: its page opens with the animation.
    @discardableResult
    func open(_ id: String) -> Bool {
        guard let b = Library.shared.state.book(id) else { return false }
        return show(b.novel.map { .novel($0.novelID, id) } ?? .book(id))
    }

    /// A novel's page (bookID "" while it is not in the library).
    func openNovel(_ novel: Int, book: String) { show(.novel(novel, book)) }

    /// when a finger last moved the layer: a tap that comes with the end of a drag (on the same cover) is not a tap
    private var lastDrag: CFTimeInterval = 0

    @discardableResult
    private func show(_ it: Item) -> Bool {
        if item != nil && CACurrentMediaTime() - lastDrag < 0.5 { return true }
        begin(it)
        // the page is built first (under the clear scrim), then it moves with nothing else to do
        wait {
            self.run(to: 1, duration: 0.62, curve: Self.openCurve) { self.landed(open: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Haptics.play("soft") }
        }
        return true
    }

    /// The page shown changes in place (a novel just added to the library: its full page).
    func replace(_ it: Item) {
        guard item != nil else { return }
        item = it
    }

    /// A finger moves it (0…1).
    func drag(_ value: CGFloat) {
        guard item != nil else { return }
        if covering { covering = false }
        lastDrag = CACurrentMediaTime()
        stop()
        whenReady = nil
        travelling = source != nil
        setP(min(1, max(0, value)))
    }

    /// The finger lets go: to the page or back to where you were, easing out from where it is.
    func release(open: Bool) {
        guard item != nil else { return }
        if open { Haptics.play("soft") }
        wait {
            let left = abs((open ? 1 : 0) - self.progress.p)
            self.run(to: open ? 1 : 0, duration: max(0.18, 0.46 * Double(left)), curve: Self.releaseCurve) { self.landed(open: open) }
        }
    }

    /// The back button: home with the animation.
    func close() {
        guard item != nil else { return }
        whenReady = nil
        covering = false
        // the cover goes home only if its place is still on screen
        if let id = bookID, !id.isEmpty, let src = CoverFrames.shared.visible(id) { source = src } else { source = nil }
        travelling = source != nil
        run(to: 0, duration: 0.5, curve: Self.closeCurve) { self.landed(open: false) }
    }

    /// Straight away, no animation (the book was deleted, or something else took the screen).
    func dismissNow() {
        stop()
        whenReady = nil
        travelling = false
        covering = false
        item = nil
        setP(0)
    }

    private func landed(open: Bool) {
        travelling = false
        covering = open
        if open { markOpened() } else { item = nil }
    }

    // MARK: the frames

    private var link: CADisplayLink?
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var duration: Double = 0.5
    private var curve = Bezier(0.25, 0.1, 0.25, 1)
    private var elapsed: Double = 0
    private var last: CFTimeInterval?
    private var done: (() -> Void)?

    /// Moves the progress to `target`, one frame at a time. The clock starts at the first frame drawn and moves at
    /// most 1/30 s a frame: a busy moment (a page being built, a heavy redraw) slows the motion down for a frame
    /// instead of skipping it, so every part of it is seen.
    private func run(to target: CGFloat, duration d: Double, curve c: Bezier, done f: @escaping () -> Void) {
        stop()
        from = progress.p
        to = target
        duration = d
        curve = c
        elapsed = 0
        last = nil
        done = f
        if abs(target - from) < 0.001 { setP(target); done = nil; f(); return }
        let l = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    fileprivate func tick(_ l: CADisplayLink) {
        let now = l.targetTimestamp
        let step = last.map { now - $0 } ?? (now - l.timestamp)
        last = now
        elapsed += min(1.0 / 30, max(0, step))
        let t = min(1, elapsed / duration)
        setP(from + (to - from) * CGFloat(curve.y(t)))
        if t >= 1 {
            let f = done
            stop()
            f?()
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        done = nil
    }

    private func setP(_ v: CGFloat) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { progress.p = v }
    }
}

/// The display link holds this, not the layer (a display link keeps its target alive).
private final class Ticker: NSObject {
    weak var layer: BookLayer?
    init(_ l: BookLayer) { layer = l }
    @MainActor @objc func tick(_ l: CADisplayLink) { layer?.tick(l) }
}

/// A CSS-style timing curve (cubic Bézier from 0,0 to 1,1): the progress at a moment of the animation.
struct Bezier {
    let x1, y1, x2, y2: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2 }

    private func bx(_ s: Double) -> Double { 3 * x1 * s * (1 - s) * (1 - s) + 3 * x2 * s * s * (1 - s) + s * s * s }
    private func by(_ s: Double) -> Double { 3 * y1 * s * (1 - s) * (1 - s) + 3 * y2 * s * s * (1 - s) + s * s * s }
    private func dx(_ s: Double) -> Double { 3 * x1 * (1 - s) * (1 - s) + 6 * (x2 - x1) * s * (1 - s) + 3 * (1 - x2) * s * s }

    /// y at time x (Newton's method, then halving if it strays)
    func y(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var s = x
        for _ in 0..<8 {
            let e = bx(s) - x
            if abs(e) < 1e-5 { return by(s) }
            let d = dx(s)
            if abs(d) < 1e-6 { break }
            s -= e / d
        }
        var lo = 0.0, hi = 1.0
        s = x
        for _ in 0..<30 {
            let e = bx(s) - x
            if abs(e) < 1e-5 { break }
            if e > 0 { hi = s } else { lo = s }
            s = (lo + hi) / 2
        }
        return by(s)
    }
}

// MARK: - the layer on screen

/// Over the tab it was opened in (RootView): the scrim, the page, the travelling cover.
struct BookLayerView: View {
    @ObservedObject private var layer = BookLayer.shared
    @ObservedObject private var progress = LayerProgress.shared
    @ObservedObject private var router = Router.shared
    @ObservedObject private var lib = Library.shared

    var body: some View {
        if let it = layer.item, router.tab == layer.tab {
            LayerStage(p: progress.p, item: it, book: lib.state.book(it.bookID), source: layer.source, travelling: layer.travelling)
                .onChange(of: router.paths[layer.tab]?.count ?? 0) { n in if n > 0 { layer.dismissNow() } }
        }
    }
}

/// Everything the progress moves, worked out on every frame (BookLayer sets the progress frame by frame).
private struct LayerStage: View {
    var p: CGFloat
    let item: BookLayer.Item
    let book: Book?
    let source: CGRect?
    let travelling: Bool
    @Environment(\.look) private var L

    var body: some View {
        // with a cover travelling: the tab fades out early (like Bookly) and the page's words come in as it lands;
        // without one: the page simply fades and rises in place
        let moving = source != nil && book != nil
        // the two overlap, so there is never a moment of an empty screen with only the cover on it
        let scrim = moving ? min(1, p / 0.45) : p
        let content = moving ? min(1, max(0, (p - 0.3) / 0.6)) : p
        ZStack(alignment: .topLeading) {
            Color(L.bg).opacity(scrim).ignoresSafeArea()
            LayerPage(item: item)
                .equatable()
                .id(item)
                // each page, once built (also a new one in the same stage): a waiting animation may start
                .onAppear { BookLayer.shared.stageAppeared() }
                .opacity(content)
                .offset(y: moving ? 0 : (1 - p) * 28)
                .allowsHitTesting(p > 0.98)
        }
        .overlay {
            // the covers' places are in screen points, left to right; this layer starts below the status bar
            // (laid out left to right: in Arabic, .position would mirror x and put the cover on the wrong side)
            GeometryReader { g in
                let o = g.frame(in: .global).origin
                if moving, let b = book, let src = source, travelling || p < 0.999 {
                    let hero = CoverFrames.shared.spots["hero:" + b.id]?.rect ?? defaultHero(b)
                    // straight with the progress: the finger's own pace, or the animation's curve (no second easing)
                    let r = lerp(src, hero, p)
                    BookCover(book: b, radius: 6 + 5 * (1 - p), marks: p < 0.5)
                        .environment(\.layoutDirection, CoverFrames.shared.spots[b.id]?.dir ?? Lang.direction)
                        .frame(width: r.width, height: r.height)
                        .shadow(color: .black.opacity(0.45 * Double(1 - content * 0.4)), radius: 14, y: 10)
                        .position(x: r.midX - o.x, y: r.midY - o.y)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .allowsHitTesting(false)
        }
        .environment(\.inBookLayer, true)
    }


    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// until the page has said where its cover is: about where a book page puts it
    private func defaultHero(_ book: Book) -> CGRect {
        let w: CGFloat = 116, h = w / CGFloat(book.coverAspect)
        let top = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.top ?? 47) + 60
        let screen = UIScreen.main.bounds.width
        return Lang.english ? CGRect(x: screen - 16 - w, y: top, width: w, height: h) : CGRect(x: 16, y: top, width: w, height: h)
    }
}

/// The page in the layer, the same view for the same item: the stage is redrawn on every frame of a move, the page
/// only when its own book changes.
private struct LayerPage: View, Equatable {
    let item: BookLayer.Item
    static func == (a: Self, b: Self) -> Bool { a.item == b.item }

    var body: some View {
        switch item {
        case .novel(let n, let b): NovelPageScreen(novelID: n, bookID: b)
        case .book(let b): BookPage(bookID: b)
        }
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
    @Environment(\.layoutDirection) private var dir
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { CoverFrames.shared.set(id, g.frame(in: .global), tab, dir) }
                .onChange(of: g.frame(in: .global)) { CoverFrames.shared.set(id, $0, tab, dir) }
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
