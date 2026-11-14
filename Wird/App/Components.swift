import SwiftUI
import UIKit

// Jalees's own pieces (web/style.css, inventory-3 section 7.8), shared by every screen.

// MARK: - covers

/// A book's cover: its picture, or one drawn in the book's colour with its title and author (the web's genCover).
struct BookCover: View {
    let book: Book
    var radius: CGFloat = 8
    /// the small marks on the cover the owner turned on (progress, stars, format badge, novels' unread count)
    var marks = true
    @ObservedObject private var lib = Library.shared

    var body: some View {
        let s = lib.state.settings.show
        ZStack {
            Generated(book: book)
            if let img = lib.image(book.cover) {
                Image(uiImage: img).resizable().scaledToFill()
            }
            if marks { overlays(s) }
        }
        .aspectRatio(book.coverAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder private func overlays(_ s: JSONObject) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if let n = book.novel, !n.isEpub, n.unread > 0 {
                    Text("\(n.unread)").font(JFont.body(11, .semibold)).monospacedDigit()
                        .foregroundStyle(Color(Appearance.shared.look.onPrimary))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color(Appearance.shared.look.primary)))
                        .padding(5)
                }
                Spacer()
                if s.bool("badge"), book.format == .audio || book.format == .ebook {
                    Image(systemName: book.format == .audio ? "headphones" : "ipad")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Circle().fill(Color.black.opacity(0.55))).padding(5)
                }
            }
            Spacer()
            if s.bool("stars"), book.rating > 0 {
                Text(Words.stars(book.rating)).font(.system(size: 10)).foregroundStyle(Color(hex: "#ffd36b"))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.black.opacity(0.5))).padding(.bottom, 6)
            }
            if s.bool("prog"), book.status == .reading, let p = book.pct {
                GeometryReader { g in
                    ZStack(alignment: .trailing) {
                        Rectangle().fill(Color.black.opacity(0.35))
                        Rectangle().fill(Color(Appearance.shared.look.primary)).frame(width: g.size.width * p)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    /// The drawn cover: a gradient of the book's colour, a thin inner frame, its title and author.
    struct Generated: View {
        let book: Book
        var body: some View {
            let c = UIColor.hslParts(book.hslString) ?? UIColor(hex: "#2f5c53")
            ZStack {
                // solid underneath, so nothing behind ever shows through
                Color(c)
                LinearGradient(colors: [Color.white.opacity(0.1), Color.black.opacity(0.14)], startPoint: .top, endPoint: .bottom)
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.22), lineWidth: 1).padding(7)
                GeometryReader { g in
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text(book.title).font(JFont.display(max(11, g.size.width * 0.13), .semibold)).foregroundStyle(.white)
                            .multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.6)
                        Spacer(minLength: 0)
                        if !book.author.isEmpty {
                            Text(book.author).font(JFont.body(max(8, g.size.width * 0.075))).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, g.size.width * 0.1)
                    .padding(.vertical, g.size.width * 0.12)
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
        }
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex)) }
}

// MARK: - sheets

/// A sheet in Jalees's style: a header with the close button, the title, and an optional action on the other side.
struct JSheet<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var action: (label: String, run: () -> Void)? = nil
    /// asks first instead of closing (unsaved text)
    var onClose: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { if let c = onClose { c() } else { dismiss() } } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(L.ink))
                        .frame(width: 36, height: 36).background(Circle().fill(Color(L.surface2)))
                }
                .buttonStyle(.plain).accessibilityLabel("إغلاق")
                Spacer(minLength: 0)
                VStack(spacing: 1) {
                    Text(title).font(JFont.display(19, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1)
                    if let s = subtitle, !s.isEmpty { Text(s).font(JFont.body(13)).foregroundStyle(Color(L.ink2)).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if let a = action {
                    Button(a.label, action: a.run).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.onPrimary))
                        .padding(.horizontal, 14).frame(height: 36).background(Capsule().fill(Color(L.primary))).buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.horizontal, 18).padding(.bottom, 26)
            }
        }
        .background(Color(L.surface).ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }
}

/// A row in a menu sheet: an icon, a title, a line under it, and a check when chosen.
struct JMenuRow: View {
    let icon: String
    let title: String
    var sub: String? = nil
    var count: Int? = nil
    var checked = false
    var danger = false
    let action: () -> Void
    @Environment(\.look) private var L

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Color(danger ? L.danger : L.primary)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(JFont.body(16, .medium)).foregroundStyle(Color(danger ? L.danger : L.ink))
                    if let s = sub, !s.isEmpty { Text(s).font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
                }
                Spacer()
                if let c = count { Text("\(c)").font(JFont.body(14)).foregroundStyle(Color(L.ink2)).monospacedDigit() }
                if checked { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(L.primary)) }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
    }
}

