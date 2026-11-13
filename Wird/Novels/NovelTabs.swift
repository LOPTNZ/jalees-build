import SwiftUI
import UIKit

/// The novels' own tabs (تصفّح · التحديثات · التحميلات · السجل), shown above the web tab bar while that bar is in its
/// novels group. One screen holds them all and stays put: moving between them swaps what is inside at once, so the
/// library underneath never shows through. تصفّح keeps its place (a site you opened stays open), like a real tab.
@MainActor
final class NovelTabsModel: ObservableObject {
    @Published var tab = "browse"
    @Published var look: JLook
    /// grows each time a tab is shown again, so its list is read afresh
    @Published var visit = 0
    init(look: JLook) { self.look = look }
}

struct NovelTabsRoot: View {
    @ObservedObject var m: NovelTabsModel

    var body: some View {
        ZStack {
            Color(m.look.bg).ignoresSafeArea()
            BrowseTab(look: m.look).opacity(m.tab == "browse" ? 1 : 0).allowsHitTesting(m.tab == "browse")
            switch m.tab {
            case "updates": UpdatesTab(look: m.look).id(m.visit)
            case "downloads": DownloadsTab(look: m.look).id(m.visit)
            case "history": HistoryTab(look: m.look).id(m.visit)
            case "site": NavigationStack { SourceBrowse(look: m.look, site: "kolnovel", name: "ملوك الروايات") }.tint(Color(m.look.primary))
            default: EmptyView()
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "ar@numbers=latn"))
    }
}

@MainActor
enum NovelTabs {
    private static var host: UIHostingController<NovelTabsRoot>?
    private static var model: NovelTabsModel?
    private(set) static var current = ""
    /// the novels' screen is up (not stepped aside for a form, not hidden for Jalees's tabs)
    static var visible: Bool { host.map { !$0.view.isHidden } ?? false }

    static func show(_ tab: String) {
        guard let h = NovelBridge.host else { return }
        if tab.isEmpty { hide(); return }
        NovelBridge.closePage(animated: false)
        let wasHidden = current.isEmpty
        current = tab
        if let vc = host, let m = model {
            if m.tab != tab || wasHidden { m.visit += 1 }
            m.tab = tab
            h.view.bringSubviewToFront(vc.view)
            if wasHidden && !covered {
                vc.view.layer.removeAllAnimations()
                vc.view.isHidden = false
                vc.view.alpha = 0
                UIView.animate(withDuration: 0.16) { vc.view.alpha = 1 }
            }
            NovelBridge.look { lk in
                if m.look != lk { m.look = lk }
                vc.view.backgroundColor = lk.bg
                vc.view.frame.size.height = NovelBridge.height(lk, in: h)
            }
            return
        }
        NovelBridge.look { lk in
            guard current == tab, host == nil else { return }
            let m = NovelTabsModel(look: lk)
            m.tab = tab
            let vc = UIHostingController(rootView: NovelTabsRoot(m: m))
            vc.view.backgroundColor = lk.bg
            h.addChild(vc)
            vc.view.frame = CGRect(x: 0, y: 0, width: h.view.bounds.width, height: NovelBridge.height(lk, in: h))
            vc.view.autoresizingMask = [.flexibleWidth]
            h.view.addSubview(vc.view)
            vc.didMove(toParent: h)
            vc.view.alpha = 0
            UIView.animate(withDuration: 0.16) { vc.view.alpha = 1 }
            host = vc
            model = m
            NovelBridge.refit()
        }
    }

    static func fit(_ top: CGFloat) { host?.view.frame.size.height = top }

    /// A form of the library is open (editing a book, say): the screen steps aside while it is, then comes back.
    private static var covered = false
    static func cover(_ on: Bool) {
        covered = on
        guard let vc = host else { return }
        vc.view.layer.removeAllAnimations()
        vc.view.alpha = 1
        vc.view.isHidden = on || current.isEmpty
    }

    /// Back to Jalees's own tabs: the novels' screen steps aside (and keeps its place for next time).
    static func hide() {
        current = ""
        guard let vc = host, !vc.view.isHidden else { return }
        UIView.animate(withDuration: 0.14, animations: { vc.view.alpha = 0 }, completion: { _ in
            if current.isEmpty { vc.view.isHidden = true; vc.view.alpha = 1 }
        })
    }

