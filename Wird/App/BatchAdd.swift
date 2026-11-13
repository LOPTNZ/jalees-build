import SwiftUI
import UIKit

// Adding many books at once (inventory-1 3.4 multiAdd; 03-lookup.js scanBatch, batchAdd), and the app's sheets center.

/// One place that opens the app's big sheets from anywhere (a button on a page, a menu, a link).
@MainActor
final class Present: ObservableObject {
    static let shared = Present()
    enum Modal: Identifiable {
        case bookForm(String?)
        case multiAdd
        case batch([String])
        case finish(String, String?, Bool)
        case reread(String)
        case readDel(String, Int)
        case item(ItemRef)
        case review(String?)
        case character(String, String)
        case card(CardRequest)
        case pdf(String)
        case restore(BackupFile)
        var id: String {
            switch self {
            case .bookForm(let b): return "form" + (b ?? "")
            case .multiAdd: return "multi"
            case .batch(let c): return "batch" + c.joined()
            case .finish(let b, let v, _): return "finish" + b + (v ?? "")
            case .reread(let b): return "reread" + b
            case .readDel(let b, let n): return "readDel" + b + "\(n)"
            case .item(let r): return "item" + r.id.uuidString
            case .review(let b): return "review" + (b ?? "")
            case .character(let b, let c): return "char" + b + c
            case .card(let r): return "card" + r.id.uuidString
            case .pdf(let b): return "pdf" + b
            case .restore(let f): return "restore" + f.id.uuidString
            }
        }
    }
    @Published var modal: Modal?

    func open(_ m: Modal) {
        if modal != nil { modal = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.modal = m } } else { modal = m }
    }
}

