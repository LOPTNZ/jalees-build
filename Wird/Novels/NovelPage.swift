import SwiftUI
import UIKit

/// The novel's page: the same layout and look as a book's page in Jalees (cover, status, progress, notes, sessions),
/// with its chapters and highlights. It is a page in the open tab; the book's own data comes from the library.
@MainActor
final class NovelPageModel: ObservableObject {
    @Published var look: JLook
    @Published var novel: Novel
    @Published var chapters: [ChapterRow] = []
    @Published var book: [String: Any] = [:]
    @Published var filter = "all"
    @Published var newestFirst = false
    @Published var selecting = false
    @Published var selA: Int?
    @Published var selB: Int?
    @Published var note: String?
    @Published var checking = false
    @Published var hideNext: Bool { didSet { DB.shared.set("nv.hideNext", hideNext ? "1" : nil) } }
    @Published var markColor = ""
    @Published var allMarks = false
    @Published var namingColors = false
    @Published var rules = false
    /// backup sources (other sites' pages of this novel) and their names
    @Published var mirrors: [Novels.Mirror] = []
    @Published var mirrorBusy: String?
    /// volumes folded away in the chapter list (all but the one being read, at first)
    @Published var folded: Set<String> = []
    private var foldedOnce = false
    var volumeCounts: [String: Int] { Dictionary(grouping: chapters, by: \.volume).mapValues(\.count) }

    func toggleVolume(_ v: String) {
        if folded.contains(v) { folded.remove(v) } else { folded.insert(v) }
    }
    let bookID: String
    var close: () -> Void = {}

    init(novel: Novel, book: String, look: JLook) {
        self.novel = novel
        self.bookID = book
        self.look = look
        hideNext = DB.shared.get("nv.hideNext") == "1"
        reload()
        watcher = NotificationCenter.default.addObserver(forName: .novelPageReload, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private var watcher: NSObjectProtocol?
    deinit { if let w = watcher { NotificationCenter.default.removeObserver(w) } }

    func reload() {
        if let n = Novels.shared.novel(novel.id) { novel = n }
        chapters = Novels.shared.chapters(novel.id)
        if !foldedOnce {
            foldedOnce = true
            let vols = Set(chapters.map(\.volume).filter { !$0.isEmpty })
            let here = currentIndex.map { chapters[$0].volume } ?? chapters.first?.volume ?? ""
            if vols.count > 1 { folded = vols.subtracting([here]) }
        }
        book = NovelLibrary.book(bookID) ?? [:]
        let l = Appearance.shared.look
        if look != l { look = l }
    }

    // book fields
    func s(_ k: String) -> String { book[k] as? String ?? "" }
    var status: String { s("status").isEmpty ? "want" : s("status") }
    var marks: [[String: Any]] { book["marks"] as? [[String: Any]] ?? [] }
    var labels: [[String: Any]] { book["labels"] as? [[String: Any]] ?? [] }
    func label(_ c: String) -> (name: String, hex: String) {
        let l = labels.first { ($0["c"] as? String) == c }
        return ((l?["name"] as? String) ?? "", (l?["hex"] as? String) ?? "#f5c84c")
    }

    var currentIndex: Int? { chapters.firstIndex { $0.id == novel.curChapter } }
    /// an EPUB book rather than a web novel
    /// EPUB books and archives imported from the tool: no site to check or comment on
    var isBook: Bool { novel.source == "epub" || novel.source == "archive" }
    var readCount: Int { chapters.filter(\.read).count }
    var markedChapters: Set<Int> { Set(marks.compactMap { NovelBridge.num($0["ch"]) }) }

    var shown: [ChapterRow] {
        let mk = markedChapters
        var list = chapters
        switch filter {
        case "unread": list = list.filter { !$0.read }
        case "saved": list = list.filter(\.saved)
        case "marked": list = list.filter { mk.contains($0.id) }
        default: break
        }
        return newestFirst ? list.reversed() : list
    }

    var picked: ClosedRange<Int>? {
        guard let a = selA else { return nil }
        let b = selB ?? a
        return min(a, b)...max(a, b)
    }

    func setStatus(_ st: String) {
        NovelLibrary.status(bookID, st)
        reload()
        Haptics.play("sel")
    }

    func read(_ idx: Int?) {
        NovelBridge.openReader(novel: novel.id, book: bookID, index: idx, chapter: nil, paragraph: nil)
    }

    func loadMirrors() { mirrors = Novels.shared.mirrors(novel.id) }

    func addMirror(_ url: String) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        mirrorBusy = "أقرأ المصدر"
        Task {
            do {
                let name = try await Novels.shared.addMirror(novel, url: u) { s in self.mirrorBusy = s }
                note = "انضاف «\(name)» مصدر احتياطي. لو فصل ما انفتح من الأساسي، أجيبه منه."
            } catch { note = error.localizedDescription }
            mirrorBusy = nil
            loadMirrors()
        }
    }

    func move(_ url: String) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        mirrorBusy = "أنقل الرواية"
        Task {
            do {
                try await Novels.shared.move(novel, to: u) { s in self.mirrorBusy = s }
                if let n = Novels.shared.novel(novel.id) { novel = n }
                NovelBridge.sync(novel.id)
                note = "انتقلت الرواية. اللي قريته وحمّلته وظللته باقي، والموقع القديم صار مصدر احتياطي."
            } catch { note = error.localizedDescription }
            mirrorBusy = nil
            loadMirrors()
            reload()
        }
    }