    /// Adds a novel found while browsing (or finds it if it is already here), makes its library book, opens its page.
    static func open(_ url: String, progress: @escaping (String) -> Void) async throws {
        let r = try await Novels.shared.add(url: url, progress: progress)
        let n = r.novel
        var book = n.book
        if book.isEmpty, let w = NovelBridge.host?.webView {
            let o: [String: Any] = ["id": n.id, "title": n.title, "author": n.author, "url": n.url, "site": n.source, "cover": n.cover,
                                    "total": n.total, "complete": n.complete, "translator": n.translator, "genres": n.genres]
            book = await withCheckedContinuation { c in w.jalees("return wirdNovelAdopt(o)", ["o": o]) { v in c.resume(returning: (v as? String) ?? "") } }
            if !book.isEmpty { Novels.shared.link(n.id, book: book) }
        }
        NovelBridge.showPage(novel: n.id, book: book, openIndex: nil)
    }
}

// MARK: - تصفّح: the sites, then a site's novels

struct BrowseTab: View {
    let look: JLook
    @State private var sources: [[String: Any]] = []
    @State private var query = ""
    @State private var results: [(site: String, items: [[String: Any]])] = []
    @State private var searching = false
    @State private var busy: String?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color(look.ink2))
                        TextField("ابحث في كل المواقع", text: $query).font(JFont.body(16)).submitLabel(.search).onSubmit { search() }
                        if !query.isEmpty { Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(look.ink2)) } }
                    }
                    .padding(.horizontal, 14).frame(minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(look.surface)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(look.line), lineWidth: 1))

                    if searching { HStack { ProgressView(); Text("أبحث…").font(JFont.body(14)).foregroundStyle(Color(look.ink2)) } }
                    ForEach(results.indices, id: \.self) { i in
                        let g = results[i]
                        JHeading(look: look, title: siteName(g.site), count: g.items.count)
                        NovelGrid(look: look, items: g.items) { open($0) }
                    }

                    JHeading(look: look, title: "المواقع")
                    ForEach(sources.indices, id: \.self) { i in
                        let s = sources[i]
                        NavigationLink {
                            SourceBrowse(look: look, site: s["id"] as? String ?? "", name: s["name"] as? String ?? "")
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "globe").font(.system(size: 20)).foregroundStyle(Color(look.primary)).frame(width: 40, height: 40)
                                    .background(Circle().fill(Color(look.surface2)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s["name"] as? String ?? "").font(JFont.body(16, .semibold)).foregroundStyle(Color(look.ink))
                                    Text(URL(string: s["home"] as? String ?? "")?.host ?? "").font(JFont.body(13)).foregroundStyle(Color(look.ink2))
                                }
                                Spacer()
                                Image(systemName: "chevron.backward").foregroundStyle(Color(look.ink2))
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(look.surface)))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(look.line), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("باقي مواقعك (cenele وrewayat وغيرها) تنضاف في المرحلة الثانية.").font(JFont.body(13)).foregroundStyle(Color(look.ink2))
                }
                .padding(16)
            }
            .background(Color(look.bg).ignoresSafeArea())
            .navigationTitle("تصفّح")
            .toolbarBackground(Color(look.bg), for: .navigationBar)
        }
        .tint(Color(look.primary))
        .preferredColorScheme(look.dark ? .dark : .light)
        .overlay { if let b = busy { BusyCard(look: look, text: b) } }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("تمام", role: .cancel) {} }
        .task { await loadSources() }
    }

    private func siteName(_ id: String) -> String { (sources.first { ($0["id"] as? String) == id }?["name"] as? String) ?? id }

    private func loadSources() async {
        sources = await SourceEngine.shared.list()
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        results = []
        Task {
            for s in sources {
                let site = s["id"] as? String ?? ""
                if let r = try? await SourceEngine.shared.browse(site, kind: "search", page: 1, query: q), !r.items.isEmpty {
                    results.append((site, r.items))
                }
            }
            searching = false
            if results.isEmpty { note = "ما لقيت «\(q)» في المواقع" }
        }
    }

    private func open(_ item: [String: Any]) {
        guard let u = item["url"] as? String else { return }
        busy = "أجيب الرواية"
        Task {
            do { try await NovelTabs.open(u) { s in busy = s } } catch { note = error.localizedDescription }
            busy = nil
        }
    }
}

