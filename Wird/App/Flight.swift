import SwiftUI
import UIKit

// The cover flight (the web app's openBook / pgAnim, inventory-3 §3.5): opening a book from the library, its cover
// flies from where it sits (the carousel, the grid, the shelf) to the cover at the top of its page while the library
// fades out and the page's content rises in; going back, the cover flies home and the page fades away.
// It is drawn above everything with Core Animation: a picture of the screen as it was, and a picture of the cover.

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
        let screen = UIScreen.main.bounds
        return s.rect.intersects(screen) ? s.rect : nil
    }
}

private struct FlightTabKey: EnvironmentKey { static let defaultValue: Router.Tab? = nil }
extension EnvironmentValues {
    /// the tab a view lives in (set by each tab's root), so a cover's place belongs to its tab
    var flightTab: Router.Tab? {
        get { self[FlightTabKey.self] }
        set { self[FlightTabKey.self] = newValue }
    }
}

@MainActor
final class Flight: ObservableObject {
    static let shared = Flight()
    /// the cover in the library hidden while its copy flies home
    @Published var hiddenSource: String?
    /// the cover at the top of the page hidden while its copy flies there
    @Published var hiddenHero: String?
    /// the page whose content waits to rise in, and whether it has
    @Published var arriving: String?
    @Published var risen = true
    private var running = false

    // the web's timing: 640 ms forwards, 540 back; EASE_MOVE forwards, EASE_OUT back
    private static let openDuration = 0.64, closeDuration = 0.54

    private var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.compactMap(\.keyWindow).first
    }

    /// Opens a book's page; with the flight when its cover is on screen, otherwise the plain way.
    func open(_ id: String, push: @escaping () -> Void) {
        guard !running, let win = window, let src = CoverFrames.shared.visible(id), !UIAccessibility.isReduceMotionEnabled,
              let shot = win.snapshotView(afterScreenUpdates: false),
              let cover = win.resizableSnapshotView(from: src, afterScreenUpdates: false, withCapInsets: .zero) else {
            push()
            return
        }
        running = true
        let layer = FlightLayer(frame: win.bounds)
        layer.addSubview(shot)
        cover.frame = src
        cover.layer.cornerRadius = 10
        cover.clipsToBounds = true
        layer.addSubview(cover)
        win.addSubview(layer)

        // the page goes in under the picture, without the system's slide, its cover and content held back
        hiddenHero = id
        arriving = id
        risen = false
        UIView.setAnimationsEnabled(false)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { push() }
        DispatchQueue.main.async { UIView.setAnimationsEnabled(true) }

        // where the page's cover is, once the page is laid out
        waitFor("hero:" + id, tries: 24) { [weak self] target in
            guard let self = self else { return }
            let to = target ?? CGRect(x: win.bounds.width - 132, y: win.safeAreaInsets.top + 60, width: 116, height: 116 / 0.66)
            UIView.animate(withDuration: Self.openDuration * 0.55, delay: 0, options: [.curveEaseInOut]) { shot.alpha = 0 }
            let move = UIViewPropertyAnimator(duration: Self.openDuration, controlPoint1: CGPoint(x: 0.42, y: 0), controlPoint2: CGPoint(x: 0.16, y: 1)) {
                cover.frame = to
                cover.layer.cornerRadius = 6
            }
            move.addCompletion { _ in
                self.hiddenHero = nil
                // the real cover shows under the copy, which fades away (no pop where they differ, like the badges)
                UIView.animate(withDuration: 0.16, delay: 0.02, options: [.curveEaseOut], animations: { cover.alpha = 0 }) { _ in
                    layer.removeFromSuperview()
                    self.arriving = nil
                    self.running = false
                }
            }
            move.startAnimation()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDuration * 0.38) {
                withAnimation(.timingCurve(0.42, 0, 0.16, 1, duration: Self.openDuration * 0.62)) { self.risen = true }
            }
        }
    }

    /// Back from a book's page; the cover flies home when its place in the library is known.
    func close(_ id: String, pop: @escaping () -> Void) {
        guard !running, let win = window, let hero = CoverFrames.shared.spots["hero:" + id]?.rect,
              hero.intersects(win.bounds), let home = CoverFrames.shared.spots[id]?.rect, !UIAccessibility.isReduceMotionEnabled,
              let shot = win.snapshotView(afterScreenUpdates: false),
              let cover = win.resizableSnapshotView(from: hero, afterScreenUpdates: false, withCapInsets: .zero) else {
            pop()
            return
        }
        running = true
        let layer = FlightLayer(frame: win.bounds)
        layer.addSubview(shot)
        cover.frame = hero
        cover.layer.cornerRadius = 6
        cover.clipsToBounds = true
        layer.addSubview(cover)
        win.addSubview(layer)

        hiddenSource = id
        UIView.setAnimationsEnabled(false)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { pop() }
        DispatchQueue.main.async { UIView.setAnimationsEnabled(true) }

        // the library's cover may have moved a little since (the carousel settles): its place now, if known
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self = self else { return }
            let to = CoverFrames.shared.spots[id]?.rect ?? home
            UIView.animate(withDuration: Self.closeDuration * 0.6, delay: 0, options: [.curveEaseOut]) { shot.alpha = 0 }
            // a soft start (the web's EASE_OUT starts so fast it looks like a jump), a gentle landing
            let move = UIViewPropertyAnimator(duration: Self.closeDuration, controlPoint1: CGPoint(x: 0.3, y: 0.55), controlPoint2: CGPoint(x: 0.2, y: 1)) {
                cover.frame = to
                cover.layer.cornerRadius = 10
            }
            move.addCompletion { _ in
                self.hiddenSource = nil
                UIView.animate(withDuration: 0.16, delay: 0.02, options: [.curveEaseOut], animations: { cover.alpha = 0 }) { _ in
                    layer.removeFromSuperview()
                    self.running = false
                }
            }
            move.startAnimation()
        }
    }

    private func waitFor(_ key: String, tries: Int, then: @escaping (CGRect?) -> Void) {
        if let r = CoverFrames.shared.spots[key]?.rect, r.width > 8 { then(r); return }
        guard tries > 0 else { then(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { self.waitFor(key, tries: tries - 1, then: then) }
    }
}

/// The flight's own layer: it takes the touches while the cover flies, so nothing is tapped twice.
private final class FlightLayer: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("no storyboard") }
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

private struct FlightHidden: ViewModifier {
    let id: String
    let hero: Bool
    @ObservedObject private var flight = Flight.shared
    func body(content: Content) -> some View {
        content.opacity((hero ? flight.hiddenHero : flight.hiddenSource) == id ? 0 : 1)
    }
}

private struct FlightArrive: ViewModifier {
    let id: String
    @ObservedObject private var flight = Flight.shared
    func body(content: Content) -> some View {
        let waiting = flight.arriving == id && !flight.risen
        content.opacity(waiting ? 0 : 1).offset(y: waiting ? 36 : 0)
    }
}

extension View {
    /// A cover a book's page can open from (and fly back to).
    func coverSpot(_ bookID: String) -> some View { modifier(CoverSpot(id: bookID)).modifier(FlightHidden(id: bookID, hero: false)) }
    /// The cover at the top of a book's page.
    func heroSpot(_ bookID: String) -> some View { modifier(CoverSpot(id: "hero:" + bookID)).modifier(FlightHidden(id: bookID, hero: true)) }
    /// A page's content below its cover: it rises in as the cover lands.
    func flightArrive(_ bookID: String) -> some View { modifier(FlightArrive(id: bookID)) }
}
