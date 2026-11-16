import SwiftUI
import UIKit

/// The novels' own tabs (تصفّح · التحديثات · التحميلات · السجل). Each sits in its tab's navigation stack (RootView),
/// in Jalees's look: its colours, fonts and cards.

// MARK: - تصفّح: the sites, then a site's novels

struct BrowseTab: View {
    let look: JLook
    @State private var sources: [[String: Any]] = []
    @State private var query = ""
    @State private var results: [(site: String, items: [[String: Any]])] = []
    @State private var searching = false
    /// each site's search while it runs: "" asking, a count, "-" nothing, "!" it failed
    @State private var siteState: [String: String] = [:]
    @State private var searchToken = 0
    @State private var busy: String?
    @State private var note: String?
    @State private var repo = false
    /// an Arabic search on its way to English for the English sites (EnglishQuery), and what it became
    @State private var toEnglish: String?
    @State private var asked = ""
    @State private var english: String?
    /// a search that found nothing, said in the page (an alert came up over whatever tab was open by then)
    @State private var nothing: String?
    @ObservedObject private var novels = Novels.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("تصفّح").font(JFont.display(28, .bold)).foregroundStyle(Color(look.ink))
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(look.ink2))
                    TextField("ابحث في كل المواقع", text: $query).font(JFont.body(16)).submitLabel(.search).onSubmit { search() }
                    if !query.isEmpty { Button { query = ""; results = []; searchToken += 1; searching = false; english = nil; nothing = nil; siteState = [:] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(look.ink2)) } }
                }
                .padding(.horizontal, 14).frame(minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(look.surface)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(look.line), lineWidth: 1))

                if searching || !siteState.isEmpty { searchProgress }
                if let e = english {
                    Label("في المواقع الإنجليزية بحثت عن «\(e)»", systemImage: "character.bubble").font(JFont.body(13)).foregroundStyle(Color(look.ink2))
                }
                if let q = nothing {
                    Text("ما لقيت «\(q)» في المواقع. جرّب كلمة وحدة من الاسم، أو اسمه بالإنجليزي.").font(JFont.body(14)).foregroundStyle(Color(look.ink2))
                }
                ForEach(results.indices, id: \.self) { i in
                    let g = results[i]
                    JHeading(look: look, title: siteName(g.site), count: g.items.count)
                    NovelGrid(look: look, items: g.items) { open($0) }
                }

                let groups = siteGroups
                ForEach(groups.indices, id: \.self) { gi in
                    JHeading(look: look, title: groups[gi].title)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(groups[gi].sites.indices, id: \.self) { i in siteCard(groups[gi].sites[i]) }
                    }
                }

                // the site repository and the hint, in one card, clear of the tab bar
                VStack(alignment: .leading, spacing: 10) {
                    Button { repo = true } label: { Label("مستودع المواقع", systemImage: "shippingbox").frame(maxWidth: .infinity) }
                        .buttonStyle(JButtonStyle(look: look))
                    Text("اضغط مطوّلًا على موقع لتسجيل الدخول فيه، لو كان يطلب حساب أو يتحقق إنك مو روبوت.").font(JFont.body(13)).foregroundStyle(Color(look.ink2))
                    Text("رابط موقع ما يعرفه جليس؟ الصقه من «إضافة ← رواية من موقع» ويحاول يقرأه لحاله.").font(JFont.body(13)).foregroundStyle(Color(look.ink2))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(look.surface)))
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .padding(.bottom, 130)
            .readableColumn(900)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(look.bg).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .tint(Color(look.primary))
        .preferredColorScheme(look.dark ? .dark : .light)
        .overlay { if let b = busy { BusyCard(look: look, text: b) } }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("تمام", role: .cancel) {} }
        .task { await loadSources(); await SiteRepo.updateIfDue() }
        .sheet(isPresented: $repo, onDismiss: { Task { try? await Task.sleep(nanoseconds: 800_000_000); await loadSources() } }) { SiteRepoSheet(look: look) }
        .modifier(EnglishQuery(request: $toEnglish) { en in run(asked, english: en) })
    }

    // MARK: the sites

    private struct SiteGroup { let title: String; let sites: [[String: Any]] }

    /// Sites you read from first (most novels first), then Arabic sites, then English ones.
    private var siteGroups: [SiteGroup] {
        let counts = Dictionary(grouping: novels.list.filter { !$0.book.isEmpty }, by: \.source).mapValues(\.count)
        let id = { (s: [String: Any]) in s["id"] as? String ?? "" }
        let mine = sources.filter { (counts[id($0)] ?? 0) > 0 }.sorted { (counts[id($0)] ?? 0) > (counts[id($1)] ?? 0) }
        let rest = sources.filter { (counts[id($0)] ?? 0) == 0 }
        let ar = rest.filter { ($0["lang"] as? String) != "en" }
        let en = rest.filter { ($0["lang"] as? String) == "en" }
        return [SiteGroup(title: "مواقع تقرأ منها", sites: mine), SiteGroup(title: "مواقع عربية", sites: ar), SiteGroup(title: "مواقع إنجليزية", sites: en)]
            .filter { !$0.sites.isEmpty }
    }

    private func siteCard(_ s: [String: Any]) -> some View {
        let site = s["id"] as? String ?? "", home = s["home"] as? String ?? ""
        let mine = novels.list.filter { $0.source == site && !$0.book.isEmpty }.count
        return NavigationLink {
            SourceBrowse(look: look, site: site, name: shortName(s))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    SiteIcon(home: home, name: shortName(s), look: look)
                    Spacer(minLength: 0)
                    Text((s["lang"] as? String) == "en" ? "English" : "عربي").font(JFont.body(11, .medium))
                        .foregroundStyle(Color(look.ink2))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(look.surface2)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortName(s)).font(JFont.body(15.5, .semibold)).foregroundStyle(Color(look.ink)).lineLimit(1)
                    Text(URL(string: home)?.host?.replacingOccurrences(of: "www.", with: "") ?? "").font(JFont.body(12)).foregroundStyle(Color(look.ink2)).lineLimit(1)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Text(mine > 0 ? "\(mine) في مكتبتك" : " ").font(JFont.body(12)).foregroundStyle(Color(look.primary))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(look.surface)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(look.line), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { SiteGate.signIn(home) } label: { Label("دخول للموقع", systemImage: "person.crop.circle") }
            Button { NovelBridge.openSite(home) } label: { Label("افتح الموقع", systemImage: "safari") }
        }
    }

    /// the site's name without its tagline («Layl | روايات ويب…» → «Layl»)
    private func shortName(_ s: [String: Any]) -> String {
        let id = s["id"] as? String ?? ""
        if let n = Novel.siteNames[id], n != id { return n }
        let full = s["name"] as? String ?? id
        return full.components(separatedBy: CharacterSet(charactersIn: "|—–")).first?.trimmingCharacters(in: .whitespaces) ?? full
    }

    private func siteName(_ id: String) -> String { sources.first { ($0["id"] as? String) == id }.map(shortName) ?? id }

    private func loadSources() async {
        for _ in 0..<3 {
            sources = await SourceEngine.shared.list()
            if !sources.isEmpty { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: searching every site

    /// every site at once, each with its own chip: asking, found N, nothing, or failed
    private var searchProgress: some View {
        let sites = sources.compactMap { $0["id"] as? String }.filter { siteState[$0] != nil }
        return Flow(spacing: 6) {
            ForEach(sites, id: \.self) { site in
                let st = siteState[site] ?? ""
                HStack(spacing: 5) {
                    if st.isEmpty { ProgressView().controlSize(.mini) }
                    else if st == "!" { Image(systemName: "exclamationmark.triangle").font(.system(size: 11)) }
                    else if st == "-" { Image(systemName: "minus").font(.system(size: 11)) }
                    else { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                    Text(siteName(site) + (Int(st).map { " · \($0)" } ?? "")).font(JFont.body(13))
                }
                .foregroundStyle(Color(st == "!" || st == "-" ? look.ink2 : look.ink))
                .padding(.horizontal, 10).frame(height: 30)
                .background(Capsule().fill(Color(look.surface)))
                .overlay(Capsule().strokeBorder(Color(look.line), lineWidth: 1))
            }
        }
        .animation(.easeOut(duration: 0.2), value: siteState)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !sources.isEmpty else { return }
        english = nil
        let hasEnglishSites = sources.contains { ($0["lang"] as? String) == "en" }
        if SearchWords.hasArabic(q) && hasEnglishSites {
            // the English sites get it in English: translated first (EnglishQuery calls run)
            asked = q
            searching = true
            toEnglish = q
        } else {
            run(q, english: nil)
        }
    }

    private func run(_ q: String, english en: String?) {
        let sites = sources.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        let langs = Dictionary(uniqueKeysWithValues: sources.compactMap { s -> (String, String)? in
            guard let id = s["id"] as? String else { return nil }
            return (id, s["lang"] as? String ?? "ar")
        })
        if let e = en, !e.isEmpty { english = e }
        searchToken += 1
        let mine = searchToken
        searching = true
        nothing = nil
        results = []
        siteState = sites.reduce(into: [:]) { $0[$1] = "" }
        Task { @MainActor in
            // all the sites at once (the network waits overlap); each result takes its site's place in the list
            await withTaskGroup(of: (String, [[String: Any]]?).self) { group in
                for site in sites {
                    let asked = langs[site] == "en" ? (en ?? q) : q
                    group.addTask { @MainActor in
                        var r = try? await SourceEngine.shared.browse(site, kind: "search", page: 1, query: asked)
                        // a site that matches a title's words in order: the other orders of the words, when nothing came
                        if r?.items.isEmpty ?? false {
                            for alt in SearchWords.rotations(asked) {
                                if let a = try? await SourceEngine.shared.browse(site, kind: "search", page: 1, query: alt), !a.items.isEmpty { r = a; break }
                            }
                        }
                        return (site, r?.items)
                    }
                }
                for await (site, items) in group {
                    guard mine == searchToken else { continue }
                    if var items = items, !items.isEmpty {
                        items = SearchWords.ranked(items, for: langs[site] == "en" ? (en ?? q) : q)
                        let rank = { (s: String) in sites.firstIndex(of: s) ?? 0 }
                        let at = results.firstIndex { rank($0.site) > rank(site) } ?? results.count
                        withAnimation(.easeOut(duration: 0.2)) { results.insert((site, items), at: at) }
                        siteState[site] = "\(items.count)"
                    } else {
                        siteState[site] = items == nil ? "!" : "-"
                    }
                }
            }
            guard mine == searchToken else { return }
            searching = false
            if results.isEmpty { nothing = q }
        }
    }

    private func open(_ item: [String: Any]) {
        guard let u = item["url"] as? String else { return }
        busy = "أجيب الرواية"
        Task {
            do { try await NovelBridge.open(u) { s in busy = s } } catch { note = error.localizedDescription }
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
    @State private var filter = BrowseFilter()
    @State private var filtering = false
    /// the list didn't come (or its next page): said under the list with a retry, never as an alert (an alert from a
    /// page in another tab came up over whatever was open)
    @State private var failed: String?
    /// the page the end of the list last asked for on its own (it asks once per page, never in a loop)
    @State private var autoAsked = 0

    var body: some View {
        let shown = items.filter { filter.keeps($0) }
        ScrollView {
            // lazy: the end of the list is made only when it scrolls into view, so it asks for more only then
            LazyVStack(alignment: .leading, spacing: 14) {
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
                    Button { filtering = true } label: {
                        Image(systemName: filter.isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 20)).foregroundStyle(Color(filter.isOn ? look.primary : look.ink2))
                    }
                    .accessibilityLabel("التصفية")
                }
                .padding(.horizontal, 12).frame(minHeight: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(look.surface)))
                if filter.isOn {
                    HStack {
                        Text("يطابق \(shown.count) من \(items.count)").font(JFont.body(13)).foregroundStyle(Color(look.ink2))
                        Spacer()
                        Button("إلغاء التصفية") { filter = BrowseFilter() }.font(JFont.body(13, .medium)).foregroundStyle(Color(look.primary))
                    }
                }
                NovelGrid(look: look, items: shown) { open($0) }
                listEnd
            }
            // (how many novels the list holds, for the walk-through tests: it must not keep loading on its own)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("browse-list")
            .accessibilityValue("\(items.count)")
            .padding(16)
            .padding(.bottom, 120)
            .readableColumn(1000)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(look.bg).ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if let b = busy { BusyCard(look: look, text: b) } }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("تمام", role: .cancel) {} }
        .task { if items.isEmpty && !loading { reload() } }
        .sheet(isPresented: $filtering) { BrowseFilterSheet(look: look, filter: $filter).presentationDetents([.medium, .large]) }
    }

    /// Under the list: loading, what went wrong (with a retry), the next page, or the end.
    @ViewBuilder private var listEnd: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let f = failed {
            VStack(spacing: 10) {
                Text(f).font(JFont.body(13.5)).foregroundStyle(Color(look.ink2)).multilineTextAlignment(.center)
                Button("حاول مرة ثانية") { failed = nil; if items.isEmpty { load() } else { next() } }.buttonStyle(JButtonStyle(look: look))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        } else if more {
            // the next page comes on its own when the end scrolls into view (once per page); the button is for a slow site
            Button("المزيد") { next() }.buttonStyle(JButtonStyle(look: look)).frame(maxWidth: .infinity)
                .onAppear { if autoAsked < page + 1 { autoAsked = page + 1; next() } }
        } else if items.isEmpty {
            Text(kind == "search" ? "ما لقيت شي بهذا الاسم في \(name)" : "ما فيه روايات هنا")
                .font(JFont.body(14)).foregroundStyle(Color(look.ink2)).frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private func reload() { page = 1; items = []; more = false; failed = nil; autoAsked = 0; load() }

    private func next() {
        guard !loading, more, failed == nil else { return }
        page += 1
        load()
    }

    private func load() {
        loading = true
        let (k, p, q) = (kind, page, query)
        Task {
            do {
                let r = try await SourceEngine.shared.browse(site, kind: k, page: p, query: q)
                // the list was switched meanwhile (another tab or search): this answer is stale
                guard k == kind, p == page, q == query else { return }
                let have = Set(items.compactMap { $0["url"] as? String })
                var fresh = r.items.filter { !have.contains(($0["url"] as? String) ?? "") }
                // a search: the closest names first within each page (sites sort theirs by date or by views)
                if k == "search" { fresh = SearchWords.ranked(fresh, for: q) }
                items += fresh
                // a page that brought nothing new is the end, whatever the site says (no asking forever)
                more = r.more && !fresh.isEmpty
            } catch {
                guard k == kind, p == page, q == query else { return }
                if p > 1 {
                    // the page after the last one: some sites answer «not found» there
                    page = p - 1
                    if case NovelError.http(404) = error { more = false } else { failed = "ما جاء الباقي. \(error.localizedDescription)" }
                } else {
                    failed = error.localizedDescription
                }
            }
            loading = false
        }
    }

    private func open(_ item: [String: Any]) {
        guard let u = item["url"] as? String else { return }
        busy = "أجيب الرواية"
        Task {
            do { try await NovelBridge.open(u) { s in busy = s } } catch { note = error.localizedDescription }
            busy = nil
        }
    }
}

/// البحث المتقدّم (س62): what a site's listing shows, narrowed by status, chapter count, genres and rating. Sites
/// give these in each novel's line («مستمرة · 120 فصل · أكشن»), so the filter reads that line; «المزيد» brings more to
/// filter.
struct BrowseFilter: Equatable {
    var status = ""          // "" | ongoing | completed | paused
    var minCh = ""
    var maxCh = ""
    var want = ""            // genres to have, comma separated
    var skip = ""            // genres to leave out
    var minRating = 0.0

    var isOn: Bool { self != BrowseFilter() }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "،" }).map { Words.norm(String($0)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func keeps(_ it: [String: Any]) -> Bool {
        guard isOn else { return true }
        let meta = (it["meta"] as? String) ?? ""
        let text = Words.norm(meta + " " + ((it["title"] as? String) ?? "") + " " + ((it["genres"] as? [String]) ?? []).joined(separator: " "))
        switch status {
        case "ongoing": if text.range(of: "مستمر|ongoing|جاري", options: .regularExpression) == nil { return false }
        case "completed": if text.range(of: "مكتمل|منتهي|complete|finished", options: .regularExpression) == nil { return false }
        case "paused": if text.range(of: "متوقف|hiatus|dropped|paused", options: .regularExpression) == nil { return false }
        default: break
        }
        if !minCh.isEmpty || !maxCh.isEmpty {
            guard let c = (it["chapters"] as? Int) ?? Self.chapters(meta) else { return false }
            if let lo = Int(minCh), c < lo { return false }
            if let hi = Int(maxCh), c > hi { return false }
        }
        for w in Self.words(want) where !text.contains(w) { return false }
        for w in Self.words(skip) where text.contains(w) { return false }
        if minRating > 0 {
            guard let r = (it["rating"] as? Double) ?? Self.rating(meta), r >= minRating else { return false }
        }
        return true
    }

    /// «120 فصل» / «120 chapters»
    static func chapters(_ meta: String) -> Int? {
        guard let r = meta.range(of: "[0-9]+\\s*(فصل|فصول|فصلا|chapters?|ch)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(meta[r].filter(\.isNumber))
    }

    /// «★ 4.5»
    static func rating(_ meta: String) -> Double? {
        guard let r = meta.range(of: "★\\s*[0-9]+(\\.[0-9]+)?", options: .regularExpression) else { return nil }
        return Double(meta[r].filter { $0.isNumber || $0 == "." })
    }
}

struct BrowseFilterSheet: View {
    let look: JLook
    @Binding var filter: BrowseFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("الحالة") {
                    Picker("الحالة", selection: $filter.status) {
                        Text("الكل").tag(""); Text("مستمرة").tag("ongoing"); Text("مكتملة").tag("completed"); Text("متوقفة").tag("paused")
                    }
                    .pickerStyle(.segmented)
                }
                Section("عدد الفصول") {
                    HStack {
                        TextField("من", text: $filter.minCh).keyboardType(.numberPad)
                        Text("إلى").foregroundStyle(.secondary)
                        TextField("إلى", text: $filter.maxCh).keyboardType(.numberPad)
                    }
                }
                Section {
                    TextField("تصنيفات أبيها (أكشن، فانتازيا)", text: $filter.want)
                    TextField("تصنيفات ما أبيها", text: $filter.skip)
                } header: { Text("التصنيفات") } footer: { Text("افصل بينها بفاصلة.") }
                Section("التقييم") {
                    Picker("أقل تقييم", selection: $filter.minRating) {
                        Text("أي تقييم").tag(0.0); Text("★ 3+").tag(3.0); Text("★ 4+").tag(4.0); Text("★ 4.5+").tag(4.5)
                    }
                }
                Section { Text("التصفية على اللي ظاهر من الموقع، و«المزيد» يجيب روايات أكثر تتصفّى معها. بعض المواقع ما تكتب الحالة أو التقييم في قائمتها، فتختفي رواياتها لو اخترتها.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("التصفية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("مسح") { filter = BrowseFilter() } }
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
            }
        }
        .environment(\.layoutDirection, Lang.direction)
        .preferredColorScheme(look.dark ? .dark : .light)
        .tint(Color(look.primary))
    }
}

/// Covers in a grid, three across, with their names under them. Every cell is the same: a cover of one shape (the
/// picture fills it and is cut to it), two lines for the name, one for the details, so the rows line up.
struct NovelGrid: View {
    let look: JLook
    let items: [[String: Any]]
    var open: ([String: Any]) -> Void

    /// each novel by its address (a cell keeps its own novel's picture when the list changes); a repeat gets a number
    private var keyed: [(key: String, item: [String: Any])] {
        var seen = Set<String>()
        return items.enumerated().map { n, it in
            var k = (it["url"] as? String) ?? ""
            if k.isEmpty || seen.contains(k) { k += "#\(n)" }
            seen.insert(k)
            return (k, it)
        }
    }

    var body: some View {
        // three across on a phone, more on an iPad
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 98, maximum: 160), spacing: 14, alignment: .top)], alignment: .leading, spacing: 20) {
            ForEach(keyed, id: \.key) { k in
                NovelCell(look: look, item: k.item) { open(k.item) }
            }
        }
    }
}

