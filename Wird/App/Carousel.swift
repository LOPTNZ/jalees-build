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
        // a drag that was cut off (a sheet came up) never said it ended: moving on our own ends it
        dragging = false
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
        // while a finger moves it nothing runs here; the display link stops until the drag ends (go starts it again)
        if dragging { stop(); return }
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
            // the covers next to the middle one are decoded in the background before they slide in
            let near = (-5...5).map { ids[((index(pos) + $0) % ids.count + ids.count) % ids.count] }
            Library.shared.prefetch(near.compactMap { Library.shared.state.book($0)?.cover })
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
                    .gesture(drag(W: W, coverH: coverH, H: g.size.height))
                // only the words fade between books: an animation on the whole column would also slow the covers
                // every time the middle book changes
                VStack(spacing: 0) {
                    if let b = lib.state.book(car.centerID ?? "") {
                        info(b).id(b.id).transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: car.centerID)
                // the words under the cover take the same swipes (Bookly: up anywhere opens the book)
                .contentShape(Rectangle())
                .gesture(drag(W: W, coverH: coverH, H: g.size.height))
                Spacer(minLength: 0)
            }
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
        }.filter { $0.show }.sorted { $0.p.z < $1.p.z }   // only the covers near the middle are built, however many books there are
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

    private func drag(W: CGFloat, coverH: CGFloat, H: CGFloat) -> some Gesture {
        // the distance a finger travels to open the page all the way (the web's D: clamp(H × 0.42, 220, 360))
        let D = min(360, max(220, H * 0.42))
        return DragGesture(minimumDistance: 8)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                if axis == " " {
                    axis = abs(dx) > abs(dy) * 1.15 ? "x" : (dy < 0 ? "y" : "n")
                    startPos = car.pos
                    car.dragging = axis == "x"
                    lastX = dx; lastT = Date(); speed = 0
                    if axis == "y" {
                        // up: the book layer starts, with the middle book
                        if let id = car.centerID, BookLayer.shared.beginBook(id) {} else { axis = "n" }
                    }
                }
                if axis == "y" { BookLayer.shared.drag(-dy / D); return }
                guard axis == "x" else { return }
                car.dragging = true
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
                    // let go past 30 %, or flicked up: the page; otherwise back to the library
                    let p = -v.translation.height / D
                    BookLayer.shared.release(open: p > 0.3 || v.predictedEndTranslation.height < -D * 0.75)
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
            .shadow(color: .black.opacity(0.55), radius: 14, y: 12)
            .rotation3DEffect(.degrees(place.rot), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .scaleEffect(place.scale)
            .offset(x: place.x)
            .coverSpot(book.id)
            .accessibilityElement()
            .accessibilityLabel(book.title)
            .accessibilityAddTraits(.isButton)
    }
}

/// The soft colour behind the carousel: the middle book's cover, blurred and darkened, fading into the page.
struct CarouselBand: View {
    let book: Book?
    @Environment(\.look) private var L
    /// the band made after the book reached the middle (normally it is ready before: Library.prefetch)
    @State private var made: (id: String, image: UIImage)?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Color(L.bg)
                ZStack {
                    if let b = book {
                        Color(UIColor.hslParts(b.hslString) ?? L.primary)
                        if let img = Library.shared.cachedSoft(b.cover) ?? (made?.id == b.cover ? made?.image : nil) {
                            Image(uiImage: img).resizable().interpolation(.medium).scaledToFill().opacity(0.9)
                        }
                    }
                    Color.black.opacity(0.42)
                }
                .frame(width: g.size.width, height: g.size.height * 0.62)
                .clipped()
                // fades into the page's colour (the same look as a mask over it, without a mask's extra pass per frame)
                .overlay(LinearGradient(stops: [.init(color: Color(L.bg).opacity(0), location: 0.62), .init(color: Color(L.bg), location: 1)],
                                        startPoint: .top, endPoint: .bottom))
                .id(book?.id)
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: book?.id)
            .animation(.easeInOut(duration: 0.25), value: made?.id)
        }
        .ignoresSafeArea()
        .task(id: book?.cover) {
            guard let c = book?.cover, !c.isEmpty, Library.shared.cachedSoft(c) == nil else { return }
            if let i = await Library.shared.softAsync(c) { made = (c, i) }
        }
    }
}

/// What a book's main button does.
@MainActor
enum Actions {
    static func read(_ b: Book) {
        if PDFBooks.isPDF(b) { PDFBooks.open(b.id); return }
        if let n = b.novel {
            NovelBridge.openReader(novel: n.novelID, book: b.id, index: nil, chapter: nil, paragraph: nil)
        } else {
            Flows.startRead(b.id)
        }
    }
}
