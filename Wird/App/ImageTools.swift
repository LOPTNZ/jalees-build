import SwiftUI
import UIKit
import PhotosUI

// Pictures for books (inventory-1, 3.2 and 3.3): choosing one (photos or camera), cropping it, and the book's size.

struct PhotoTarget: Identifiable {
    let id = UUID()
    let kind: String
}

/// «من صورك أو بالكاميرا»: a small sheet with both ways.
struct ImageSource: View {
    let target: PhotoTarget
    let done: (UIImage?) -> Void
    @Environment(\.look) private var L
    @State private var item: PhotosPickerItem?
    @State private var camera = false

    var body: some View {
        VStack(spacing: 12) {
            Text(target.kind == "spine" ? "صورة الكعب" : (target.kind == "photo" ? "صورة الشخصية" : "صورة الغلاف")).font(JFont.display(19, .semibold))
            PhotosPicker(selection: $item, matching: .images) {
                Label("من صورك", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(JButtonStyle(look: L, primary: true))
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { camera = true } label: { Label("بالكاميرا", systemImage: "camera").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
            }
            Button("إلغاء") { done(nil) }.font(JFont.body(15)).foregroundStyle(Color(L.ink2))
        }
        .padding(20)
        .presentationDetents([.height(250)])
        .onChange(of: item) { it in
            guard let it = it else { return }
            Task {
                let d = try? await it.loadTransferable(type: Data.self)
                let img = d.flatMap { UIImage(data: $0) }?.fixedOrientation().resized(maxSide: 2200)
                // a picture that can't be read (an odd format, or not downloaded from iCloud)
                if img == nil { ToastCenter.shared.show("تعذّر فتح الصورة، جرّب صورة ثانية.") }
                done(img)
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { img in camera = false; done(img?.fixedOrientation().resized(maxSide: 2200)) }.ignoresSafeArea()
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(_ d: @escaping (UIImage?) -> Void) { done = d }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}

extension UIImage {
    /// Upright pixels (camera pictures carry their turn as a flag).
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}

// MARK: - cropping

struct CropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
    let kind: String
}

/// «قص الغلاف» / «قص الكعب» / «حدد مكان الوجه»: a frame with handles over the picture; pinch to zoom, drag to move.
struct CropView: View {
    let request: CropRequest
    let done: (UIImage?) -> Void
    @Environment(\.look) private var L
    @State private var aspect: CGFloat?
    @State private var frame: CGRect = .zero
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero
    @State private var startFrame: CGRect = .zero
    @State private var fitted = false
    @State private var canvas: CGSize = .zero

    private var options: [(String, CGFloat?)] {
        let r = request.image.size.width / max(1, request.image.size.height)
        switch request.kind {
        case "spine": return [("حر", nil), ("1:6", 1 / 6), ("1:8", 1 / 8), ("1:10", 1 / 10), ("الأصلية", r)]
        case "photo": return [("دائري", 1)]
        case "ocr": return [("حر", nil), ("الصورة كاملة", r), ("سطر", r / 0.07), ("فقرة", r / 0.3)]
        default: return [("حر", nil), ("الأصلية", r), ("2:3", 2 / 3), ("3:4", 3 / 4), ("1:1", 1)]
        }
    }

    private var title: String { ["spine": "قص الكعب", "photo": "حدد مكان الوجه", "ocr": "حدد النص"][request.kind] ?? "قص الغلاف" }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { done(nil) } label: { Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40) }
                    .foregroundStyle(.white).accessibilityLabel("إلغاء")
                Spacer()
                Text(title).font(JFont.display(19, .semibold)).foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 12)
            GeometryReader { g in
                let fit = fitRect(in: g.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: request.image).resizable().frame(width: fit.width * scale, height: fit.height * scale)
                        .offset(x: fit.minX + offset.width - (fit.width * (scale - 1)) / 2, y: fit.minY + offset.height - (fit.height * (scale - 1)) / 2)
                    // the dark outside and the frame
                    Path { p in p.addRect(CGRect(origin: .zero, size: g.size)); p.addRect(frame) }
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    frameView
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(pan.simultaneously(with: zoom))
                .onAppear { canvas = g.size; if !fitted { fitted = true; frame = startRect(in: g.size, fit: fit) } }
            }
            .environment(\.layoutDirection, .leftToRight)
            if options.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(options.indices, id: \.self) { i in
                            let o = options[i]
                            Button { aspect = o.1; applyAspect() } label: {
                                Text(o.0).font(JFont.body(14, aspect == o.1 ? .semibold : .regular)).foregroundStyle(aspect == o.1 ? Color.black : .white)
                                    .padding(.horizontal, 14).frame(height: 34).background(Capsule().fill(aspect == o.1 ? Color.white : Color.white.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack(spacing: 10) {
                if request.kind != "photo" {
                    Button("بدون قص") { done(request.image) }.buttonStyle(JButtonStyle(look: L))
                }
                Button { finish() } label: { Label("تم", systemImage: "checkmark").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { if request.kind == "photo" { aspect = 1 } }
    }

    private var frameView: some View {
        ZStack {
            Group {
                if request.kind == "photo" { Circle().strokeBorder(.white, lineWidth: 1.5) } else { Rectangle().strokeBorder(.white, lineWidth: 1.5) }
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            ForEach(0..<4, id: \.self) { c in
                Circle().fill(Color(L.accent)).frame(width: 22, height: 22)
                    .position(corner(c))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in if startFrame == .zero { startFrame = frame }; resize(c, by: v.translation) }
                        .onEnded { _ in startFrame = .zero })
            }
        }
    }

    private func corner(_ c: Int) -> CGPoint {
        [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)][c]
    }

    private func resize(_ c: Int, by t: CGSize) {
        var f = startFrame
        let minS: CGFloat = 30
        switch c {
        case 0: f.origin.x += t.width; f.origin.y += t.height; f.size.width -= t.width; f.size.height -= t.height
        case 1: f.origin.y += t.height; f.size.width += t.width; f.size.height -= t.height
        case 2: f.origin.x += t.width; f.size.width -= t.width; f.size.height += t.height
        default: f.size.width += t.width; f.size.height += t.height
        }
        if let a = aspect {
            let h = f.width / a
            if c < 2 { f.origin.y = f.maxY - h }
            f.size.height = h
        }
        guard f.width >= minS, f.height >= minS else { return }
        frame = f
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) }
            .onEnded { _ in lastOffset = offset }
    }

    private var zoom: some Gesture {
        MagnificationGesture()
            .onChanged { s in scale = min(10, max(1, lastScale * s)) }
            .onEnded { _ in lastScale = scale }
    }

    private func fitRect(in size: CGSize) -> CGRect {
        let iw = request.image.size.width, ih = request.image.size.height
        let k = min(size.width / iw, size.height / ih) * 0.92
        let w = iw * k, h = ih * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func startRect(in size: CGSize, fit: CGRect) -> CGRect {
        if request.kind == "photo" {
            let s = min(fit.width, fit.height) * 0.8
            return CGRect(x: fit.midX - s / 2, y: fit.midY - s / 2, width: s, height: s)
        }
        return fit.insetBy(dx: fit.width * 0.04, dy: fit.height * 0.04)
    }

    private func applyAspect() {
        guard let a = aspect else { return }
        var f = frame
        let h = f.width / a
        if h <= frame.height { f.origin.y += (f.height - h) / 2; f.size.height = h } else { let w = f.height * a; f.origin.x += (f.width - w) / 2; f.size.width = w }
        frame = f
    }

    /// The part of the picture inside the frame, at most 1100 (cover), 1300 (spine) or 520 (face) on its long side.
    private func finish() {
        let fit = fitRect(in: canvas)
        let shown = CGRect(x: fit.minX + offset.width - (fit.width * (scale - 1)) / 2, y: fit.minY + offset.height - (fit.height * (scale - 1)) / 2,
                           width: fit.width * scale, height: fit.height * scale)
        let k = request.image.size.width / shown.width
        var r = CGRect(x: (frame.minX - shown.minX) * k, y: (frame.minY - shown.minY) * k, width: frame.width * k, height: frame.height * k)
        r = r.intersection(CGRect(origin: .zero, size: request.image.size))
        guard r.width > 4, r.height > 4, let cg = request.image.cgImage?.cropping(to: CGRect(x: r.minX * request.image.scale, y: r.minY * request.image.scale,
                                                                                               width: r.width * request.image.scale, height: r.height * request.image.scale)) else {
            done(request.image); return
        }
        let maxSide: CGFloat = request.kind == "photo" ? 520 : (request.kind == "spine" ? 1300 : (request.kind == "ocr" ? 2200 : 1100))
        done(UIImage(cgImage: cg).resized(maxSide: maxSide))
    }
}

// MARK: - the book's size on the shelf

/// «أبعاد الكتاب» (03-book.js dimsHTML): the spine and the cover standing on a plank against a centimetre ruler.
/// Drag the round handles (top: height, side: spine thickness or cover width) or the sliders, as chosen in the
/// settings; the centimetre fields work in both. Locked ratios keep the pictures from stretching.
struct DimsSheet: View {
    @ObservedObject var model: BookFormModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @ObservedObject private var lib = Library.shared
    @State private var h: Double = 21
    @State private var w: Double = 14
    @State private var t: Double = 2
    @State private var lockC = false
    @State private var lockS = false
    /// still the automatic size (nothing moved yet)
    @State private var auto = true
    @State private var loaded = false
    @State private var dragging: String?
    @State private var fields: [String: String] = [:]
    @FocusState private var focus: String?

    private static let DS: CGFloat = 5.2, DPAD: CGFloat = 22, DGAP: CGFloat = 16, DBOT: CGFloat = 16
    private static let lim: [String: ClosedRange<Double>] = ["h": 10...40, "w": 6...32, "t": 0.3...12]

    private var handles: Bool { lib.state.settings.raw.str("dimMode", "handles") == "handles" }
    private var cRatio: Double? { model.b.coverRatio.flatMap { $0 > 0 ? $0 : nil } }
    private var sRatio: Double? { model.b.spineRatio.flatMap { $0 > 0 ? $0 : nil } }
    private var locks: (c: Bool, s: Bool) { (lockC && cRatio != nil, lockS && sRatio != nil) }

    var body: some View {
        JSheet(title: "أبعاد الكتاب", action: ("حفظ", { save() })) {
            stage
            if handles {
                Text("اسحب النقاط: العلوية للارتفاع، والجانبية لسماكة الكعب أو عرض الغلاف.")
                    .font(JFont.body(13)).foregroundStyle(Color(L.ink2))
            } else {
                VStack(spacing: 4) {
                    slider("الارتفاع", "h", h)
                    slider("عرض الغلاف", "w", w)
                    slider("سماكة الكعب", "t", t)
                }
            }
            HStack(spacing: 8) {
                input("الارتفاع (سم)", "h")
                input("العرض (سم)", "w")
                input("السماكة (سم)", "t")
            }
            if cRatio != nil { JSwitchRow(title: "حافظ على نسبة صورة الغلاف", sub: "يمنع مطّ الغلاف", on: lockBinding(c: true)) }
            if sRatio != nil { JSwitchRow(title: "حافظ على نسبة صورة الكعب", sub: "يمنع مطّ الكعب", on: lockBinding(c: false)) }
            Button("رجوع للأبعاد الافتراضية") { reset() }.buttonStyle(JButtonStyle(look: L, small: true))
        }
        .onAppear(perform: load)
        .onChange(of: focus) { f in if f == nil { syncFields() } }
    }

    // MARK: the stage

    private var stage: some View {
        let DS = Self.DS, DPAD = Self.DPAD, DGAP = Self.DGAP, DBOT = Self.DBOT
        let H = 40 * DS + DBOT + 48
        return GeometryReader { geo in
            let W = geo.size.width
            let tw = CGFloat(t) * DS, hh = CGFloat(h) * DS, ww = CGFloat(w) * DS
            let spineX = W - DPAD - tw / 2, coverX = W - DPAD - tw - DGAP - ww / 2, midY = H - DBOT - hh / 2
            ZStack(alignment: .topLeading) {
                // the wall: dark wood with faint boards, and the ruler on the left
                LinearGradient(colors: [Color(hex: "#2e2119"), Color(hex: "#211812")], startPoint: .top, endPoint: .bottom)
                Canvas { ctx, size in
                    var x: CGFloat = 58
                    while x < size.width { ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(.black.opacity(0.12))); x += 60 }
                    for cm in stride(from: 0, through: 40, by: 5) {
                        let y = H - DBOT - CGFloat(cm) * DS
                        ctx.fill(Path(CGRect(x: 6, y: y, width: 8, height: 1)), with: .color(.white.opacity(0.35)))
                        if cm % 10 == 0 {
                            ctx.draw(Text("\(cm)").font(.system(size: 9)).foregroundColor(.white.opacity(0.55)), at: CGPoint(x: 18, y: y), anchor: .leading)
                        }
                    }
                }
                // the plank
                VStack(spacing: 0) {
                    Color(hex: "#9a6a43").frame(height: 3)
                    LinearGradient(colors: [Color(hex: "#6f482b"), Color(hex: "#452b19")], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: W, height: DBOT).position(x: W / 2, y: H - DBOT / 2)

                Spine(book: model.b, width: tw, height: hh)
                    .frame(width: tw, height: hh).shadow(color: .black.opacity(0.6), radius: 5, y: 6)
                    .position(x: spineX, y: midY)
                BookCover(book: model.b, radius: 2, marks: false)
                    .frame(width: ww, height: hh).shadow(color: .black.opacity(0.6), radius: 5, y: 6)
                    .position(x: coverX, y: midY)

                label(String(format: "%.1f", t)).position(x: spineX, y: H - DBOT - hh - 30)
                label(String(format: "%.1f × %.1f", w, h)).position(x: coverX, y: H - DBOT - hh - 30)

                if handles {
                    handle("h").position(x: spineX, y: H - DBOT - hh)
                    handle("t").position(x: W - DPAD - tw, y: midY)
                    handle("h").position(x: coverX, y: H - DBOT - hh)
                    handle("w").position(x: W - DPAD - tw - DGAP - ww, y: midY)
                }
            }
            .frame(width: W, height: H)
            .contentShape(Rectangle())
            .gesture(drag(W: W, H: H), including: handles ? .all : .subviews)
        }
        .frame(height: H)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "الارتفاع %.1f، العرض %.1f، السماكة %.1f سم", h, w, t))
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.8)).fixedSize()
    }

