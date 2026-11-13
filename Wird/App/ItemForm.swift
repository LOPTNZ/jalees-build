import SwiftUI
import UIKit

// The notebook's form (inventory-2, 3.1): a quote (with its photo and text read from it), a thought, a word, or a
// character (with relations and fields of your own); add, edit, delete with undo.

@MainActor
final class ItemFormModel: ObservableObject {
    let kind: NoteKind
    let editing: Bool
    @Published var bookID: String
    @Published var x: JSONObject
    @Published var showPassage: Bool
    @Published var err = ""
    @Published var ocrBusy = false
    var newImgs: [String] = []
    private let oldImg: String?
    var saved = false
    private let original: Data?

    init(ref: ItemRef) {
        kind = NoteKind(rawValue: ref.kind) ?? .quote
        bookID = ref.book
        let b = Library.shared.state.book(ref.book)
        if let id = ref.item, let b = b, let found = b.raw.objs(kind.listKey).first(where: { $0.str("id") == id }) {
            editing = true
            x = found
        } else {
            editing = false
            x = b.map { NovelLibrary.blankItem(kind, $0) } ?? [:]
        }
        showPassage = !x.str("passage").isEmpty
        oldImg = kind == .char ? x.optStr("photo") : x.optStr("img")
        original = JSONValue.object(x).data()
    }

    var book: Book? { Library.shared.state.book(bookID) }
    var dirty: Bool { !saved && (JSONValue.object(x).data() != original || !newImgs.isEmpty) }

    func str(_ k: String) -> Binding<String> { Binding(get: { self.x.str(k) }, set: { self.x.set(k, $0) }) }
    func bool(_ k: String) -> Binding<Bool> { Binding(get: { self.x.bool(k) }, set: { self.x.set(k, $0) }) }
    func num(_ k: String) -> Binding<Double?> { Binding(get: { self.x.optNum(k) }, set: { self.x.set(k, optional: $0) }) }

    func discard() {
        guard !saved else { return }
        for id in newImgs { Library.shared.deleteImage(id) }
        newImgs = []
    }

    // MARK: pictures

    func setPicture(_ img: UIImage) {
        guard let id = Library.shared.putImage(img, prefix: kind == .quote ? "q" : "i") else { return }
        newImgs.append(id)
        if kind == .char { x.set("photo", id) } else { x.set("img", id) }
    }

    func clearPicture() { if kind == .char { x["photo"] = .null } else { x["img"] = .null } }