    func check() {
        guard !checking else { return }
        checking = true
        Task {
            do {
                let f = try await Novels.shared.refresh(novel)
                note = f == 0 ? "ما فيه فصول جديدة" : (f == 1 ? "وصل فصل جديد" : "وصلت \(f) فصول جديدة")
                NovelBridge.sync(novel.id)
                NewChapters.afterCheck()
            } catch {
                note = error.localizedDescription
            }
            checking = false
            reload()
        }
    }

    func act(_ what: String, _ ids: [Int]) {
        guard !ids.isEmpty else { return }
        switch what {
        case "download":
            Downloads.shared.add(ids, source: novel.source)
            note = ids.count == 1 ? "الفصل في قائمة التحميل" : "\(ids.count) فصول في قائمة التحميل"
        case "undownload": Novels.shared.undownload(ids)
        case "read": Novels.shared.setRead(ids, true)
        case "unread": Novels.shared.setRead(ids, false)
        default: break
        }
        selecting = false; selA = nil; selB = nil
        NovelBridge.sync(novel.id)
        reload()
        Haptics.play("success")
    }

    func pick(_ i: Int) {
        if selA == nil || selB != nil { selA = i; selB = nil } else { selB = i }
        Haptics.play("sel")
    }

    func openMark(_ m: [String: Any]) {
        NovelBridge.openReader(novel: novel.id, book: bookID, index: nil, chapter: NovelBridge.num(m["ch"]), paragraph: NovelBridge.num(m["p"]))
    }

    func openNotebook(_ kind: String) {
        Router.shared.openNotebook(book: bookID, kind: kind)
    }

    /// The library's own form for a book's name, author and cover (what the owner changes stays).
    func edit() {
        Router.shared.push(.book(bookID))
    }

    func saveNames(_ names: [String: String]) {
        NovelLibrary.labelsSet(names)
        reload()
    }
}

struct NovelPageView: View {
    @ObservedObject var model: NovelPageModel
    @ObservedObject private var downloads = Downloads.shared
    @State private var jump = ""
    @State private var wide = false