private struct NovelCell: View {
    let look: JLook
    let item: [String: Any]
    let tap: () -> Void

    var body: some View {
        let title = item["title"] as? String ?? ""
        let meta = item["meta"] as? String ?? ""
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 7) {
                Color(look.surface2)
                    .aspectRatio(0.68, contentMode: .fit)
                    .overlay {
                        RemoteImage(url: item["cover"] as? String ?? "") {
                            Text(title).font(JFont.display(12, .semibold)).foregroundStyle(Color(look.ink2))
                                .multilineTextAlignment(.center).lineLimit(4).padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(look.line), lineWidth: 0.5))
                    .shadow(color: .black.opacity(look.dark ? 0.35 : 0.12), radius: 5, y: 3)
                Text(title).font(JFont.body(13, .medium)).foregroundStyle(Color(look.ink))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                Text(meta.isEmpty ? " " : meta).font(JFont.body(11)).foregroundStyle(Color(look.ink2)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
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
    /// counts up each time the tab is shown: the list refreshes in place (it is not rebuilt, so it keeps its scroll)
    var visit = 0
    @ObservedObject private var downloads = Downloads.shared
    @State private var rows: [[String: Any]] = []

    var body: some View {
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
        // room for the floating tab bar under the last row
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 96) }
        .environment(\.defaultMinListRowHeight, 52)
        .background(Color(look.bg).ignoresSafeArea())
        .navigationTitle("التحميلات")
        .tint(Color(look.primary))
        .preferredColorScheme(look.dark ? .dark : .light)
        .onAppear(perform: load)
        .onChange(of: visit) { _ in load() }
        // the sizes scan every saved text: refresh every ten chapters and at the end, not after each one
        .onReceive(downloads.$waiting) { w in if w.isEmpty || w.count % 10 == 0 { load() } }
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
    var visit = 0
    @State private var rows: [[String: Any]] = []

    var body: some View {
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
        // room for the floating tab bar under the last row
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 96) }
        .environment(\.defaultMinListRowHeight, 52)
        .background(Color(look.bg).ignoresSafeArea())
        .navigationTitle("السجل")
        .toolbar {
            if !rows.isEmpty { Button("مسح") { DB.shared.run("DELETE FROM history"); load() } }
        }
        .tint(Color(look.primary))
        .preferredColorScheme(look.dark ? .dark : .light)
        .onAppear(perform: load)
        .onChange(of: visit) { _ in load() }
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
        f.locale = Lang.locale
        f.dateFormat = "d MMMM"
        return f.string(from: d)
    }

    private func time(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = "h:mm a"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

// MARK: - التحديثات

/// New chapters from every novel, newest first, by day. Checked when the tab opens (at most once an hour) or on a pull.
struct UpdatesTab: View {
    let look: JLook
    var visit = 0
    @State private var rows: [[String: Any]] = []
    @State private var checking = false
    @State private var status = ""

    var body: some View {
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
        // room for the floating tab bar under the last row
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 96) }
        .environment(\.defaultMinListRowHeight, 52)
        .background(Color(look.bg).ignoresSafeArea())
        .navigationTitle("التحديثات")
        .refreshable { await check() }
        .tint(Color(look.primary))
        .preferredColorScheme(look.dark ? .dark : .light)
        .onAppear(perform: arrive)
        .onChange(of: visit) { _ in arrive() }
    }

    /// shown (first time or again): the list in place, marked seen, a check if the last is over an hour old
    private func arrive() {
        load()
        NewChapters.seen()
        let last = Double(DB.shared.get("updates.checked") ?? "") ?? 0
        if Date().timeIntervalSince1970 - last > 3600 { Task { await check() } }
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
        f.locale = Lang.locale
        return "آخر فحص " + f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }

    private func check() async {
        guard !checking else { return }
        checking = true
        status = "أفحص رواياتك"
        let k = await Novels.shared.checkAll { s in status = s }
        checking = false
        load()
        NewChapters.afterCheck()
        NewChapters.seen()
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
        f.locale = Lang.locale
        f.dateFormat = "d MMMM"
        return f.string(from: d)
    }
}