struct SourceBrowse: View {
    let look: JLook
    let site: String
    let name: String
    @State private var kind = "latest"
    @State private var items: [[String: Any]] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var query = ""
    @State private var busy: String?
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 0) {
                    ForEach(["latest", "popular"], id: \.self) { k in
                        Button { kind = k; query = ""; reload() } label: {
                            Text(k == "latest" ? "الأحدث" : "الأشهر").font(JFont.body(15, kind == k ? .medium : .regular))
                                .foregroundStyle(Color(kind == k ? look.onPrimary : look.ink))
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(kind == k ? Color(look.primary) : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(look.surface))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(look.line), lineWidth: 1))
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(look.ink2))
                    TextField("ابحث في \(name)", text: $query).font(JFont.body(15)).submitLabel(.search).onSubmit { kind = "search"; reload() }
                }
                .padding(.horizontal, 12).frame(minHeight: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(look.surface)))
                NovelGrid(look: look, items: items) { open($0) }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                else if more {
                    Button("المزيد") { page += 1; load() }.buttonStyle(JButtonStyle(look: look)).frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .background(Color(look.bg).ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if let b = busy { BusyCard(look: look, text: b) } }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("تمام", role: .cancel) {} }
        .task { if items.isEmpty { reload() } }
    }

    private func reload() { page = 1; items = []; load() }

    private func load() {
        loading = true
        Task {
            do {
                let r = try await SourceEngine.shared.browse(site, kind: kind, page: page, query: query)
                let have = Set(items.compactMap { $0["url"] as? String })
                items += r.items.filter { !have.contains(($0["url"] as? String) ?? "") }
                more = r.more && kind != "search"
            } catch { note = error.localizedDescription }
            loading = false
        }
    }

    private func open(_ item: [String: Any]) {
        guard let u = item["url"] as? String else { return }
        busy = "أجيب الرواية"
        Task {
            do { try await NovelTabs.open(u) { s in busy = s } } catch { note = error.localizedDescription }
            busy = nil
        }
    }
}

/// Covers in a grid, three across, with their names under them.
struct NovelGrid: View {
    let look: JLook
    let items: [[String: Any]]
    var open: ([String: Any]) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                Button { open(it) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        AsyncImage(url: URL(string: it["cover"] as? String ?? "")) { img in img.resizable().scaledToFill() } placeholder: {
                            Color(look.surface2)
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(0.68, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(it["title"] as? String ?? "").font(JFont.body(13, .medium)).foregroundStyle(Color(look.ink)).lineLimit(2)
                        if let m = it["meta"] as? String, !m.isEmpty { Text(m).font(JFont.body(11)).foregroundStyle(Color(look.ink2)).lineLimit(1) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct BusyCard: View {
    let look: JLook
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(text).font(JFont.body(14, .medium)).foregroundStyle(Color(look.ink)).multilineTextAlignment(.center)
            }
            .padding(24).frame(minWidth: 220)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(look.surface)))
        }
    }
}

// MARK: - التحميلات

struct DownloadsTab: View {
    let look: JLook
    @ObservedObject private var downloads = Downloads.shared
    @State private var rows: [[String: Any]] = []

    var body: some View {
        NavigationStack {
            List {
                if downloads.active {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("يحمّل الحين · باقي \(downloads.waiting.count)").font(JFont.body(15))
                            Spacer()
                            Button("إيقاف") { downloads.cancel() }.foregroundStyle(Color(look.primary))
                        }
                        .listRowBackground(Color(look.surface)).listRowSeparatorTint(Color(look.line))
                    }
                }
                Section {
                    if rows.isEmpty {
                        Text("ما فيه فصول محفوظة بعد. من صفحة أي رواية: «حمّل العشرة الجاية» أو حدد مجموعة فصول.").font(JFont.body(14)).foregroundStyle(Color(look.ink2)).listRowBackground(Color(look.surface)).listRowSeparatorTint(Color(look.line))
                    }
                    ForEach(rows.indices, id: \.self) { i in
                        let r = rows[i]
                        Button { NovelBridge.showPage(novel: r.int("id"), book: r.str("book"), openIndex: nil) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.str("title")).font(JFont.body(16, .semibold)).foregroundStyle(Color(look.ink))
                                    Text("\(r.int("saved")) فصل محفوظ من \(r.int("total"))").font(JFont.body(13)).foregroundStyle(Color(look.ink2))
                                }
                                Spacer()
                                Text(size(r.int("bytes"))).font(JFont.body(13)).foregroundStyle(Color(look.ink2)).monospacedDigit()
                            }
                        }
                        .listRowBackground(Color(look.surface)).listRowSeparatorTint(Color(look.line))
                        .swipeActions {
                            Button("احذف المحفوظ", role: .destructive) {
                                let ids = DB.shared.query("SELECT c.id FROM chapters c JOIN texts t ON t.chapter=c.id WHERE c.novel=?", [r.int("id")]).map { $0.int("id") }
                                Novels.shared.undownload(ids)
                                load()
                            }
                        }
                    }
                } header: { Text("المحفوظ على جوالك") }
            }
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 52)
            .background(Color(look.bg).ignoresSafeArea())
            .navigationTitle("التحميلات")
        }
        .tint(Color(look.primary))
        .preferredColorScheme(look.dark ? .dark : .light)
        .onAppear(perform: load)
        .onReceive(downloads.$waiting) { _ in load() }
    }

    private func load() {
        rows = DB.shared.query("""
        SELECT n.id, n.title, n.book, n.total, COUNT(t.chapter) AS saved, COALESCE(SUM(LENGTH(t.paras)), 0) AS bytes
        FROM novels n JOIN chapters c ON c.novel = n.id JOIN texts t ON t.chapter = c.id
        WHERE n.source != 'sample' GROUP BY n.id ORDER BY saved DESC
        """)
    }

    private func size(_ b: Int) -> String { b > 1_000_000 ? String(format: "%.1f م.ب", Double(b) / 1_000_000) : "\(max(1, b / 1000)) ك.ب" }
}