/// .seg: equal parts in a rounded box, the chosen one filled.
struct JSeg<V: Hashable>: View {
    let options: [(V, String)]
    @Binding var value: V
    @Environment(\.look) private var L

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                Button { value = o.0; Haptics.play("sel") } label: {
                    Text(o.1).font(JFont.body(14.5, value == o.0 ? .medium : .regular)).lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(Color(value == o.0 ? L.onPrimary : L.ink))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(value == o.0 ? Color(L.primary) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(value == o.0 ? [.isSelected] : [])
                if i < options.count - 1 { Rectangle().fill(Color(L.line)).frame(width: 1) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }
}

/// .sw: a row with a label (and a line under it) and a switch.
struct JSwitchRow: View {
    let title: String
    var sub: String? = nil
    @Binding var on: Bool
    @Environment(\.look) private var L

    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(JFont.body(15.5)).foregroundStyle(Color(L.ink))
                if let s = sub { Text(s).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)) }
            }
        }
        .tint(Color(L.primary))
        .frame(minHeight: 48)
    }
}

/// A group title inside a sheet.
struct JLabel: View {
    let text: String
    @Environment(\.look) private var L
    var body: some View { Text(text).font(JFont.body(13.5, .medium)).foregroundStyle(Color(L.ink2)) }
}

/// .panel
struct JPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.look) private var L
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }
}

/// Five stars to tap: a star, its half, or none.
struct JStars: View {
    @Binding var value: Double
    var size: CGFloat = 26
    @Environment(\.look) private var L
    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { i in
                // a tap: that many stars; the same star again: half of it; once more: none (half stars, س64)
                Button {
                    let d = Double(i)
                    value = value == d ? d - 0.5 : (value == d - 0.5 ? 0 : d)
                    Haptics.play("sel")
                } label: {
                    Image(systemName: Double(i) <= value ? "star.fill" : (Double(i) - 0.5 <= value ? "star.leadinghalf.filled" : "star")).font(.system(size: size * 0.8))
                        .foregroundStyle(Color(Double(i) - 0.5 <= value ? L.star : L.line)).frame(width: size, height: size)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(i) نجوم")
            }
        }
    }
}

/// The small progress ring beside a book's status.
struct ProgressRing: View {
    let value: Double?
    var size: CGFloat = 26
    @Environment(\.look) private var L
    var body: some View {
        ZStack {
            Circle().stroke(Color(L.surface2), lineWidth: 3)
            Circle().trim(from: 0, to: value ?? 0).stroke(Color(L.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - toasts (with undo)

/// The web app's toast: a dark pill above the tab bar; with an undo button and a shrinking bar when something can be undone.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let undo: Bool
        let achievement: Bool
        let seconds: Double
        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }
    @Published private(set) var current: Item?
    private var queue: [Item] = []
    private var undoRun: (() -> Void)?
    private var timer: DispatchWorkItem?

    func show(_ text: String, achievement: Bool = false, undo: (() -> Void)? = nil) {
        let it = Item(text: text, undo: undo != nil, achievement: achievement, seconds: undo != nil ? 5.2 : (achievement ? 3.4 : 2.4))
        if undo != nil {
            undoRun = undo
            // an undo goes first; a plain message showing now is cut short, an achievement waits its turn
            if let c = current, c.achievement { queue.insert(c, at: 0) }
            queue.insert(it, at: 0)
            next()
            return
        }
        queue.append(it)
        if current == nil { next() }
    }

    func doUndo() {
        let f = undoRun
        undoRun = nil
        f?()
        show("تم التراجع")
        next()
    }

    private func next() {
        timer?.cancel()
        guard !queue.isEmpty else { withAnimation(.easeOut(duration: 0.2)) { current = nil }; return }
        let it = queue.removeFirst()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { current = it }
        let w = DispatchWorkItem { [weak self] in
            if self?.current?.undo == true { self?.undoRun = nil }
            self?.next()
        }
        timer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + it.seconds, execute: w)
    }
}

struct ToastView: View {
    @ObservedObject private var center = ToastCenter.shared
    @Environment(\.look) private var L
    @State private var progress: CGFloat = 1

    var body: some View {
        if let t = center.current {
            HStack(spacing: 12) {
                if t.achievement { Image(systemName: "trophy.fill").foregroundStyle(Color(hex: "#ffe6b0")) }
                Text(t.text).font(JFont.body(14.5, .medium)).foregroundStyle(t.achievement ? Color(hex: "#ffe6b0") : Color(L.bg)).lineLimit(2)
                if t.undo {
                    Spacer(minLength: 0)
                    Button("تراجع") { center.doUndo() }.font(JFont.body(14.5, .bold)).foregroundStyle(Color(L.primary.withAlphaComponent(1))).buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18).frame(minHeight: 46)
            .background {
                Capsule().fill(t.achievement ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "#3a2a0c"), Color(hex: "#5a3f10")], startPoint: .leading, endPoint: .trailing))
                               : AnyShapeStyle(Color(L.ink)))
            }
            .overlay(alignment: .bottom) {
                if t.undo {
                    GeometryReader { g in Capsule().fill(Color(L.accent)).frame(width: g.size.width * progress, height: 3) }
                        .frame(height: 3).padding(.horizontal, 22)
                }
            }
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
            .onAppear {
                progress = 1
                if t.undo { withAnimation(.linear(duration: t.seconds)) { progress = 0 } }
            }
        }
    }
}