    private var L: JLook { model.look }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    topBar
                    hero
                    if !model.novel.summary.isEmpty { summary }
                    statusAndProgress
                    if downloads.active { downloadsCard }
                    highlights
                    notebook
                    sessions
                    about
                    if model.novel.source != "epub" && model.novel.source != "sample" { sourcesSection }
                    chaptersHeader(proxy)
                    chapterRows
                    Color.clear.frame(height: model.selecting ? 120 : 24)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(L.bg).ignoresSafeArea())
        .overlay(alignment: .bottom) { if model.selecting { selectionBar } }
        .environment(.layoutDirection, Lang.direction)
        .environment(\.locale, Lang.locale)
        .preferredColorScheme(L.dark ? .dark : .light)
        .tint(Color(L.primary))
        .alert(model.note ?? "", isPresented: Binding(get: { model.note != nil }, set: { if !$0 { model.note = nil } })) {
            Button("تمام", role: .cancel) {}
        }
        .sheet(isPresented: $model.namingColors) { ColorNames(model: model) }
        .sheet(isPresented: $model.rules) {
            NavigationStack { ReplaceRulesView(scope: String(model.novel.id), title: model.novel.title) }
                .environment(.layoutDirection, Lang.direction).preferredColorScheme(L.dark ? .dark : .light)
        }
        .sheet(isPresented: $exportEpub) {
            EpubExportSheet(novel: model.novel).environment(\.look, L).environment(.layoutDirection, Lang.direction)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: top

    private var topBar: some View {
        ZStack {
            Text("جَليس").font(JFont.display(26, .bold)).foregroundStyle(Color(L.ink))
            HStack {
                Button(action: model.close) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.backward").font(.system(size: 14, weight: .semibold))
                        Text("المكتبة").font(JFont.body(15))
                    }
                    .foregroundStyle(Color(L.ink2))
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.top, 4)
    }

    private var bookColor: UIColor { UIColor.hslParts(model.s("hue")) ?? L.primary }

    private var hero: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.s("title").isEmpty ? model.novel.title : model.s("title"))
                    .font(JFont.display(26, .bold)).foregroundStyle(Color(L.ink))
                    .fixedSize(horizontal: false, vertical: true)
                let by = [model.novel.author.isEmpty ? "" : "بقلم \(model.novel.author)", model.novel.translator.isEmpty ? "" : "ترجمة \(model.novel.translator)"].filter { !$0.isEmpty }
                if !by.isEmpty {
                    Text(by.joined(separator: " · ")).font(JFont.body(15)).foregroundStyle(Color(L.ink2)).lineLimit(3)
                }
                Flow(spacing: 6) {
                    if model.isBook {
                        JMeta(look: L, text: "كتاب EPUB", symbol: "doc.richtext")
                    } else {
                        JMeta(look: L, text: "رواية ويب", symbol: "globe")
                        JMeta(look: L, text: model.novel.complete ? "مكتملة" : "مستمرة")
                        JMeta(look: L, text: model.novel.siteName)
                    }
                    ForEach(model.novel.genres.prefix(5), id: \.self) { g in JMeta(look: L, text: g) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CoverView(id: model.s("cover"), title: model.novel.title, author: model.novel.author, color: bookColor)
                .frame(width: 116, height: 116 / 0.66)
                .shadow(color: .black.opacity(0.55), radius: 11, y: 10)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            LinearGradient(colors: [Color(bookColor).opacity(0.28), Color(L.bg).opacity(0)], startPoint: .top, endPoint: .bottom)
                .padding(.horizontal, -16)
        )
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.novel.summary).font(JFont.body(15)).foregroundStyle(Color(L.ink2)).lineLimit(wide ? nil : 4)
            Button(wide ? "أقل" : "المزيد") { withAnimation(.easeOut(duration: 0.2)) { wide.toggle() } }
                .font(JFont.body(14, .medium)).foregroundStyle(Color(L.primary))
        }
    }

    private var statusAndProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                ForEach([("want", "أريد"), ("reading", "أقرأه"), ("done", "أنهيته"), ("dnf", "توقفت")], id: \.0) { k, t in
                    let on = model.status == k
                    Button { model.setStatus(k) } label: {
                        Text(t).font(JFont.body(15, on ? .medium : .regular))
                            .foregroundStyle(Color(on ? L.onPrimary : L.ink))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(on ? Color(L.primary) : Color.clear)
                    }
                    .buttonStyle(.plain)
                    if k != "dnf" { Rectangle().fill(Color(L.line)).frame(width: 1, height: 42) }
                }
            }
            .background(Color(L.surface))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))

            let total = model.chapters.count, read = model.readCount
            HStack {
                Text("ف \(read) / \(total)").font(JFont.body(15, .medium)).foregroundStyle(Color(L.ink)).monospacedDigit()
                Spacer()
                if total > 0 { Text("\(Int((Double(read) / Double(total) * 100).rounded()))%").font(JFont.body(13)).foregroundStyle(Color(L.ink2)).monospacedDigit() }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(L.surface2))
                    Capsule().fill(Color(L.primary)).frame(width: total > 0 ? g.size.width * CGFloat(read) / CGFloat(total) : 0)
                }
            }
            .frame(height: 6)
            .environment(.layoutDirection, Lang.direction)

            HStack(spacing: 10) {
                Button { model.read(nil) } label: {
                    Text(model.currentIndex.map { "تابع القراءة · \(model.chapters[$0].label)" } ?? "ابدأ القراءة").frame(maxWidth: .infinity)
                }
                .buttonStyle(JButtonStyle(look: L, primary: true))
                .disabled(model.chapters.isEmpty)
                if !model.isBook {
                    Button { model.check() } label: {
                        if model.checking { ProgressView().frame(width: 60) } else { Text("الجديد") }
                    }
                    .buttonStyle(JButtonStyle(look: L))
                    .accessibilityLabel("تحقق من فصول جديدة")
                    alertMenu
                }
            }
        }
    }

    /// «نبهني»: a notification for this novel once this many new chapters have gathered (س45.1، س60).
    @State private var alertN = -1

    private var alertMenu: some View {
        let id = model.novel.id
        let n = alertN >= 0 ? alertN : NewChapters.threshold(id)
        return Menu {
            Picker("نبهني بالفصول الجديدة", selection: Binding(get: { n }, set: { v in NewChapters.setThreshold(id, v); alertN = v; Haptics.play("sel") })) {
                Text("بدون تنبيه").tag(0)
                ForEach(NewChapters.thresholds, id: \.self) { k in
                    Text(k == 1 ? "مع كل فصل جديد" : "لما يتجمع \(k) فصول").tag(k)
                }
            }
        } label: {
            Image(systemName: n > 0 ? "bell.fill" : "bell").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(n > 0 ? L.primary : L.ink))
                .frame(width: 48, height: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        }
        .accessibilityLabel(n > 0 ? "التنبيه شغال" : "نبهني بالفصول الجديدة")
    }

    @State private var exportEpub = false
    @State private var askMirror = false
    @State private var askMove = false
    @State private var linkText = ""

    /// «المصادر»: the main site, backup sources, and moving the novel (س29).
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            JHeading(look: L, title: "المصادر")
            HStack {
                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color(L.primary))
                Text(model.novel.siteName).font(JFont.body(14.5, .semibold)).foregroundStyle(Color(L.ink))
                Text("الأساسي").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
                Spacer()
            }
            ForEach(model.mirrors, id: \.url) { m in
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12)).foregroundStyle(Color(L.ink2))
                    Text(URL(string: m.url)?.host ?? m.source).font(JFont.body(14)).foregroundStyle(Color(L.ink))
                    Text("احتياطي").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
                    Spacer()
                    Button { Novels.shared.removeMirror(model.novel.id, url: m.url); model.loadMirrors() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(L.ink2)) }
                        .buttonStyle(.plain).accessibilityLabel("شيل المصدر")
                }
            }
            if let b = model.mirrorBusy {
                HStack(spacing: 8) { ProgressView(); Text(b).font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
            }
            HStack(spacing: 8) {
                Button { linkText = ""; askMirror = true } label: { Label("أضف مصدر احتياطي", systemImage: "plus") }.buttonStyle(JButtonStyle(look: L, small: true))
                Button { linkText = ""; askMove = true } label: { Label("انقلها لموقع ثاني", systemImage: "arrow.right.arrow.left") }.buttonStyle(JButtonStyle(look: L, small: true))
            }
            Text("الاحتياطي يجيب الفصل لو ما انفتح من الأساسي، أو لما تختار «الفصل من مصدر ثاني» في القارئ.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
        }
        .onAppear { model.loadMirrors() }
        .alert("مصدر احتياطي", isPresented: $askMirror) {
            TextField("رابط نفس الرواية في موقع ثاني", text: $linkText).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("أضف") { model.addMirror(linkText) }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("الصق رابط صفحة الرواية (أو أي فصل منها) في الموقع الثاني.") }
        .alert("انقل الرواية لموقع ثاني", isPresented: $askMove) {
            TextField("رابط الرواية في الموقع الجديد", text: $linkText).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("انقلها") { model.move(linkText) }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("تقدّمك وتحميلك وتظليلك يبقون، والفصول تتطابق بأرقامها.") }
    }

    private var downloadsCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("يحمّل الفصول · باقي \(downloads.waiting.count)").font(JFont.body(14)).foregroundStyle(Color(L.ink))
            Spacer()
            Button("إيقاف") { downloads.cancel() }.font(JFont.body(14, .medium)).foregroundStyle(Color(L.primary))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface)))
    }

    // MARK: highlights

    private var highlights: some View {
        let all = model.marks
        let counts = Dictionary(grouping: all, by: { ($0["color"] as? String) ?? "yellow" }).mapValues(\.count)
        let list = model.markColor.isEmpty ? all : all.filter { ($0["color"] as? String) == model.markColor }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                JHeading(look: L, title: "التظليلات", count: all.count)
                Spacer()
                Button("أسماء الألوان") { model.namingColors = true }.font(JFont.body(14, .medium)).foregroundStyle(Color(L.primary))
            }
            if all.isEmpty {
                Text("حدد نص وأنت تقرأ واختر «تظليل». لكل لون اسم تختاره، مثل «معلومة» أو «مضحك»، وكل اللي ظلّلته يتجمّع هنا.")
                    .font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            } else {
                Flow(spacing: 8) {
                    JChip(look: L, text: "الكل", on: model.markColor.isEmpty) { model.markColor = "" }
                    ForEach(model.labels.indices, id: \.self) { i in
                        let l = model.labels[i]
                        let c = l["c"] as? String ?? ""
                        if let n = counts[c] {
                            let name = (l["name"] as? String) ?? ""
                            JChip(look: L, text: name.isEmpty ? ((l["plain"] as? String) ?? c) : name, count: n,
                                  dot: UIColor.css(l["hex"] as? String ?? ""), on: model.markColor == c) { model.markColor = c }
                        }
                    }
                }
                ForEach(Array(list.prefix(model.allMarks ? 300 : 4).enumerated()), id: \.offset) { _, m in
                    Button { model.openMark(m) } label: { MarkCard(look: L, mark: m, label: model.label((m["color"] as? String) ?? "")) }
                        .buttonStyle(.plain)
                }
                if list.count > 4 && !model.allMarks {
                    Button("عرض الكل (\(list.count))") { model.allMarks = true }.buttonStyle(JButtonStyle(look: L, small: true))
                }
            }
        }
    }

    // MARK: notebook, sessions, about

    private var notebook: some View {
        let counts = model.book["counts"] as? [String: Any] ?? [:]
        let kinds: [(String, String, String, String)] = [("quote", "الاقتباسات", "quotes", "text.quote"), ("thought", "الأفكار", "thoughts", "lightbulb"),
                                                         ("char", "الشخصيات", "charsTop", "person.2"), ("word", "الكلمات", "words", "character.book.closed")]
        return VStack(alignment: .leading, spacing: 10) {
            JHeading(look: L, title: "دفتري")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(kinds, id: \.0) { k, title, listKey, icon in
                    let n = NovelBridge.num(counts[k])
                    let first = ((model.book[listKey] as? [[String: Any]]) ?? []).first?["text"] as? String
                    Button { model.openNotebook(k) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Color(L.primary))
                                Text(title).font(JFont.body(14, .medium)).foregroundStyle(Color(L.ink))
                                Spacer()
                                Text("\(n)").font(JFont.body(13)).foregroundStyle(Color(L.ink2)).monospacedDigit()
                            }
                            Text(first ?? "ما فيه شي بعد").font(JFont.body(13)).foregroundStyle(Color(L.ink2)).lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("تضيف من القارئ: حدد النص واختر «للدفتر».").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
        }
    }

    private var sessions: some View {
        let s = model.book["sessions"] as? [String: Any] ?? [:]
        let count = NovelBridge.num(s["count"]), mins = NovelBridge.num(s["minutes"])
        let last = s["last"] as? [[String: Any]] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            JHeading(look: L, title: "الجلسات", count: count)
            if count == 0 {
                Text("الجلسة تبدأ لحالها لما تفتح فصل، وتنحسب هنا وفي أهدافك.").font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            } else {
                Text("\(minutesText(mins)) في \(count) جلسة").font(JFont.body(15, .medium)).foregroundStyle(Color(L.ink))
                ForEach(Array(last.prefix(3).enumerated()), id: \.offset) { _, x in
                    HStack {
                        Text(dateText(NovelBridge.num(x["start"]))).font(JFont.body(14)).foregroundStyle(Color(L.ink))
                        Spacer()
                        Text(minutesText(Int((x["minutes"] as? Double) ?? Double(NovelBridge.num(x["minutes"]))))).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
                        let u = NovelBridge.num(x["units"])
                        if u > 0 { Text("· \(u) فصل").font(JFont.body(14)).foregroundStyle(Color(L.ink2)) }
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            JHeading(look: L, title: "عن الرواية")
            if !model.isBook {
                HStack(spacing: 8) {
                Button { model.edit() } label: { Label("تعديل الاسم والغلاف", systemImage: "pencil") }.buttonStyle(JButtonStyle(look: L, small: true))
                Button { model.rules = true } label: { Label("قواعد الاستبدال", systemImage: "textformat.alt") }.buttonStyle(JButtonStyle(look: L, small: true))
            }
            Button { exportEpub = true } label: { Label("تصدير EPUB لكيندل", systemImage: "square.and.arrow.up.on.square") }
                .buttonStyle(JButtonStyle(look: L, small: true))
            Button { NovelBridge.openSite(model.novel.url) } label: {
                    Label("صفحة الرواية في \(model.novel.siteName)", systemImage: "safari")
                }
                .buttonStyle(JButtonStyle(look: L, small: true))
            }
        }
    }

    // MARK: chapters

    private func chaptersHeader(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                JHeading(look: L, title: model.isBook ? "الأقسام" : "الفصول", count: model.chapters.count)
                Spacer()
                if let i = model.currentIndex {
                    JCircle(look: L, symbol: "scope", label: "الفصل الحالي") {
                        model.filter = "all"
                        withAnimation { proxy.scrollTo(model.chapters[i].id, anchor: .center) }
                    }
                }
                JCircle(look: L, symbol: model.newestFirst ? "arrow.up" : "arrow.down", label: model.newestFirst ? "الأقدم أولًا" : "الأحدث أولًا") { model.newestFirst.toggle() }
                JCircle(look: L, symbol: "checkmark.circle", on: model.selecting, label: "تحديد مجموعة فصول") {
                    model.selecting.toggle(); model.selA = nil; model.selB = nil
                }
                Menu {
                    Toggle("أخفِ عناوين الفصول الجاية", isOn: $model.hideNext)
                    Button { model.act("download", nextIDs(10)) } label: { Label("حمّل العشرة الجاية", systemImage: "arrow.down.circle") }
                    Button { model.act("download", model.chapters.filter { !$0.saved }.map(\.id)) } label: { Label("حمّل كل الفصول", systemImage: "arrow.down.circle.fill") }
                    Button(role: .destructive) { model.act("undownload", model.chapters.filter { $0.read && $0.saved }.map(\.id)) } label: { Label("احذف تحميل المقروء", systemImage: "trash") }
                    if let i = model.currentIndex {
                        Button { model.act("read", model.chapters[..<i].filter { !$0.read }.map(\.id)) } label: { Label("علّم كل اللي قبل الحالي مقروء", systemImage: "checkmark") }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).foregroundStyle(Color(L.ink))
                        .frame(width: 36, height: 36).background(Circle().fill(Color(L.surface))).overlay(Circle().strokeBorder(Color(L.line), lineWidth: 1))
                }
                .accessibilityLabel("خيارات الفصول")
            }
            let mk = model.markedChapters
            Flow(spacing: 8) {
                JChip(look: L, text: "الكل", on: model.filter == "all") { model.filter = "all" }
                JChip(look: L, text: "غير المقروء", count: model.chapters.filter { !$0.read }.count, on: model.filter == "unread") { model.filter = "unread" }
                JChip(look: L, text: "المحمّل", count: model.chapters.filter(\.saved).count, on: model.filter == "saved") { model.filter = "saved" }
                JChip(look: L, text: "فيه تظليل", count: model.chapters.filter { mk.contains($0.id) }.count, on: model.filter == "marked") { model.filter = "marked" }
            }
            HStack(spacing: 8) {
                TextField("روح لفصل رقم…", text: $jump)
                    .keyboardType(.numberPad)
                    .font(JFont.body(15))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                Button("اذهب") { go(proxy) }.buttonStyle(JButtonStyle(look: L, small: true)).disabled(jump.isEmpty)
            }
            if model.selecting {
                Text(model.selA == nil ? "اضغط أول فصل في المجموعة." : (model.selB == nil ? "اضغط آخر فصل." : "\(model.picked?.count ?? 0) فصول محددة."))
                    .font(JFont.body(14)).foregroundStyle(Color(L.primary))
            }
        }
    }

    private func nextIDs(_ n: Int) -> [Int] {
        let from = (model.currentIndex ?? -1) + 1
        return model.chapters.dropFirst(max(0, from)).prefix(n).filter { !$0.saved }.map(\.id)
    }

    private func go(_ proxy: ScrollViewProxy) {
        let q = jump.trimmingCharacters(in: .whitespaces)
        guard let c = model.chapters.first(where: { $0.num == q }) ?? model.chapters.first(where: { String($0.idx + 1) == q }) else {
            model.note = "ما لقيت الفصل \(q)"
            return
        }
        model.filter = "all"
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(c.id, anchor: .center) } }
    }

    private var chapterRows: some View {
        let list = model.shown
        let cur = model.currentIndex ?? -1
        let mk = model.markedChapters
        let range = model.picked
        let showVol = !model.newestFirst && model.filter == "all"
        return VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { k, c in
                if showVol, !c.volume.isEmpty, k == 0 || list[k - 1].volume != c.volume {
                    let open = !model.folded.contains(c.volume)
                    Button { withAnimation(.easeOut(duration: 0.2)) { model.toggleVolume(c.volume) } } label: {
                        HStack(spacing: 8) {
                            Text(c.volume).font(JFont.display(16, .semibold)).foregroundStyle(Color(L.ink)).multilineTextAlignment(.leading)
                            Spacer(minLength: 6)
                            Text("\(model.volumeCounts[c.volume] ?? 0)").font(JFont.body(13)).foregroundStyle(Color(L.ink2)).monospacedDigit()
                            Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(L.ink2))
                                .rotationEffect(.degrees(open ? 0 : 90))
                        }
                        .padding(.horizontal, 12).frame(minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10).padding(.bottom, 4)
                }
                if !(showVol && model.folded.contains(c.volume)) {
                ChapterRowView(look: L, ch: c, current: c.idx == cur, marked: mk.contains(c.id),
                               hideTitle: model.hideNext && cur >= 0 && c.idx > cur + 1,
                               picked: range?.contains(c.idx) ?? false)
                    .id(c.id)
                    .contentShape(Rectangle())
                    .onTapGesture { if model.selecting { model.pick(c.idx) } else { model.read(c.idx) } }
                    .contextMenu {
                        Button { model.read(c.idx) } label: { Label("افتح", systemImage: "book") }
                        if c.saved {
                            Button(role: .destructive) { model.act("undownload", [c.id]) } label: { Label("احذف التحميل", systemImage: "trash") }
                        } else {
                            Button { model.act("download", [c.id]) } label: { Label("حمّل", systemImage: "arrow.down.circle") }
                        }
                        Button { model.act(c.read ? "unread" : "read", [c.id]) } label: { Label(c.read ? "علّمه غير مقروء" : "علّمه مقروء", systemImage: c.read ? "circle" : "checkmark.circle") }
                        Button { model.act("read", model.chapters[..<c.idx].filter { !$0.read }.map(\.id)) } label: { Label("علّم كل اللي قبله مقروء", systemImage: "checkmark") }
                        Button { NovelBridge.openSite(c.url) } label: { Label("افتحه في الموقع", systemImage: "safari") }
                    }
                Rectangle().fill(Color(L.line).opacity(0.6)).frame(height: 0.5)
                }
            }
        }
    }

    private var selectionBar: some View {
        let ids = model.picked.map { r in model.chapters.filter { r.contains($0.idx) }.map(\.id) } ?? []
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { model.act("download", ids) } label: { Label("تحميل", systemImage: "arrow.down.circle") }.buttonStyle(JButtonStyle(look: L, primary: true, small: true))
                Button { model.act("undownload", ids) } label: { Label("حذف", systemImage: "trash") }.buttonStyle(JButtonStyle(look: L, small: true))
                Button { model.act("read", ids) } label: { Text("مقروءة") }.buttonStyle(JButtonStyle(look: L, small: true))
                Button { model.act("unread", ids) } label: { Text("غير مقروءة") }.buttonStyle(JButtonStyle(look: L, small: true))
            }
            .disabled(ids.isEmpty)
            Button("إلغاء التحديد") { model.selecting = false; model.selA = nil; model.selB = nil }
                .font(JFont.body(14, .medium)).foregroundStyle(Color(L.primary))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(L.surface)).shadow(color: .black.opacity(0.35), radius: 16, y: 6))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func minutesText(_ m: Int) -> String {
        if m < 60 { return m == 1 ? "دقيقة" : "\(m) دقيقة" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) ساعة" : "\(h) ساعة و\(r) دقيقة"
    }

    private func dateText(_ ms: Int) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = "d MMMM"
        return f.string(from: d)
    }
}