// MARK: - السجل

struct HistoryTab: View {
    let look: JLook
    @State private var rows: [[String: Any]] = []

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text("كل فصل تفتحه ينحفظ هنا، عشان ترجع له بضغطة.").font(JFont.body(14)).foregroundStyle(Color(look.ink2)).listRowBackground(Color(look.surface)).listRowSeparatorTint(Color(look.line))
                }
                let gs = groups
                ForEach(gs.indices, id: \.self) { g in
                    Section(gs[g].0) {
                        ForEach(gs[g].1.indices, id: \.self) { i in
                            let r = gs[g].1[i]
                            Button { NovelBridge.openReader(novel: r.int("novel"), book: r.str("book"), index: nil, chapter: r.int("chapter"), paragraph: nil) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(r.str("title")).font(JFont.body(15, .semibold)).foregroundStyle(Color(look.ink))
                                        Text(label(r)).font(JFont.body(13)).foregroundStyle(Color(look.ink2))
                                    }
                                    Spacer()
                                    Text(time(r.dbl("at"))).font(JFont.body(12)).foregroundStyle(Color(look.ink2)).monospacedDigit()
                                }
                            }
                            .listRowBackground(Color(look.surface)).listRowSeparatorTint(Color(look.line))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 52)
            .background(Color(look.bg).ignoresSafeArea())
            .navigationTitle("السجل")
            .toolbar {
                if !rows.isEmpty { Button("مسح") { DB.shared.run("DELETE FROM history"); load() } }
            }
        }
        .tint(Color(look.primary))
        .preferredColorScheme(look.dark ? .dark : .light)
        .onAppear(perform: load)
    }

    private var groups: [(String, [[String: Any]])] {
        var out: [(String, [[String: Any]])] = []
        for r in rows {
            let d = day(r.dbl("at"))
            if let i = out.firstIndex(where: { $0.0 == d }) { out[i].1.append(r) } else { out.append((d, [r])) }
        }
        return out
    }

    private func label(_ r: [String: Any]) -> String {
        let num = r.str("num"), title = r.str("ctitle")
        if !num.isEmpty, num != "0" { return title.isEmpty ? "الفصل \(num)" : "الفصل \(num): \(title)" }
        return title
    }

    private func load() {
        rows = DB.shared.query("""
        SELECT h.novel, h.chapter, h.at, n.title, n.book, c.num, c.title AS ctitle
        FROM history h JOIN novels n ON n.id = h.novel JOIN chapters c ON c.id = h.chapter
        ORDER BY h.at DESC LIMIT 300
        """)
    }

    private func day(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        if Calendar.current.isDateInToday(d) { return "اليوم" }
        if Calendar.current.isDateInYesterday(d) { return "أمس" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar@numbers=latn")
        f.dateFormat = "d MMMM"
        return f.string(from: d)
    }

    private func time(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar@numbers=latn")
        f.dateFormat = "h:mm a"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

// MARK: - التحديثات

/// New chapters from every novel, newest first, by day. Checked when the tab opens (at most once an hour) or on a pull.
struct UpdatesTab: View {
    let look: JLook
    @State private var rows: [[String: Any]] = []
    @State private var checking = false
    @State private var status = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        if checking { ProgressView() }
                        Text(checking ? status : lastCheck).font(JFont.body(14)).foregroundStyle(Color(look.ink2))
                        Spacer()
                        Button("افحص الحين") { Task { await check() } }.disabled(checking).foregroundStyle(Color(look.primary))
                    }
                    .listRowBackground(Color(look.surface)).listRowSeparatorTint(Color(look.line))
                }
                if rows.isEmpty && !checking {
                    Text("لما ينزل فصل جديد في أي رواية في مكتبتك يطلع هنا. اسحب الصفحة لتحت عشان تفحص.").font(JFont.body(14)).foregroundStyle(Color(look.ink2))
                        .listRowBackground(Color(look.surface)).listRowSeparatorTint(Color(look.line))
                }
                let gs = groups
                ForEach(gs.indices, id: \.self) { g in
                    Section(gs[g].0) {
                        ForEach(gs[g].1.indices, id: \.self) { i in
                            row(gs[g].1[i])
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 52)
            .background(Color(look.bg).ignoresSafeArea())
            .navigationTitle("التحديثات")
            .refreshable { await check() }
        }
        .tint(Color(look.primary))
        .preferredColorScheme(look.dark ? .dark : .light)
        .onAppear {
            load()
            let last = Double(DB.shared.get("updates.checked") ?? "") ?? 0
            if Date().timeIntervalSince1970 - last > 3600 { Task { await check() } }
        }
    }

    private func row(_ r: [String: Any]) -> some View {
        let read = r.int("read") != 0
        return Button {
            NovelBridge.openReader(novel: r.int("novel"), book: r.str("book"), index: nil, chapter: r.int("id"), paragraph: nil)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(Color(look.primary)).frame(width: 7, height: 7).opacity(read ? 0 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.str("title")).font(JFont.body(15, .semibold)).foregroundStyle(Color(read ? look.ink2 : look.ink))
                    Text(label(r)).font(JFont.body(13)).foregroundStyle(Color(look.ink2)).lineLimit(1)
                }
                Spacer()
                if r.int("saved") != 0 { Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color(look.ink2)) }
            }
        }
        .listRowBackground(Color(look.surface)).listRowSeparatorTint(Color(look.line))
        .swipeActions(edge: .leading) {
            Button(read ? "غير مقروء" : "مقروء") {
                DB.shared.run("UPDATE chapters SET read=? WHERE id=?", [read ? 0 : 1, r.int("id")])
                NovelBridge.sync(r.int("novel"))
                load()
            }.tint(Color(look.primary))
        }
        .swipeActions(edge: .trailing) {
            if r.int("saved") == 0 {
                Button("حمّل") { Downloads.shared.add([r.int("id")], source: r.str("source")) }.tint(Color(look.surface2))
            }
        }
    }

    private var lastCheck: String {
        guard let t = Double(DB.shared.get("updates.checked") ?? ""), t > 0 else { return "ما فحصت بعد" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ar@numbers=latn")
        return "آخر فحص " + f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }

    private func check() async {
        guard !checking else { return }
        checking = true
        status = "أفحص رواياتك"
        let k = await Novels.shared.checkAll { s in status = s }
        checking = false
        load()
        if k > 0 { Haptics.play("soft") }
    }

    private var groups: [(String, [[String: Any]])] {
        var out: [(String, [[String: Any]])] = []
        for r in rows {
            let d = day(r.dbl("found"))
            if let i = out.firstIndex(where: { $0.0 == d }) { out[i].1.append(r) } else { out.append((d, [r])) }
        }
        return out
    }

    private func label(_ r: [String: Any]) -> String {
        let num = r.str("num"), title = r.str("ctitle")
        if !num.isEmpty, num != "0" { return title.isEmpty ? "الفصل \(num)" : "الفصل \(num): \(title)" }
        return title
    }

    private func load() {
        rows = DB.shared.query("""
        SELECT c.id, c.novel, c.num, c.title AS ctitle, c.read, c.found, n.title, n.book, n.source,
               (SELECT 1 FROM texts t WHERE t.chapter = c.id) AS saved
        FROM chapters c JOIN novels n ON n.id = c.novel
        WHERE c.found IS NOT NULL ORDER BY c.found DESC, c.idx DESC LIMIT 300
        """)
    }

    private func day(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        if Calendar.current.isDateInToday(d) { return "اليوم" }
        if Calendar.current.isDateInYesterday(d) { return "أمس" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar@numbers=latn")
        f.dateFormat = "d MMMM"
        return f.string(from: d)
    }
}