/// «عدة كتب»: one title a line («العنوان - المؤلف»), with one format, progress method and status for all.
struct MultiAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var text = ""
    @State private var structure = "volume"
    @State private var audioBy = "time"
    @State private var format = BookFormat.physical
    @State private var status = BookStatus.want
    @State private var err = ""

    var body: some View {
        JSheet(title: "عدة كتب", action: ("إضافة", { save() })) {
            JLabel(text: "كل كتاب في سطر، وممكن تكتب «العنوان - المؤلف»")
            TextEditor(text: $text).font(JFont.body(16)).frame(minHeight: 180).scrollContentBackground(.hidden)
                .padding(8).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { Text("البؤساء - فيكتور هيجو\nلكنود - إسلام جمال").font(JFont.body(16)).foregroundStyle(Color(L.ink2).opacity(0.7)).padding(14).allowsHitTesting(false) }
                }
            JLabel(text: "طريقة التقدم")
            if format == .audio { JSeg(options: [("time", "بالوقت"), ("chapters", "بالفصول")], value: $audioBy) }
            else { JSeg(options: [("volume", "بالصفحات"), ("chapters", "بالفصول")], value: $structure) }
            JLabel(text: "الصيغة")
            JSeg(options: [(BookFormat.physical, "ملموس"), (.ebook, "إلكتروني"), (.audio, "صوتي")], value: $format)
            JLabel(text: "الحالة")
            JSeg(options: [(BookStatus.want, "أريد قراءته"), (.reading, "أقرأه الآن"), (.done, "أنهيته")], value: $status)
            Text("عدد الصفحات أو الفصول تكمّله لاحقًا من «تعديل الكتاب».").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
            if !err.isEmpty { Text(err).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
            Button { save() } label: { Text("إضافة الكتب").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
        }
        .interactiveDismissDisabled(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func save() {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { err = "اكتب عنوانًا واحدًا على الأقل."; return }
        let t0 = Millis.now
        var books: [Book] = []
        for (i, l) in lines.enumerated() {
            let parts = l.components(separatedBy: CharacterSet(charactersIn: "-–—")).map { $0.trimmingCharacters(in: .whitespaces) }
            let hasDash = l.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) != nil
            var o = Library.blankBook()
            o.set("title", hasDash ? parts[0] : l)
            o.set("author", hasDash ? parts.dropFirst().joined(separator: " - ") : "")
            o.set("structure", structure)
            o.set("format", format.rawValue)
            if format == .audio { o.set("audioBy", audioBy) }
            o.set("status", status.rawValue)
            o.set("added", t0 + Double(i))
            if status == .reading { o.set("start", t0) }
            if status == .done { o.set("finish", t0) }
            books.append(Book(Library.fixBook(o)))
        }
        Library.shared.change { $0.books.append(contentsOf: books) }
        dismiss()
        Router.shared.select(.library)
        Achievements.check()
        ToastCenter.shared.show("تمت إضافة " + Words.cnt(Double(books.count), ["كتاب واحد", "كتابين", "كتب", "كتابًا"]))
    }
}

/// «مسح متتابع»: each scanned code looked up (three at once); tick the ones to add.
struct BatchAddSheet: View {
    let codes: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var items: [Row] = []
    @State private var status = BookStatus.want

    struct Row: Identifiable {
        let id = UUID()
        let code: String
        var state = "wait"
        var on = false
        var r: BookLookup.Item?
        var dup = false
    }

    var body: some View {
        let left = items.filter { $0.state == "wait" }.count
        let n = items.filter(\.on).count
        JSheet(title: "مسح متتابع", action: n > 0 ? ("إضافة", { save() }) : nil) {
            Text(left > 0 ? "أدوّر على " + Words.cnt(Double(items.count), ["كتاب واحد", "كتابين", "كتب", "كتابًا"]) + "… باقي \(left)."
                          : "اختر اللي تبي تضيفه. الكتب تنضاف ملموسة، وتكمّل تفاصيلها لاحقًا.")
                .font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
            VStack(spacing: 0) {
                ForEach($items) { $x in
                    HStack(spacing: 12) {
                        Toggle("", isOn: $x.on).labelsHidden().disabled(x.state != "found").tint(Color(L.primary))
                        let th = ((x.r?["thumb"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? ((x.r?["cover"] as? String) ?? "")
                        AsyncImage(url: URL(string: th)) { i in i.resizable().scaledToFill() } placeholder: { Color(L.surface2) }
                            .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(x.state == "wait" ? "أدوّر…" : (x.state == "none" ? "ما لقيت هذا الرقم" : ((x.r?["title"] as? String) ?? "")))
                                .font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(2)
                            Text(sub(x)).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .opacity(x.state == "none" || x.dup ? 0.55 : 1)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
                }
            }
            JLabel(text: "الحالة")
            JSeg(options: [(BookStatus.want, "أريد قراءته"), (.reading, "أقرأه الآن"), (.done, "أنهيته")], value: $status)
            Button { save() } label: {
                Text(n > 0 ? "إضافة " + Words.cnt(Double(n), ["كتاب واحد", "كتابين", "كتب", "كتابًا"]) : "اختر كتابًا").frame(maxWidth: .infinity)
            }
            .buttonStyle(JButtonStyle(look: L, primary: true)).disabled(n == 0)
        }
        .task { await start() }
    }

    private func sub(_ x: Row) -> String {
        if x.dup { return x.code + " · موجود في مكتبتك" }
        guard x.state == "found", let r = x.r else { return x.code }
        let p = NovelBridge.num(r["pages"])
        return [(r["author"] as? String) ?? "", p > 0 ? "\(p) صفحة" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func start() async {
        guard items.isEmpty else { return }
        let have = Set(Library.shared.state.books.map(\.isbn).filter { !$0.isEmpty })
        items = codes.map { Row(code: $0, dup: have.contains($0)) }
        // three at once
        await withTaskGroup(of: Void.self) { g in
            var next = 0
            func one(_ i: Int) { g.addTask { @MainActor in await look(i) } }
            for _ in 0..<min(3, items.count) { one(next); next += 1 }
            while await g.next() != nil { if next < items.count { one(next); next += 1 } }
        }
    }

    private func look(_ i: Int) async {
        let r = await BookLookup.batch(items[i].code)
        if let r = r { items[i].r = r; items[i].state = "found"; items[i].on = !items[i].dup } else { items[i].state = "none" }
    }

    private func save() {
        let picks = items.filter { $0.on && $0.r != nil }
        guard !picks.isEmpty else { return }
        let t0 = Millis.now
        var added: [(Book, BookLookup.Item)] = []
        for (i, x) in picks.enumerated() {
            guard let r = x.r else { continue }
            var o = Library.blankBook()
            o.set("title", (r["title"] as? String) ?? "")
            o.set("author", (r["author"] as? String) ?? "")
            o.set("isbn", x.code)
            let lg = (r["lang"] as? String) ?? ""
            if Words.langs.contains(where: { $0.0 == lg }) { o.set("lang", lg) }
            let p = NovelBridge.num(r["pages"])
            if p > 0 && (r["approx"] as? Bool) != true { o["volumes"] = .array([.object(["id": .string(uid()), "title": .string(""), "total": .number(Double(p))])]) }
            o.set("status", status.rawValue)
            o.set("added", t0 + Double(i))
            if status == .reading { o.set("start", t0) }
            if status == .done { o.set("finish", t0) }
            added.append((Book(Library.fixBook(o)), r))
        }
        Library.shared.change { $0.books.append(contentsOf: added.map(\.0)) }
        dismiss()
        Router.shared.select(.library)
        Achievements.check()
        ToastCenter.shared.show("تمت إضافة " + Words.cnt(Double(added.count), ["كتاب واحد", "كتابين", "كتب", "كتابًا"]))
        // covers arrive one by one, after the books are already in the library
        Task { @MainActor in
            for (b, r) in added {
                guard let c = r["cover"] as? String, !c.isEmpty, let img = await BookLookup.coverImage(c, fallback: r["thumb"] as? String) else { continue }
                if Library.shared.state.book(b.id)?.cover == nil { NovelLibrary.setCover(b.id, img) }
            }
        }
    }
}

@MainActor
enum Scanning {
    /// One barcode: the book form, then its editions.
    static func single() { Present.shared.open(.bookForm(nil)); DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { NotificationCenter.default.post(name: .formScan, object: nil) } }

    /// Many barcodes, one after another, then the list to tick.
    static func batch() {
        guard let h = NovelBridge.host else { return }
        let s = BarcodeScanner()
        s.multi = true
        ScanKeeper.current = s
        s.present(from: NovelBridge.top(h)) { r in
            ScanKeeper.current = nil
            let raw = (r as? [String]) ?? ((r as? String).map { [$0] } ?? [])
            var codes: [String] = []
            for c in raw { let x = BookLookup.clean(c); if !x.isEmpty && !codes.contains(x) { codes.append(x) } }
            if r == nil { ToastCenter.shared.show("تعذّر فتح الكاميرا"); return }
            guard !codes.isEmpty else { return }
            Haptics.play("success")
            Present.shared.open(.batch(codes))
        }
    }
}

extension Notification.Name {
    static let formScan = Notification.Name("jalees.formScan")
    /// for the simulator check: a search typed into the open form
    static let formQuery = Notification.Name("jalees.formQuery")
}