    private func handle(_ k: String) -> some View {
        Circle().fill(Color(L.accent)).overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .frame(width: 26, height: 26).shadow(color: .black.opacity(0.4), radius: 2.5, y: 1)
            .scaleEffect(dragging == k ? 1.2 : 1)
            .allowsHitTesting(false)
    }

    /// One drag on the stage takes the handle nearest to where it began (within reach), like the web's pointer capture.
    private func drag(W: CGFloat, H: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let DS = Self.DS, DPAD = Self.DPAD, DGAP = Self.DGAP, DBOT = Self.DBOT
                if dragging == nil {
                    let tw = CGFloat(t) * DS, hh = CGFloat(h) * DS, ww = CGFloat(w) * DS
                    let midY = H - DBOT - hh / 2, top = H - DBOT - hh
                    let spots: [(String, CGPoint)] = [("h", CGPoint(x: W - DPAD - tw / 2, y: top)), ("t", CGPoint(x: W - DPAD - tw, y: midY)),
                                                      ("h", CGPoint(x: W - DPAD - tw - DGAP - ww / 2, y: top)), ("w", CGPoint(x: W - DPAD - tw - DGAP - ww, y: midY))]
                    let p = g.startLocation
                    guard let best = spots.min(by: { hypot($0.1.x - p.x, $0.1.y - p.y) < hypot($1.1.x - p.x, $1.1.y - p.y) }),
                          hypot(best.1.x - p.x, best.1.y - p.y) <= 30 else { return }
                    dragging = best.0
                    Haptics.play("sel")
                }
                guard let k = dragging else { return }
                let loc = g.location
                let v: CGFloat
                switch k {
                case "h": v = (H - DBOT - loc.y) / DS
                case "t": v = (W - DPAD - loc.x) / DS
                default: v = (W - DPAD - CGFloat(t) * DS - DGAP - loc.x) / DS
                }
                set(k, Double(v))
            }
            .onEnded { _ in dragging = nil; syncFields() }
    }

    // MARK: sliders and fields

    private func slider(_ title: String, _ k: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(JFont.body(15)).foregroundStyle(Color(L.ink))
                Spacer()
                Text(String(format: "%.1f سم", v)).font(JFont.body(13)).monospacedDigit().foregroundStyle(Color(L.ink2))
            }
            Slider(value: Binding(get: { v }, set: { set(k, ($0 * 10).rounded() / 10); syncFields() }), in: Self.lim[k]!, step: 0.1)
                .tint(Color(L.primary))
        }
    }

    private func input(_ title: String, _ k: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(JFont.body(11.5, .medium)).foregroundStyle(Color(L.ink2)).lineLimit(1).minimumScaleFactor(0.8)
            TextField("", text: Binding(get: { fields[k] ?? "" }, set: { s in
                fields[k] = s
                let v = Double(s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "٫", with: "."))
                if let v = v, v >= Self.lim[k]!.lowerBound { set(k, v) }
            }))
            .keyboardType(.decimalPad).focused($focus, equals: k)
            .multilineTextAlignment(.center).font(JFont.body(16)).monospacedDigit().foregroundStyle(Color(L.ink))
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        }
    }

    private func lockBinding(c: Bool) -> Binding<Bool> {
        Binding(get: { c ? locks.c : locks.s }, set: { v in
            if c { lockC = v } else { lockS = v }
            if v { set("h", h, keep: true); syncFields() }
        })
    }

    // MARK: the rules (setDim)

    private func clampTo(_ k: String, _ v: Double) -> Double { min(Self.lim[k]!.upperBound, max(Self.lim[k]!.lowerBound, v)) }
    private func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private func set(_ k: String, _ value: Double, keep: Bool = false) {
        let lk = locks
        let v = clampTo(k, value)
        var nh = h
        if k == "h" { nh = v } else if k == "w", lk.c, let r = cRatio { nh = v / r } else if k == "t", lk.s, let r = sRatio { nh = v / r }
        if !keep { auto = false }
        nh = clampTo("h", nh)
        var nw = w, nt = t
        if k == "w" && !lk.c { nw = v }
        if k == "t" && !lk.s { nt = v }
        if lk.c, let r = cRatio { nw = clampTo("w", nh * r) }
        if lk.s, let r = sRatio { nt = clampTo("t", nh * r) }
        h = r1(nh); w = r1(nw); t = r1(nt)
        if focus == nil { syncFields() }
    }

    private func syncFields() {
        for (k, v) in [("h", h), ("w", w), ("t", t)] where focus != k { fields[k] = String(format: "%.1f", v) }
    }

    private func defaults() -> (h: Double, w: Double, t: Double) {
        var b = model.b
        b.dims = nil
        let d = ShelfSize.dims(b)
        return (r1(d.h), r1(d.w), r1(d.t))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        lockC = model.lockC ?? (cRatio != nil)
        lockS = model.lockS ?? (sRatio != nil)
        if model.openDims, let d = model.b.dims, d.num("h") > 0, d.num("w") > 0, d.num("t") > 0 {
            h = d.num("h"); w = d.num("w"); t = d.num("t"); auto = false
        } else {
            let d = defaults()
            h = d.h; w = d.w; t = d.t; auto = true
        }
        if locks.c || locks.s { set("h", h, keep: true) }
        syncFields()
    }

    private func reset() {
        lockC = cRatio != nil
        lockS = sRatio != nil
        let d = defaults()
        h = d.h; w = d.w; t = d.t
        auto = true
        if locks.c || locks.s { set("h", h, keep: true) }
        syncFields()
    }

    private func save() {
        focus = nil
        let d = defaults()
        // untouched defaults stay «automatic» (they follow the cover's shape)
        let same = auto && abs(h - d.h) < 0.05 && abs(w - d.w) < 0.05 && abs(t - d.t) < 0.05
        model.openDims = !same
        model.b.dims = same ? nil : ["h": .number(h), "w": .number(w), "t": .number(t)]
        model.lockC = lockC
        model.lockS = lockS
        dismiss()
        ToastCenter.shared.show("تم حفظ الأبعاد")
    }
}

/// Keeps the camera scanner alive while it is open.
@MainActor
enum ScanKeeper {
    static var current: BarcodeScanner?
}