extension View {
    /// Pages without a navigation bar: the status bar area takes the page colour, so lines scrolling under the clock
    /// don't show through it.
    func statusBarBackdrop(_ c: Color) -> some View {
        overlay(alignment: .top) { c.opacity(0.96).frame(height: 0).ignoresSafeArea(edges: .top) }
    }
}

/// The web app's splash (07-app.js, style.css .splash): the name, the verse and its poet, for 1.7 s (0.45 s with
/// reduced motion), then a fade; a tap skips it.
struct SplashView: View {
    let done: () -> Void
    @Environment(\.look) private var L
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    @State private var leaving = false

    var body: some View {
        ZStack {
            Color(L.bg).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("جَليس").font(JFont.display(58, .bold)).foregroundStyle(Color(L.primary))
                    .scaleEffect(shown || reduce ? 1 : 0.9).opacity(shown || reduce ? 1 : 0)
                    .animation(reduce ? nil : .timingCurve(0.2, 0.9, 0.25, 1.1, duration: 0.7), value: shown)
                Text("وخيرُ جليسٍ في الزمانِ كتابُ").font(JFont.quote(21)).foregroundStyle(Color(L.ink).opacity(0.85))
                    .offset(y: shown || reduce ? 0 : 10).opacity(shown || reduce ? 1 : 0)
                    .animation(reduce ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6).delay(0.35), value: shown)
                Text("المتنبي").font(JFont.body(12)).foregroundStyle(Color(L.ink2))
                    .offset(y: shown || reduce ? 0 : 10).opacity(shown || reduce ? 1 : 0)
                    .animation(reduce ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6).delay(0.5), value: shown)
            }
            .padding(24)
            .scaleEffect(leaving ? 1.04 : 1)
        }
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { leave() }
        .onAppear {
            shown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0.45 : 1.7)) { leave() }
        }
        .accessibilityHidden(true)
    }

    private func leave() {
        guard !leaving else { return }
        withAnimation(.easeOut(duration: 0.5)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { done() }
    }
}

/// Ends typing first (a number field hands over its value only when editing ends), then runs the action: so tapping
/// «حفظ» right after typing a page count saves that count.
@MainActor func afterEditing(_ f: @escaping () -> Void) {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { f() }
}

/// Spoilers in your own notes and reviews (answers-round2 س64): blurred, with a line saying so, until tapped; only when
/// «إخفاء الحرق» is on in the settings.
private struct SpoilerCover: ViewModifier {
    let on: Bool
    @State private var shown = false
    @Environment(\.look) private var L
    func body(content: Content) -> some View {
        if on && !shown && Library.shared.state.settings.raw.bool("spoilers", true) {
            content
                .blur(radius: 8)
                .overlay {
                    Label("فيه حرق، اضغط لتشوفه", systemImage: "eye.slash").font(JFont.body(13.5, .medium)).foregroundStyle(Color(L.ink))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color(L.surface2)))
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

extension View {
    func spoiler(_ on: Bool) -> some View { modifier(SpoilerCover(on: on)) }
}