// MARK: - pieces

struct ChapterRowView: View {
    let look: JLook
    let ch: ChapterRow
    let current: Bool
    let marked: Bool
    let hideTitle: Bool
    let picked: Bool

    var body: some View {
        HStack(spacing: 10) {
            if current { Capsule().fill(Color(look.primary)).frame(width: 3, height: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(ch.label).font(JFont.body(15, current ? .semibold : .medium))
                if ch.numbered, !ch.title.isEmpty, !hideTitle {
                    Text(ch.title).font(JFont.body(13)).foregroundStyle(Color(look.ink2)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if marked { Circle().fill(Color(look.primary)).frame(width: 7, height: 7).accessibilityLabel("فيه تظليل") }
            if ch.locked && !ch.saved { Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(Color(look.ink2)).accessibilityLabel("مقفل في الموقع") }
            if ch.saved { Image(systemName: "arrow.down.circle.fill").font(.system(size: 13)).foregroundStyle(Color(look.ink2)).accessibilityLabel("محمّل") }
            if !ch.date.isEmpty { Text(ChapterRowView.shortDate(ch.date)).font(JFont.body(12)).foregroundStyle(Color(look.ink2)).monospacedDigit() }
        }
        .foregroundStyle(Color(look.ink).opacity(ch.read && !current ? 0.5 : 1))
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .background(picked ? Color(look.primary).opacity(0.18) : (current ? Color(look.surface2) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func shortDate(_ iso: String) -> String {
        let p = iso.prefix(10).split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return "" }
        return "\(d)/\(m)/\(y % 100)"
    }
}

struct MarkCard: View {
    let look: JLook
    let mark: [String: Any]
    let label: (name: String, hex: String)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(UIColor.css(label.hex) ?? .systemYellow)).frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text((mark["text"] as? String) ?? "").font(JFont.body(15)).foregroundStyle(Color(look.ink)).lineLimit(4)
                if let n = mark["note"] as? String, !n.isEmpty {
                    Text(n).font(JFont.body(14)).foregroundStyle(Color(look.ink2)).lineLimit(3)
                }
                Text([label.name, (mark["chLabel"] as? String) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(JFont.body(12)).foregroundStyle(Color(look.ink2))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(look.surface)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(look.line), lineWidth: 1))
    }
}

/// The book's cover from the library's images, or a drawn one like the web's.
struct CoverView: View {
    let id: String
    let title: String
    let author: String
    let color: UIColor

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(color), Color(color).opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.28), lineWidth: 1).padding(7)
            VStack {
                Spacer()
                Text(title).font(JFont.display(15, .semibold)).foregroundStyle(Color.white).multilineTextAlignment(.center).padding(.horizontal, 10)
                Spacer()
                Text(author).font(JFont.body(10)).foregroundStyle(Color.white.opacity(0.85)).padding(.bottom, 12)
            }
            if !id.isEmpty, let img = Store.shared.image(id) {
                Image(uiImage: img).resizable().scaledToFill()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Names for the highlight colours (معلومة، مضحك، تلميح…).
struct ColorNames: View {
    @ObservedObject var model: NovelPageModel
    @State private var names: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let L = model.look
        NavigationStack {
            List {
                Section {
                    ForEach(model.labels.indices, id: \.self) { i in
                        let l = model.labels[i]
                        let c = l["c"] as? String ?? ""
                        HStack(spacing: 12) {
                            Circle().fill(Color(UIColor.css(l["hex"] as? String ?? "") ?? .systemYellow)).frame(width: 18, height: 18)
                            TextField((l["plain"] as? String) ?? c, text: Binding(get: { names[c] ?? "" }, set: { names[c] = $0 }))
                                .font(JFont.body(16))
                        }
                    }
                } footer: {
                    Text("سمّ كل لون باللي يعنيه لك. الاسم يطلع وأنت تظلّل، وهنا، وفي دفتري.").font(JFont.body(13))
                }
            }
            .navigationTitle("أسماء ألوان التظليل")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("حفظ") { model.saveNames(names); dismiss() } }
            }
            .onAppear {
                for l in model.labels { if let c = l["c"] as? String { names[c] = (l["name"] as? String) ?? "" } }
            }
        }
        .environment(.layoutDirection, Lang.direction)
        .preferredColorScheme(L.dark ? .dark : .light)
        .tint(Color(L.primary))
    }
}

/// The novel's page as a page of the open tab: its own bar on top, the edge swipe to go back.
struct NovelPageScreen: View {
    let novelID: Int
    let bookID: String

    var body: some View {
        if let n = Novels.shared.novel(novelID) {
            NovelPageHolder(novel: n, bookID: bookID)
        } else {
            Text("ما لقيت الرواية").font(JFont.body(16)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NovelPageHolder: View {
    @StateObject private var model: NovelPageModel
    @Environment(\.dismiss) private var dismiss

    init(novel: Novel, bookID: String) {
        _model = StateObject(wrappedValue: NovelPageModel(novel: novel, book: bookID, look: Appearance.shared.look))
    }

    var body: some View {
        NovelPageView(model: model)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { model.close = { dismiss() }; model.reload() }
    }
}
