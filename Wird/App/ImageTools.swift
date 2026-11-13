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
                done(d.flatMap { UIImage(data: $0) }?.fixedOrientation().resized(maxSide: 2200))
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
        default: return [("حر", nil), ("الأصلية", r), ("2:3", 2 / 3), ("3:4", 3 / 4), ("1:1", 1)]
        }
    }

    private var title: String { ["spine": "قص الكعب", "photo": "حدد مكان الوجه"][request.kind] ?? "قص الغلاف" }

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
        let maxSide: CGFloat = request.kind == "photo" ? 520 : (request.kind == "spine" ? 1300 : 1100)
        done(UIImage(cgImage: cg).resized(maxSide: maxSide))
    }
}

// MARK: - the book's size on the shelf

/// «أبعاد الكتاب»: height, cover width, spine thickness (cm), keeping the pictures' shapes if asked.
struct DimsSheet: View {
    @ObservedObject var model: BookFormModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var h: Double = 21
    @State private var w: Double = 14
    @State private var t: Double = 2
    @State private var lockC = true
    @State private var lockS = true
    @State private var loaded = false

    var body: some View {
        JSheet(title: "أبعاد الكتاب", action: ("حفظ", { save() })) {
            HStack(alignment: .bottom, spacing: 14) {
                Spine(book: model.b, width: max(18, CGFloat(t) * ShelfSize.K), height: CGFloat(h) * ShelfSize.K)
                BookCover(book: model.b, radius: 3, marks: false).frame(width: CGFloat(w) * ShelfSize.K, height: CGFloat(h) * ShelfSize.K)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#2e2119")))
            slider("الارتفاع", $h, 10...40) { if lockC, let r = model.b.coverRatio { w = (h * r * 10).rounded() / 10 }; if lockS, let r = model.b.spineRatio { t = (h * r * 10).rounded() / 10 } }
            slider("عرض الغلاف", $w, 6...32) { if lockC, let r = model.b.coverRatio, r > 0 { h = (w / r * 10).rounded() / 10 } }
            slider("سماكة الكعب", $t, 0.3...12) { if lockS, let r = model.b.spineRatio, r > 0 { h = (t / r * 10).rounded() / 10 } }
            if model.b.coverRatio != nil { JSwitchRow(title: "حافظ على نسبة صورة الغلاف", sub: "يمنع مطّ الغلاف", on: $lockC) }
            if model.b.spineRatio != nil { JSwitchRow(title: "حافظ على نسبة صورة الكعب", sub: "يمنع مطّ الكعب", on: $lockS) }
            Button("رجوع للأبعاد الافتراضية") { model.openDims = false; model.b.dims = nil; load(force: true) }.buttonStyle(JButtonStyle(look: L))
        }
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        guard !loaded || force else { return }
        loaded = true
        let d = ShelfSize.dims(model.b)
        h = d.h; w = d.w; t = d.t
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, changed: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(JFont.body(15))
                Spacer()
                Text(String(format: "%.1f سم", v.wrappedValue)).font(JFont.body(14)).foregroundStyle(Color(L.ink2)).monospacedDigit()
            }
            Slider(value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = ($0 * 10).rounded() / 10; changed() }), in: r).tint(Color(L.primary))
        }
    }

    private func save() {
        model.b.dims = ["h": .number(min(40, max(10, h))), "w": .number(min(32, max(6, w))), "t": .number(min(12, max(0.3, t)))]
        model.openDims = true
        dismiss()
    }
}

/// Keeps the camera scanner alive while it is open.
@MainActor
enum ScanKeeper {
    static var current: BarcodeScanner?
}
