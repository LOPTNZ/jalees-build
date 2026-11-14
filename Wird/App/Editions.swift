import SwiftUI
import UIKit

// Choosing your edition, a cover from the web, and importing from the small browser (03-lookup.js screens).

struct EditionsRequest: Identifiable {
    let id = UUID()
    let isbn: String
    let q: String
    let seed: BookLookup.Item?
}

/// «اختر طبعتك»: every edition found (yours first), filtered by language; pick one and its data fill the form.
struct EditionsSheet: View {
    let request: EditionsRequest
    let use: (BookLookup.Item, Bool) -> Void
    var ownCover = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var list: [BookLookup.Item] = []
    @State private var lang = ""
    @State private var sel = -1
    @State private var busy = true
    @State private var errs: [String] = []
    @State private var keepOwn = false
    @State private var browse: BrowseRequest?

    var body: some View {
        let vis = list.enumerated().filter { lang.isEmpty || ($0.element["lang"] as? String) == lang || $0.element["mark"] != nil }
        var langs: [String: Int] = [:]
        for e in list { if let l = e["lang"] as? String, !l.isEmpty { langs[l, default: 0] += 1 } }
        let lk = langs.keys.sorted { langs[$0]! > langs[$1]! }
        return JSheet(title: "اختر طبعتك", action: sel >= 0 ? ("استخدم", { pick() }) : nil) {
            Text((request.isbn.isEmpty ? "" : "هذي الطبعات اللي لقيتها للرقم \(request.isbn) ولنفس الكتاب. ") + "اختر اللي معك: غلافها وعدد صفحاتها ولغتها تنحفظ للكتاب.")
                .font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
            if lk.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        JChip(look: L, text: "الكل", count: list.count, on: lang.isEmpty) { lang = "" }
                        ForEach(lk, id: \.self) { k in JChip(look: L, text: Words.lang(k).isEmpty ? k : Words.lang(k), count: langs[k], on: lang == k) { lang = k } }
                    }
                }
            }
            if !vis.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 14) {
                    ForEach(vis, id: \.offset) { i, e in card(e, on: i == sel) { sel = i } }
                }
            }
            if busy {
                HStack(spacing: 8) { ProgressView(); Text("أدوّر على الطبعات…").font(JFont.body(14)).foregroundStyle(Color(L.ink2)) }
            } else if list.isEmpty {
                Notice(title: "ما لقيت " + (request.isbn.isEmpty ? "طبعات لهذا الكتاب" : "هذا الرقم") + ".",
                       text: "الكتب العربية كثير منها ما له باركود في قواعد البيانات. ابحث بالعنوان، أو دوّر عليه في المواقع.")
            }
            if !errs.isEmpty && !busy { Text("ما وصلت لـ " + errs.joined(separator: "، ") + ".").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)) }
            SiteChips { s in browse = BrowseRequest(query: request.isbn.isEmpty ? ((request.seed?["title"] as? String) ?? request.q) : request.isbn, site: s, coverOnly: false) }
            if ownCover { JSwitchRow(title: "احتفظ بصورتك للغلاف", sub: "تاخذ من الطبعة بياناتها بس", on: $keepOwn) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if list.indices.contains(sel) {
                let e = list[sel], pages = NovelBridge.num(e["pages"])
                EdBar(title: (e["title"] as? String) ?? "",
                      sub: [pages > 0 ? ((e["approx"] as? Bool) == true ? "≈ " : "") + "\(pages) صفحة" : "", Words.lang((e["lang"] as? String) ?? ""), (e["isbn"] as? String) ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                      button: "استخدمها") { pick() }
            }
        }
        .task { await load() }
        .onAppear { keepOwn = ownCover }
        .fullScreenCover(item: $browse) { r in
            BrowserImport(request: r) { data in
                browse = nil
                if let d = data { dismiss(); use(d, false) }
            }
        }
    }

    private func load() async {
        if let s = request.seed { var x = s; x["mark"] = (s["exact"] as? Bool) == true ? "exact" : "pick"; list = [x]; sel = 0 }
        let r = await BookLookup.editions(isbn: request.isbn, q: request.q, seed: request.seed)
        list = r.list
        lang = r.lang
        sel = r.sel
        errs = r.errs
        busy = false
    }

    private func pick() {
        guard list.indices.contains(sel) else { return }
        let e = list[sel]
        dismiss()
        use(e, keepOwn)
    }

    private func card(_ e: BookLookup.Item, on: Bool, tap: @escaping () -> Void) -> some View {
        let pages = NovelBridge.num(e["pages"]), minutes = NovelBridge.num(e["minutes"])
        let bits = [pages > 0 ? ((e["approx"] as? Bool) == true ? "≈ " : "") + "\(pages) صفحة" : "", minutes > 0 ? Words.fmtMin(Double(minutes)) : "",
                    (e["year"] as? String) ?? "", (e["publisher"] as? String) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let th = ((e["thumb"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? ((e["cover"] as? String) ?? "")
        return Button(action: tap) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    Color(L.surface2)
                    AsyncImage(url: URL(string: th)) { i in i.resizable().scaledToFill() } placeholder: {
                        Text((e["title"] as? String) ?? "").font(JFont.body(10)).foregroundStyle(Color(L.ink2)).padding(6)
                    }
                    if (e["mark"] as? String) == "exact" {
                        Text("طبعتك").font(JFont.body(10.5, .semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(L.accent))).padding(5)
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(on ? L.primary : .clear), lineWidth: 3))
                Text((e["title"] as? String) ?? "").font(JFont.body(12, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(2)
                if !bits.isEmpty { Text(bits).font(JFont.body(10.5)).foregroundStyle(Color(L.ink2)).lineLimit(2) }
                Text([Words.lang((e["lang"] as? String) ?? ""), BookLookup.sourceNames[(e["src"] as? String) ?? ""] ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(JFont.body(10)).foregroundStyle(Color(L.ink2))
            }
        }
        .buttonStyle(.plain)
    }
}

/// «غلاف من الإنترنت»: covers from every source for the book's title (or a search you change).
struct CoverSearchSheet: View {
    let query: String
    let use: (BookLookup.Item) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var q = ""
    @State private var list: [BookLookup.Item] = []
    @State private var sel = -1
    @State private var busy = false
    @State private var done = false
    @State private var errs: [String] = []
    @State private var token = 0
    @State private var browse: BrowseRequest?

    var body: some View {
        JSheet(title: "غلاف من الإنترنت", action: sel >= 0 ? ("استخدم الغلاف", { pick() }) : nil) {
            HStack(spacing: 8) {
                TextField("اسم الكتاب أو المؤلف أو ISBN", text: $q).font(JFont.body(16)).submitLabel(.search).onSubmit { run() }
                    .padding(.horizontal, 12).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                Button("ابحث") { run() }.buttonStyle(JButtonStyle(look: L, primary: true)).disabled(busy)
            }
            Text("اختر الغلاف اللي يشبه نسختك. ما يتغير شي غير الصورة.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
            if !list.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(list.indices, id: \.self) { i in
                        let e = list[i]
                        let th = ((e["thumb"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? ((e["cover"] as? String) ?? "")
                        Button { sel = i } label: {
                            VStack(spacing: 4) {
                                AsyncImage(url: URL(string: th)) { im in im.resizable().scaledToFill() } placeholder: { Color(L.surface2) }
                                    .aspectRatio(2 / 3, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(i == sel ? L.primary : .clear), lineWidth: 3))
                                Text([BookLookup.sourceNames[(e["src"] as? String) ?? ""] ?? "", (e["year"] as? String) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(JFont.body(10.5)).foregroundStyle(Color(L.ink2)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel((e["title"] as? String) ?? "غلاف")
                    }
                }
            }
            if busy {
                HStack(spacing: 8) { ProgressView(); Text("أدوّر على الأغلفة…").font(JFont.body(14)).foregroundStyle(Color(L.ink2)) }
            } else if done && list.isEmpty {
                Notice(title: "ما لقيت أغلفة.", text: "جرّب تكتب الاسم بطريقة ثانية أو بالإنجليزي، أو دوّر عليه في المواقع تحت.")
            }
            if !errs.isEmpty && !busy { Text("ما وصلت لـ " + errs.joined(separator: "، ") + ".").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)) }
            if done || !list.isEmpty {
                Text("ما لقيت غلافك؟ دوّر عليه بنفسك:").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
                SiteChips { s in browse = BrowseRequest(query: q, site: s, coverOnly: true) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if list.indices.contains(sel) {
                let e = list[sel]
                EdBar(title: ((e["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? "غلاف",
                      sub: BookLookup.sourceNames[(e["src"] as? String) ?? ""] ?? "", button: "استخدم الغلاف") { pick() }
            }
        }
        .onAppear { if q.isEmpty { q = query; run() } }
        .fullScreenCover(item: $browse) { r in
            BrowserImport(request: r) { data in
                browse = nil
                if let d = data { dismiss(); use(d) }
            }
        }
    }

    private func run() {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        token += 1
        let mine = token
        busy = true; done = false; list = []; sel = -1; errs = []
        Task {
            let r = await BookLookup.covers(text)
            guard mine == token else { return }
            list = r.list; errs = r.errs; busy = false; done = true
        }
    }

    private func pick() {
        guard list.indices.contains(sel) else { return }
        let e = list[sel]
        dismiss()
        use(e)
    }
}

// MARK: - the small browser

struct BrowseRequest: Identifiable {
    let id = UUID()
    let query: String
    let site: Int
    let coverOnly: Bool
}

/// The small browser on a book site; «استيراد» there brings the page's data and pictures back here to choose from.
struct BrowserImport: View {
    let request: BrowseRequest
    let done: ([String: Any]?) -> Void
    @State private var page: [String: Any]?

    var body: some View {
        if let p = page {
            WebImportSheet(page: p, coverOnly: request.coverOnly, done: done)
        } else {
            BrowserHost(query: request.query, site: request.site) { r in
                if let r = r { page = r } else { done(nil) }
            }
            .ignoresSafeArea()
        }
    }
}

private struct BrowserHost: UIViewControllerRepresentable {
    let query: String
    let site: Int
    let done: ([String: Any]?) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: BookBrowser(query: query, site: site, done: done))
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

/// «من …»: the cover from the page's pictures, and its title, author, pages and ISBN (which you can fix).
struct WebImportSheet: View {
    let page: [String: Any]
    let coverOnly: Bool
    let done: ([String: Any]?) -> Void
    @Environment(\.look) private var L
    @State private var images: [String] = []
    @State private var pickIndex = 0
    @State private var useData = true
    @State private var t = ""
    @State private var a = ""
    @State private var pages = ""
    @State private var isbn = ""
    @State private var loaded = false
    @State private var err = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if (page["book"] as? Bool) == false && !coverOnly {
                        Text("هذي الصفحة ما تبدو صفحة كتاب، فأخذت صورها بس. لو تبي بياناته افتح صفحة الكتاب نفسه.").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                    }
                    JLabel(text: "اختر الغلاف")
                    if images.isEmpty { Text("ما لقيت صور في الصفحة.").font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(images.indices, id: \.self) { i in
                            Button { pickIndex = i } label: {
                                AsyncImage(url: URL(string: images[i])) { im in im.resizable().scaledToFill() } placeholder: { Color(L.surface2) }
                                    .aspectRatio(2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(i == pickIndex ? L.primary : .clear), lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                        }
                        // your own photo instead (-2), or no cover from this page (-1)
                        choice(-2, "camera", "صوّر غلافك")
                        choice(-1, "nosign", "بدون غلاف")
                    }
                    if !coverOnly {
                        JSwitchRow(title: "عبّي بيانات الكتاب من الصفحة", on: $useData)
                        if useData {
                            box("العنوان", $t); box("المؤلف", $a); box("عدد الصفحات", $pages); box("ISBN", $isbn)
                        }
                    }
                    if !err.isEmpty { Text(err).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
                    Button { use() } label: { Text("استخدم").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
                }
                .padding(18)
            }
            .background(Color(L.surface).ignoresSafeArea())
            .navigationTitle("من " + ((page["site"] as? String) ?? "الويب"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { done(nil) } label: { Image(systemName: "xmark") } } }
        }
        .environment(\.layoutDirection, Lang.direction)
        .onAppear(perform: load)
    }

    private func choice(_ i: Int, _ icon: String, _ label: String) -> some View {
        Button { pickIndex = i } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 22))
                Text(label).font(JFont.body(12.5, .medium)).multilineTextAlignment(.center)
            }
            .foregroundStyle(Color(L.ink2))
            .frame(maxWidth: .infinity).aspectRatio(2 / 3, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(L.surface2)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(i == pickIndex ? L.primary : .clear), lineWidth: 3))
        }
        .buttonStyle(.plain)
    }

    private func box(_ label: String, _ v: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            JLabel(text: label)
            TextField("", text: v).font(JFont.body(16)).padding(.horizontal, 12).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        var imgs = ((page["images"] as? [String]) ?? []).filter { !$0.isEmpty && (!$0.hasPrefix("data:") || $0.count < 600_000) }
        if let c = page["cover"] as? String, !c.isEmpty, !imgs.contains(c) { imgs.insert(c, at: 0) }
        images = Array(imgs.prefix(12))
        if images.isEmpty { pickIndex = -1 }
        let raw = ((page["title"] as? String) ?? "").replacingOccurrences(of: #"\s*[|–-]\s*(Goodreads|Amazon[^|]*|أبجد|Open Library|Google Books)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^Amazon\.\w+\s*:\s*"#, with: "", options: .regularExpression)
        t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        a = ((page["author"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = NovelBridge.num(page["pages"]); pages = p > 0 ? "\(p)" : ""
        isbn = BookLookup.clean((page["isbn"] as? String) ?? "")
    }

    private func use() {
        if !coverOnly && useData && t.trimmingCharacters(in: .whitespaces).isEmpty { err = "اكتب العنوان."; return }
        var e: [String: Any] = ["src": "web"]
        if images.indices.contains(pickIndex) { e["cover"] = images[pickIndex] }
        if pickIndex == -2 { e["ownPhoto"] = true }
        if !coverOnly && useData {
            e["title"] = t; e["author"] = a; e["isbn"] = isbn
            if let p = Int(pages), p > 0 { e["pages"] = p }
            if let l = page["lang"] as? String { e["lang"] = l }
        }
        done(e)
    }
}

/// .notice: a bold line and its explanation on the accent's soft colour.
struct Notice: View {
    let title: String
    let text: String
    @Environment(\.look) private var L
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(JFont.body(14.5, .semibold))
            Text(text).font(JFont.body(13.5))
        }
        .foregroundStyle(Color(L.ink))
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.accentSoft)))
    }
}

/// .ed-bar: what is selected, pinned under the list, with its button.
struct EdBar: View {
    let title: String
    let sub: String
    let button: String
    let action: () -> Void
    @Environment(\.look) private var L
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(JFont.body(14.5, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(JFont.body(12)).foregroundStyle(Color(L.ink2)).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: action).buttonStyle(JButtonStyle(look: L, primary: true))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color(L.surface).shadow(color: .black.opacity(0.25), radius: 10, y: -4).ignoresSafeArea(edges: .bottom))
    }
}
