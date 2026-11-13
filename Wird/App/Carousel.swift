import SwiftUI
import UIKit
import QuartzCore

/// The carousel's position, moved by a spring (02-library.js: stiffness 240, damping 2√k·0.96), so a flick glides and
/// settles on a book the way the web app's did.
@MainActor
final class CarouselState: NSObject, ObservableObject {
    static let shared = CarouselState()

    @Published var pos: Double = 0
    @Published private(set) var centerID: String?
    var target: Double = 0
    var vel: Double = 0
    var dragging = false
    private(set) var ids: [String] = []
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    var count: Int { ids.count }
    var wraps: Bool { count >= 3 }

    /// The books shown; keeps the one in the middle if it is still there, else starts at the last one read.
    func setBooks(_ list: [String], start: String?) {
        guard list != ids else { return }
        let keep = centerID.flatMap { list.firstIndex(of: $0) } ?? start.flatMap { list.firstIndex(of: $0) } ?? 0
        ids = list
        pos = Double(keep); target = pos; vel = 0
        updateCenter(haptic: false)
    }

    func index(_ p: Double) -> Int {
        guard count > 0 else { return 0 }
        let r = Int(p.rounded())
        return wraps ? ((r % count) + count) % count : min(max(r, 0), count - 1)
    }

    /// How far a book is from the middle, in books (negative before it), going round when there are 3 or more.
    func offset(_ i: Int) -> Double {
        var o = Double(i) - pos
        if wraps {
            let n = Double(count)
            o = o.truncatingRemainder(dividingBy: n)
            if o < 0 { o += n }
            if o > n / 2 { o -= n }
        }
        return o
    }

    func go(to t: Double) {
        target = wraps ? t : min(max(t, 0), Double(max(0, count - 1)))
        run()
    }

    /// Moves to a book by its index, the short way round.
    func go(index i: Int) { go(to: pos + offset(i)) }

    func dragTo(_ p: Double) {
        if !wraps {
            let maxP = Double(max(0, count - 1))
            if p < 0 { pos = p * 0.35 } else if p > maxP { pos = maxP + (p - maxP) * 0.35 } else { pos = p }
        } else {
            pos = p
        }
        updateCenter(haptic: true)
    }

    func run() {
        guard link == nil else { return }
        last = 0
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() { link?.invalidate(); link = nil }

    @objc private func frame(_ l: CADisplayLink) {
        let dt = last == 0 ? 1.0 / 60 : min(0.034, l.timestamp - last)
        last = l.timestamp
        guard !dragging else { return }
        if UIAccessibility.isReduceMotionEnabled {
            pos = target; vel = 0
        } else {
            let k = 240.0, d = 2 * sqrt(k) * 0.96
            vel += ((target - pos) * k - vel * d) * dt
            pos += vel * dt
            if abs(target - pos) < 0.0008 && abs(vel) < 0.006 { pos = target; vel = 0 }
        }
        updateCenter(haptic: true)
        if pos == target && vel == 0 { stop() }
    }

    private func updateCenter(haptic: Bool) {
        guard count > 0 else { centerID = nil; return }
        let id = ids[index(pos)]
        if id != centerID {
            if haptic && centerID != nil { Haptics.play("sel") }
            centerID = id
            CarouselCenter.shared.id = id
        }
    }
}

/// Only the book in the middle (the library header and the band follow it, not every frame of the movement).
@MainActor
final class CarouselCenter: ObservableObject {
    static let shared = CarouselCenter()
    @Published var id: String?
}

/// The books as covers side by side: the middle one large, the others peeking from behind it (stack) or turned
/// away (flow). Swipe sideways to move, tap the middle one or swipe up to open it.
struct CarouselView: View {
    let books: [Book]
    let ns: Namespace.ID
    @Binding var sheet: LibraryView.LibSheet?
    @ObservedObject private var car = CarouselState.shared
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var axis: Character = " "
    @State private var startPos: Double = 0
    @State private var lastX: CGFloat = 0
    @State private var lastT: Date = .distantPast
    @State private var speed: Double = 0

    private var flow: Bool { lib.state.settings.carStyle == "flow" }

    var body: some View {
        GeometryReader { g in
            let W = g.size.width
            let infoH: CGFloat = 196
            let coverH = floor(max(130, min(g.size.height * 0.64, (W * 0.6) / 0.68, g.size.height - infoH - 30)))
            VStack(spacing: 14) {
                stage(W: W, coverH: coverH)
                    .frame(width: W, height: coverH)
                    .padding(.top, max(10, min(26, (g.size.height - coverH - infoH) * 0.3)))
                if let b = lib.state.book(car.centerID ?? "") {
                    info(b).id(b.id).transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.2), value: car.centerID)
        }
        .onAppear { sync() }
        .onChange(of: books.map(\.id)) { _ in sync() }
    }