    /// The words in a photographed page, added to the quote.
    func read(_ img: UIImage) {
        guard let d = img.jpegData(compressionQuality: 0.9) else { return }
        ocrBusy = true
        OCR.run(["url": "data:image/jpeg;base64," + d.base64EncodedString()]) { [weak self] r in
            guard let self = self else { return }
            self.ocrBusy = false
            let t = ((r["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { self.err = "ما لقيت نص في الصورة."; return }
            if (r["arabic"] as? Bool) == false && t.range(of: #"[؀-ۿ]"#, options: .regularExpression) == nil {
                ToastCenter.shared.show("قرأت النص غير العربي فقط، جهازك يحتاج تحديث iOS للعربي")
            }
            let cur = self.x.str("text")
            self.x.set("text", cur.isEmpty ? t : cur + "\n" + t)
        }
    }

    // MARK: saving (itemSave)

    func save() -> Bool {
        guard let b = book else { err = "اختر الكتاب."; return false }
        switch kind {
        case .quote, .thought:
            x.set("text", x.str("text").trimmingCharacters(in: .whitespacesAndNewlines))
            if x.str("text").isEmpty && !(kind == .quote && x.optStr("img") != nil) { err = kind == .quote ? "اكتب الاقتباس أو صوّره." : "اكتب الفكرة."; return false }
            if kind == .quote {
                if x.optStr("img")?.isEmpty ?? true { x["img"] = nil }
                if x.str("speakerId") != "__o" { x.set("speakerName", "") }
            }
            if kind == .thought && !showPassage { x.set("passage", "") }
        case .word:
            x.set("word", x.str("word").trimmingCharacters(in: .whitespacesAndNewlines))
            if x.str("word").isEmpty { err = "اكتب الكلمة."; return false }
            if x.str("lang") == "ar" { x.set("tr", "") }
        case .char:
            x.set("name", x.str("name").trimmingCharacters(in: .whitespacesAndNewlines))
            if x.str("name").isEmpty { err = "اكتب اسم الشخصية."; return false }
            x.set("rel", objects: x.objs("rel").filter { !$0.str("to").isEmpty })
            x.set("custom", objects: x.objs("custom").filter { !$0.str("k").trimmingCharacters(in: .whitespaces).isEmpty || !$0.str("v").trimmingCharacters(in: .whitespaces).isEmpty })
        }
        let newPic = kind == .char ? x.optStr("photo") : x.optStr("img")
        if let o = oldImg, o != newPic { Library.shared.deleteImage(o) }
        let item = x, k = kind
        let firstWas = x.optNum("first")
        Library.shared.changeBook(b.id) { bb in
            var list = bb.raw.objs(k.listKey)
            if let i = list.firstIndex(where: { $0.str("id") == item.str("id") }) { list[i] = item } else { list.append(item) }
            if k == .char {
                // a relation goes both ways
                for r in item.objs("rel") {
                    if let j = list.firstIndex(where: { $0.str("id") == r.str("to") }), !list[j].objs("rel").contains(where: { $0.str("to") == item.str("id") }) {
                        var o = list[j]; var rl = o.objs("rel"); rl.append(["to": .string(item.str("id")), "label": .string("")]); o.set("rel", objects: rl); list[j] = o
                    }
                }
            }
            bb.raw.set(k.listKey, objects: list)
        }
        saved = true
        Achievements.check()
        ToastCenter.shared.show("تم الحفظ")
        // a new character in a novel or e-book: its first appearance is the chapter that first names it
        if k == .char && !editing && b.isNovel, let was = firstWas {
            let names = [item.str("name"), item.str("alias")]
            Task { @MainActor in
                guard let n = b.novel, let f = await Novels.shared.firstMention(n.novelID, names: names), Double(f.num) != was else { return }
                if NovelLibrary.charFirst(b.id, item.str("id"), f.num, was: Int(was)) {
                    ToastCenter.shared.show("أول ذكر لـ«\(item.str("name"))»: الفصل \(f.num)" + (f.sure ? "" : " (من الفصول المحفوظة)"))
                }
            }
        }
        return true
    }

    /// itemDel: a character also leaves the others' relations, and its quotes keep its name as «another person».
    func delete() {
        guard let b = book else { return }
        let snapshot = b
        let id = x.str("id"), k = kind, name = x.str("name")
        Library.shared.changeBook(b.id) { bb in
            bb.raw.set(k.listKey, objects: bb.raw.objs(k.listKey).filter { $0.str("id") != id })
            if k == .char {
                bb.raw.set("chars", objects: bb.raw.objs("chars").map { c in var c = c; c.set("rel", objects: c.objs("rel").filter { $0.str("to") != id }); return c })
                bb.raw.set("quotes", objects: bb.raw.objs("quotes").map { q in
                    var q = q
                    if q.str("speakerId") == id { q.set("speakerId", "__o"); q.set("speakerName", name) }
                    return q
                })
            }
        }
        saved = true
        let this = ["quote": "هذا الاقتباس", "thought": "هذه الفكرة", "word": "هذه الكلمة", "char": "هذه الشخصية"][k.rawValue] ?? ""
        ToastCenter.shared.show("تم حذف " + this) {
            Library.shared.change { st in if let i = st.index(of: snapshot.id) { st.books[i] = snapshot } }
        }
    }
}

struct ItemForm: View {
    let ref: ItemRef
    @StateObject private var m: ItemFormModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var askLeave = false
    @State private var askDelete = false
    @State private var photo: PhotoTarget?
    @State private var crop: CropRequest?
    @State private var ocrSource: PhotoTarget?

    init(ref: ItemRef) {
        self.ref = ref
        _m = StateObject(wrappedValue: ItemFormModel(ref: ref))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bookRow
                    switch m.kind {
                    case .quote: quote
                    case .thought: thought
                    case .word: word
                    case .char: character
                    }
                    if !m.err.isEmpty { Text(m.err).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
                    Button { if m.save() { dismiss() } } label: { Text("حفظ").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
                    if m.editing {
                        if let nv = m.x["nv"]?.object, let b = m.book, let n = b.novel {
                            Button { dismiss(); NovelBridge.openReader(novel: n.novelID, book: b.id, index: nil, chapter: nv.int("ch"), paragraph: nv.int("p")) } label: {
                                Label("افتح مكانه في القارئ", systemImage: "book").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(JButtonStyle(look: L))
                        }
                        Button { askDelete = true } label: {
                            Label("حذف " + (["quote": "هذا الاقتباس", "thought": "هذه الفكرة", "word": "هذه الكلمة", "char": "هذه الشخصية"][m.kind.rawValue] ?? ""), systemImage: "trash")
                                .frame(maxWidth: .infinity).foregroundStyle(Color(L.danger))
                        }
                        .buttonStyle(JButtonStyle(look: L))
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(L.surface).ignoresSafeArea())
            .navigationTitle((m.editing ? "تعديل " : "إضافة ") + m.kind.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel("إغلاق") }
                ToolbarItem(placement: .confirmationAction) { Button { if m.save() { dismiss() } } label: { Image(systemName: "checkmark") }.accessibilityLabel("حفظ") }
            }
        }
        .tint(Color(L.primary))
        .interactiveDismissDisabled(m.dirty)
        .confirmationDialog(m.editing ? "تترك التعديلات؟" : "تترك الإضافة؟", isPresented: $askLeave, titleVisibility: .visible) {
            Button("اطلع بدون حفظ", role: .destructive) { m.discard(); dismiss() }
            Button("أكمل", role: .cancel) {}
        }
        .confirmationDialog("حذف؟", isPresented: $askDelete) {
            Button("حذف", role: .destructive) { m.delete(); dismiss() }
            Button("إلغاء", role: .cancel) {}
        }
        .sheet(item: $photo) { t in
            ImageSource(target: t) { img in
                photo = nil
                if let i = img { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { crop = CropRequest(image: i, kind: t.kind) } }
            }
        }
        .fullScreenCover(item: $crop) { r in
            CropView(request: r) { img in
                crop = nil
                guard let i = img else { return }
                // a photographed page: keep it as a picture, or read its words
                if r.kind == "ocr" { pendingOCR = i } else { m.setPicture(i) }
            }
        }
        .sheet(item: $ocrSource) { t in
            ImageSource(target: t) { img in
                ocrSource = nil
                if let i = img { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { crop = CropRequest(image: i, kind: "ocr") } }
            }
        }
        .confirmationDialog("الصورة", isPresented: Binding(get: { pendingOCR != nil && crop == nil }, set: { if !$0 { pendingOCR = nil } })) {
            Button("استخراج النص") { if let i = pendingOCR { m.read(i) }; pendingOCR = nil }
            Button("حفظ كصورة") { if let i = pendingOCR { m.setPicture(i) }; pendingOCR = nil }
            Button("إلغاء", role: .cancel) { pendingOCR = nil }
        }
        .onDisappear { if !m.saved { m.discard() } }
    }

    @State private var pendingOCR: UIImage?

    private func close() { if m.dirty { askLeave = true } else { m.discard(); dismiss() } }

    // MARK: the book and the place

    @ViewBuilder private var bookRow: some View {
        if ref.pick {
            Menu {
                ForEach(Library.shared.state.books) { b in Button(b.title) { m.bookID = b.id; m.x = NovelLibrary.blankItem(m.kind, b).merging(m.x.filter { ["text", "word", "name", "passage"].contains($0.key) }) { $1 } } }
            } label: {
                HStack { Text(m.book?.title ?? "اختر كتابًا").font(JFont.body(15.5, .medium)); Spacer(); Image(systemName: "chevron.down") }
                    .foregroundStyle(Color(L.ink)).padding(.horizontal, 12).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            }
        } else if let b = m.book {
            Text(b.title).font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.ink2))
        }
    }

    @ViewBuilder private func location(_ label: String, key: String = "loc", volKey: String = "vol") -> some View {
        if let b = m.book {
            if b.series {
                Picker("المجلد", selection: Binding(get: { m.x.int(volKey) }, set: { m.x.set(volKey, $0) })) {
                    ForEach(b.volumes.indices, id: \.self) { i in Text("المجلد \(i + 1)" + (b.volumes[i].title.isEmpty ? "" : " · " + b.volumes[i].title)).tag(i) }
                }
                .pickerStyle(.menu)
            }
            JLabel(text: label)
            if b.unit.time {
                DurationField(minutes: Binding(get: { m.x.num(key) }, set: { m.x.set(key, $0) }))
            } else {
                box(m.num(key), numeric: true)
            }
        }
    }

    // MARK: kinds

    @ViewBuilder private var quote: some View {
        if let img = m.x.optStr("img"), let i = Library.shared.image(img) {
            Image(uiImage: i).resizable().scaledToFit().frame(maxHeight: 440).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                Button("صورة ثانية") { ocrSource = PhotoTarget(kind: "ocr") }.buttonStyle(JButtonStyle(look: L, small: true))
                if !m.ocrBusy { Button("استخرج نصها") { m.read(i) }.buttonStyle(JButtonStyle(look: L, small: true)) }
                Button("إزالة الصورة") { m.clearPicture() }.buttonStyle(JButtonStyle(look: L, small: true)).foregroundStyle(Color(L.danger))
            }
        }
        JLabel(text: m.x.optStr("img") != nil ? "نص الاقتباس (اختياري)" : "الاقتباس *")
        editor(m.str("text"), quoteFont: true, placeholder: m.x.optStr("img") != nil ? "اكتب نصه أو تعليقًا عليه" : "")
        if m.x.optStr("img") == nil {
            Button { ocrSource = PhotoTarget(kind: "ocr") } label: { Label(m.ocrBusy ? "أقرأ الصورة…" : "صوّر الاقتباس", systemImage: "camera") }
                .buttonStyle(JButtonStyle(look: L, small: true)).disabled(m.ocrBusy)
            Text("صوّر الصفحة وحدد الجزء اللي يعجبك، وبعدها اختر: تحفظه صورة أو أستخرج نصه.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
        }
        location(m.book?.unit.name ?? "الصفحة")
        if let b = m.book {
            Picker("القائل", selection: m.str("speakerId")) {
                Text("بدون قائل").tag("")
                ForEach(b.chars) { c in Text(c.name).tag(c.id) }
                Text("شخص آخر").tag("__o")
            }
            .pickerStyle(.menu)
            if m.x.str("speakerId") == "__o" { JLabel(text: "اسم القائل"); box(m.str("speakerName")) }
        }
        JSwitchRow(title: "من المفضّلة", on: m.bool("fav"))
    }

    @ViewBuilder private var thought: some View {
        JLabel(text: "الفكرة *")
        editor(m.str("text"), quoteFont: false, placeholder: "")
        location(m.book?.unit == .page ? "الصفحة التي ألهمتك" : "الفصل الذي ألهمك")
        JSwitchRow(title: "أضف النص اللي ألهمك (اختياري)", on: $m.showPassage)
        if m.showPassage { JLabel(text: "النص"); editor(m.str("passage"), quoteFont: true, placeholder: "") }
    }

    @ViewBuilder private var word: some View {
        JLabel(text: "الكلمة *")
        box(m.str("word"))
        HStack {
            Text("لغة الكلمة").font(JFont.body(15))
            Spacer()
            Picker("لغة الكلمة", selection: m.str("lang")) { ForEach(Words.langs, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.menu)
        }
        if m.x.str("lang") != "ar" { JLabel(text: "الترجمة"); box(m.str("tr")) }
        JLabel(text: "المعنى"); editor(m.str("meaning"), quoteFont: false, placeholder: "", height: 70)
        JLabel(text: "جملة من الكتاب (اختياري)"); editor(m.str("ex"), quoteFont: true, placeholder: "", height: 70)
        location(m.book?.unit.name ?? "الصفحة")
    }

    @ViewBuilder private var character: some View {
        HStack(spacing: 14) {
            Button { photo = PhotoTarget(kind: "photo") } label: { Avatar(name: m.x.str("name"), photo: m.x.optStr("photo"), size: 72) }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) { JLabel(text: "الاسم *"); box(m.str("name")) }
        }
        if let p = m.x.optStr("photo"), let i = Library.shared.image(p) {
            HStack(spacing: 8) {
                Button("تعديل مكان الوجه") { crop = CropRequest(image: i, kind: "photo") }.buttonStyle(JButtonStyle(look: L, small: true))
                Button("إزالة الصورة") { m.clearPicture() }.buttonStyle(JButtonStyle(look: L, small: true)).foregroundStyle(Color(L.danger))
            }
        }
        Text("كل الحقول اختيارية ما عدا الاسم.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
        Text("الأساسيات").font(JFont.display(17, .semibold))
        JLabel(text: "اللقب"); box(m.str("alias"))
        JSeg(options: [("main", "رئيسية"), ("secondary", "ثانوية"), ("", "غير محدد")], value: m.str("role"))
        JSeg(options: [("m", "ذكر"), ("f", "أنثى"), ("", "غير محدد")], value: m.str("gender"))
        JLabel(text: "العمر"); box(m.str("age"))
        location("أول ظهور (" + (m.book?.unit.name ?? "الفصل") + ")", key: "first", volKey: "firstVol")
        Text("الوصف").font(JFont.display(17, .semibold))
        JLabel(text: "الوصف"); editor(m.str("desc"), quoteFont: false, placeholder: "", height: 60)
        JLabel(text: "الأهمية"); box(m.str("importance"))
        JLabel(text: "الشكل"); editor(m.str("appearance"), quoteFont: false, placeholder: "", height: 60)
        JLabel(text: "الصفات"); editor(m.str("traits"), quoteFont: false, placeholder: "", height: 60)
        JLabel(text: "العيوب"); editor(m.str("flaws"), quoteFont: false, placeholder: "", height: 60)
        JLabel(text: "الموت"); box(m.str("death"), placeholder: "متى وكيف، إن وُجد")
        if Library.shared.state.settings.raw.bool("spoilers", true) {
            Text("الموت يظهر مغطّى حتى تضغط عليه، عشان ما تنحرق عليك الأحداث.").font(JFont.body(12)).foregroundStyle(Color(L.ink2))
        }
        relations
        custom
    }

    @ViewBuilder private var relations: some View {
        Text("العلاقات").font(JFont.display(17, .semibold))
        let others = (m.book?.chars ?? []).filter { $0.id != m.x.str("id") }
        if others.isEmpty {
            Text("أضف شخصيات ثانية لهذا الكتاب عشان تربطها ببعض.").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
        } else {
            ForEach(m.x.objs("rel").indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { m.x.objs("rel")[safe: i]?.str("to") ?? "" }, set: { v in setRel(i, "to", v) })) {
                        Text("اختر").tag("")
                        ForEach(others) { c in Text(c.name).tag(c.id) }
                    }
                    .pickerStyle(.menu)
                    TextField("أخ، عدو، معلّم…", text: Binding(get: { m.x.objs("rel")[safe: i]?.str("label") ?? "" }, set: { v in setRel(i, "label", v) }))
                        .font(JFont.body(15)).padding(.horizontal, 10).frame(height: 42).background(RoundedRectangle(cornerRadius: 10).fill(Color(L.bg)))
                    Button { var r = m.x.objs("rel"); r.remove(at: i); m.x.set("rel", objects: r) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            Button { var r = m.x.objs("rel"); r.append(["to": .string(""), "label": .string("")]); m.x.set("rel", objects: r) } label: { Label("علاقة", systemImage: "plus") }
                .buttonStyle(JButtonStyle(look: L, small: true))
        }
    }

    private func setRel(_ i: Int, _ k: String, _ v: String) {
        var r = m.x.objs("rel")
        guard r.indices.contains(i) else { return }
        r[i].set(k, v)
        m.x.set("rel", objects: r)
    }

    @ViewBuilder private var custom: some View {
        Text("حقول تضيفها بنفسك").font(JFont.display(17, .semibold))
        ForEach(m.x.objs("custom").indices, id: \.self) { i in
            HStack(spacing: 8) {
                TextField("الحقل، مثل المسار", text: Binding(get: { m.x.objs("custom")[safe: i]?.str("k") ?? "" }, set: { v in setCustom(i, "k", v) }))
                    .font(JFont.body(15)).padding(.horizontal, 10).frame(height: 42).background(RoundedRectangle(cornerRadius: 10).fill(Color(L.bg)))
                TextField("القيمة", text: Binding(get: { m.x.objs("custom")[safe: i]?.str("v") ?? "" }, set: { v in setCustom(i, "v", v) }))
                    .font(JFont.body(15)).padding(.horizontal, 10).frame(height: 42).background(RoundedRectangle(cornerRadius: 10).fill(Color(L.bg)))
                Button { var c = m.x.objs("custom"); c.remove(at: i); m.x.set("custom", objects: c) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        Button { var c = m.x.objs("custom"); c.append(["k": .string(""), "v": .string("")]); m.x.set("custom", objects: c) } label: { Label("حقل", systemImage: "plus") }
            .buttonStyle(JButtonStyle(look: L, small: true))
    }

    private func setCustom(_ i: Int, _ k: String, _ v: String) {
        var c = m.x.objs("custom")
        guard c.indices.contains(i) else { return }
        c[i].set(k, v)
        m.x.set("custom", objects: c)
    }

    // MARK: fields

    private func box(_ text: Binding<String>, placeholder: String = "") -> some View {
        TextField(placeholder, text: text).font(JFont.body(16)).padding(.horizontal, 12).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    private func box(_ v: Binding<Double?>, numeric: Bool) -> some View {
        TextField("", value: v, format: .number.grouping(.never)).keyboardType(.numberPad).font(JFont.body(16)).padding(.horizontal, 12).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    private func editor(_ text: Binding<String>, quoteFont: Bool, placeholder: String, height: CGFloat = 120) -> some View {
        TextEditor(text: text).font(quoteFont ? JFont.quote(18) : JFont.body(16)).frame(minHeight: height).scrollContentBackground(.hidden).padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty && !placeholder.isEmpty { Text(placeholder).font(JFont.body(15)).foregroundStyle(Color(L.ink2).opacity(0.7)).padding(14).allowsHitTesting(false) }
            }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