    private func sync() {
        car.setBooks(books.map(\.id), start: lib.state.lastBookId())
    }

    // MARK: the covers

    private func stage(W: CGFloat, coverH: CGFloat) -> some View {
        let R = flow ? 4.9 : 3.05
        let tilt = flow ? min(12, max(-12, -car.vel * 4)) : 0
        // every card is placed first, then drawn in depth order (the middle one last, on top)
        // positions come from the carousel's own list, so a card and the words under it always agree
        let at = Dictionary(car.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let cards: [(i: Int, b: Book, p: Place, show: Bool)] = books.enumerated().map { n, b in
            let i = at[b.id] ?? n
            let o = car.offset(i)
            let cw = coverH * b.coverAspect
            let p = flow ? flowPlace(o, W: W, tilt: tilt) : stackPlace(o, cw: cw, W: W)
            return (i, b, p, abs(o) <= R)
        }.sorted { $0.p.z < $1.p.z }
        return ZStack {
            ForEach(cards, id: \.b.id) { c in
                CarouselCard(book: c.b, height: coverH, place: c.p, ns: ns)
                    .opacity(c.show ? c.p.op : 0)
                    .allowsHitTesting(c.show)
                    .onTapGesture {
                        if abs(car.offset(c.i)) < 0.5 { OpenBook.open(c.b) } else { car.go(index: c.i) }
                    }
                    .accessibilityHidden(!c.show)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(width: W, height: coverH)
        .contentShape(Rectangle())
        .gesture(drag(W: W, coverH: coverH))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("مكتبتك: اسحب يمين ويسار للتنقل، واسحب للأعلى للتفاصيل")
    }


    /// side books behind the middle one, smaller and darker (02-library.js stackL)
    private func stackPlace(_ o: Double, cw: CGFloat, W: CGFloat) -> Place {
        let S: [Double] = [1, 0.77, 0.7, 0.64], D: [Double] = [0, 0.1, 0.2, 0.38]
        let ab = abs(o), a = min(ab, 3), sg: Double = o > 0 ? 1 : (o < 0 ? -1 : 0)
        let s1 = Double(W) * 0.085, s2 = Double(W) * 0.05, s3 = Double(W) * 0.035, c = Double(cw)
        let X = [0, 0.115 * c + s1, 0.15 * c + s1 + s2, 0.18 * c + s1 + s2 + s3]
        let i = min(2, Int(a.rounded(.down))), f = a - Double(i)
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        return Place(x: CGFloat(-sg * lerp(X[i], X[i + 1])), scale: CGFloat(lerp(S[i], S[i + 1])), rot: 0, z: 100 - ab * 10,
                     dim: lerp(D[i], D[i + 1]), op: ab < 2.2 ? 1 : max(0, (3 - ab) / 0.8))
    }

    /// side covers turned away like a shelf of records (02-library.js flowL)
    private func flowPlace(_ o: Double, W: CGFloat, tilt: Double) -> Place {
        let a = abs(o), sg: Double = o > 0 ? 1 : (o < 0 ? -1 : 0), m = min(a, 1), e = max(0, a - 1)
        return Place(x: CGFloat(-sg * Double(W) * (0.25 * m + 0.105 * e)), scale: CGFloat(1 - 0.16 * m - 0.02 * e), rot: sg * m * 58 + tilt * 0.5,
                     z: 100 - a * 10, dim: min(0.7, 0.3 * m + 0.08 * e), op: a > 4.3 ? max(0, (4.9 - a) / 0.6) : 1)
    }

    private func step(W: CGFloat, coverH: CGFloat) -> Double {
        let cw = Double(coverH) * 0.66
        return flow ? Double(W) * 0.25 : max(60, (0.115 * cw + Double(W) * 0.085) * 1.5)
    }

    private func drag(W: CGFloat, coverH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                if axis == " " {
                    axis = abs(dx) > abs(dy) * 1.15 ? "x" : (dy < 0 ? "y" : "n")
                    startPos = car.pos
                    car.dragging = axis == "x"
                    lastX = dx; lastT = Date(); speed = 0
                }
                guard axis == "x" else { return }
                let now = Date(), dt = max(0.001, now.timeIntervalSince(lastT))
                speed = 0.6 * speed + 0.4 * (Double(dx - lastX) / step(W: W, coverH: coverH) / dt)
                lastX = dx; lastT = now
                car.dragTo(startPos + Double(dx) / step(W: W, coverH: coverH))
                car.vel = speed
            }
            .onEnded { v in
                defer { axis = " "; car.dragging = false }
                if axis == "x" {
                    var p = car.pos
                    if abs(speed) > 1.5 { p += speed * 0.14 }
                    let base = startPos.rounded()
                    car.go(to: min(base + 4, max(base - 4, p.rounded())))
                } else if axis == "y" {
                    if v.translation.height < -50 || v.predictedEndTranslation.height < -160,
                       let b = lib.state.book(car.centerID ?? "") { OpenBook.open(b) }
                }
            }
    }

    // MARK: the words under the middle book

    private func info(_ b: Book) -> some View {
        let st = lib.state
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(st.statusText(b)).font(JFont.body(13.5, .medium)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                Spacer()
                if !b.isNovel {
                    Button { sheet = .progress(b.id) } label: {
                        HStack(spacing: 6) {
                            Text(b.shortPos).font(JFont.body(12.5, .medium)).foregroundStyle(Color(L.ink2)).monospacedDigit()
                                .environment(\.layoutDirection, .leftToRight)
                            ProgressRing(value: b.pct, size: 24)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("تحديث التقدم")
                }
            }
            Text(b.title).font(JFont.display(26, .bold)).foregroundStyle(Color(L.ink)).lineLimit(2).minimumScaleFactor(0.8)
            Text(b.author.isEmpty ? " " : "بقلم " + b.author).font(JFont.body(14.5)).foregroundStyle(Color(L.ink2)).lineLimit(1)
            Text(metaLine(b)).font(JFont.body(13)).foregroundStyle(Color(L.ink2)).lineLimit(1)
            HStack(spacing: 10) {
                Button { Actions.read(b) } label: {
                    Text(st.readLabel(b)).frame(maxWidth: .infinity)
                }
                .buttonStyle(JButtonStyle(look: L, primary: true))
                square("plus", "أضف اقتباسًا أو فكرة أو شخصية أو كلمة") { sheet = .note(b.id) }
                square("pencil", "تعديل معلومات الكتاب") { Flows.editBook(b.id) }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
    }

    private func metaLine(_ b: Book) -> String {
        var parts = [b.format.label + (b.series ? " · " + Words.cnt(Double(b.volumes.count), Words.vols) : "")]
        let g = b.genres.prefix(2).joined(separator: "، ")
        if !g.isEmpty { parts.append(g) }
        return parts.joined(separator: " · ")
    }

    private func square(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(Color(L.primary))
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.primary).opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Where a card sits: across, its size, its turn, its depth, its shade, its fade.
struct Place { var x: CGFloat; var scale: CGFloat; var rot: Double; var z: Double; var dim: Double; var op: Double }

/// One cover of the carousel.
struct CarouselCard: View {
    let book: Book
    let height: CGFloat
    let place: Place
    let ns: Namespace.ID

    var body: some View {
        BookCover(book: book, radius: 11)
            .frame(width: height * book.coverAspect, height: height)
            .overlay(Color.black.opacity(place.dim).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)))
            .zoomSource(book.id, ns)
            .shadow(color: .black.opacity(0.55), radius: 14, y: 12)
            .rotation3DEffect(.degrees(place.rot), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .scaleEffect(place.scale)
            .offset(x: place.x)
            .accessibilityElement()
            .accessibilityLabel(book.title)
            .accessibilityAddTraits(.isButton)
    }
}

/// The soft colour behind the carousel: the middle book's cover, blurred and darkened, fading into the page.
struct CarouselBand: View {
    let book: Book?
    @Environment(\.look) private var L

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Color(L.bg)
                ZStack {
                    if let b = book {
                        Color(UIColor.hslParts(b.hslString) ?? L.primary)
                        if let img = Library.shared.image(b.cover) {
                            Image(uiImage: img).resizable().scaledToFill().blur(radius: 34).opacity(0.9)
                        }
                    }
                    Color.black.opacity(0.42)
                }
                .frame(width: g.size.width, height: g.size.height * 0.62)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .id(book?.id)
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: book?.id)
        }
        .ignoresSafeArea()
    }
}

/// What a book's main button does.
@MainActor
enum Actions {
    static func read(_ b: Book) {
        if let n = b.novel {
            NovelBridge.openReader(novel: n.novelID, book: b.id, index: nil, chapter: nil, paragraph: nil)
        } else {
            Flows.startRead(b.id)
        }
    }
}
