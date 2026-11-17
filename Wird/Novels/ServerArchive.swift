import SwiftUI

// The server's archive from the phone (server/jalees-server.js v3): archiving a whole site, chosen novels, the jobs
// with their progress, the followed novels, storage, and pulling new chapters from the server into the library.

// MARK: - pure helpers (WirdTests/ServerArchiveTests.swift)

enum ArchiveFormat {
    /// «12.3 MB» (Western digits, always).
    static func bytes(_ n: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, n), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        let s = i == 0 ? String(Int(v)) : String(format: "%.1f", v)
        return s + " " + units[i]
    }

    /// «نحو 3 ساعة» style: the biggest unit that fits.
    static func duration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "أقل من دقيقة" }
        if s < 3600 { return "\(Int((s / 60).rounded())) دقيقة" }
        if s < 86_400 { return "\(Int((s / 3600).rounded())) ساعة" }
        return "\(Int((s / 86_400).rounded())) يوم"
    }

    /// 0...1
    static func fraction(_ done: Double, _ total: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, done / total))
    }

    /// Requests a minute at a pace in milliseconds (a number for the pace chooser's note).
    static func perMinute(paceMs: Double) -> Int { paceMs > 0 ? Int((60_000 / paceMs).rounded()) : 0 }

    /// The addresses of a server's chapter list that the phone has no row for.
    static func missing(known: Set<String>, incoming: [String]) -> [String] {
        var seen = known
        return incoming.filter { seen.insert($0).inserted }
    }

    /// A multi-select: toggles one address in the set.
    static func toggle(_ set: inout Set<String>, _ url: String) {
        if set.contains(url) { set.remove(url) } else { set.insert(url) }
    }

    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
}

// MARK: - what the server tells

struct ServerJob: Identifiable, Equatable {
    var id: String
    var type: String
    var site: String
    var label: String
    var state: String          // running, queued, paused, done, cancelled
    var pausedBy: String
    var discovering: Bool
    var page: Int
    var waiting: Int
    var failed: Int
    var found: Int
    var added: Int
    var novelsDone: Int
    var chaptersFetched: Int
    var chaptersTotal: Int
    var errors: Int
    var bytes: Double
    var eta: Double?
    var current: String
    var lastError: String

    init(_ o: [String: Any]) {
        let st = (o["stats"] as? [String: Any]) ?? [:]
        id = (o["id"] as? String) ?? ""
        type = (o["type"] as? String) ?? ""
        site = (o["site"] as? String) ?? ""
        label = (o["label"] as? String) ?? ""
        state = (o["state"] as? String) ?? ""
        pausedBy = (o["pausedBy"] as? String) ?? ""
        discovering = (o["discovering"] as? Bool) ?? false
        page = Int(ArchiveFormat.num(o["page"]))
        waiting = Int(ArchiveFormat.num(o["waiting"]))
        failed = Int(ArchiveFormat.num(o["failed"]))
        found = Int(ArchiveFormat.num(st["found"]))
        added = Int(ArchiveFormat.num(st["added"]))
        novelsDone = Int(ArchiveFormat.num(st["novelsDone"]))
        chaptersFetched = Int(ArchiveFormat.num(st["chaptersFetched"]))
        chaptersTotal = Int(ArchiveFormat.num(st["chaptersTotal"]))
        errors = Int(ArchiveFormat.num(st["errors"]))
        bytes = ArchiveFormat.num(st["bytes"])
        eta = (o["eta"] as? NSNumber)?.doubleValue
        current = ((o["current"] as? [String: Any])?["title"] as? String) ?? ""
        lastError = (st["lastError"] as? String) ?? ""
    }

    var active: Bool { state == "running" || state == "queued" || state == "paused" }
    var title: String {
        let name = label.isEmpty ? (Novel.siteNames[site] ?? site) : label
        return type == "site" ? "موقع كامل: \(name)" : "روايات مختارة: \(name)"
    }
    /// novels done of novels found (the job's main bar)
    var fraction: Double { ArchiveFormat.fraction(Double(novelsDone), Double(max(found, 1))) }
    var stateText: String {
        switch state {
        case "running": return discovering ? "يقرأ قائمة الموقع (صفحة \(page))" : "يشتغل"
        case "queued": return "ينتظر دوره"
        case "paused":
            switch pausedBy {
            case "blocked": return "وقف: الموقع يرفض أو يطلب تحقق"
            case "disk": return "وقف: المساحة قليلة"
            case "error": return "وقف بسبب أخطاء"
            default: return "موقوف"
            }
        case "done": return "خلص"
        case "cancelled": return "ملغي"
        default: return state
        }
    }
}

struct ServerNovel: Identifiable, Equatable {
    var id: String
    var url: String
    var title: String
    var site: String
    var chapters: Int
    var saved: Int
    var checked: Double
    var lastNew: Double
    var paused: Bool
    var mode: String
    var complete: Bool
    var newCount: Int
    var updatedCount: Int

    init(_ o: [String: Any]) {
        id = (o["id"] as? String) ?? ""
        url = (o["url"] as? String) ?? ""
        title = (o["title"] as? String) ?? ""
        site = (o["site"] as? String) ?? ""
        chapters = Int(ArchiveFormat.num(o["chapters"]))
        saved = Int(ArchiveFormat.num(o["saved"]))
        checked = ArchiveFormat.num(o["checked"])
        lastNew = ArchiveFormat.num(o["lastNew"])
        paused = (o["paused"] as? Bool) ?? false
        mode = (o["mode"] as? String) ?? "library"
        complete = (o["complete"] as? Bool) ?? false
        newCount = Int(ArchiveFormat.num(o["newCount"]))
        updatedCount = Int(ArchiveFormat.num(o["updatedCount"]))
    }
}

struct ServerSite: Identifiable, Equatable {
    var id: String
    var name: String
    var novels: Int
    var archived: Int
    var job: ServerJob?

    init(_ o: [String: Any]) {
        id = (o["id"] as? String) ?? ""
        name = (o["name"] as? String) ?? id
        novels = Int(ArchiveFormat.num(o["novels"]))
        archived = Int(ArchiveFormat.num(o["archived"]))
        job = (o["job"] as? [String: Any]).map(ServerJob.init)
    }
}

// MARK: - the calls

extension ServerLink {
    private static func json(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: Double = 30) async throws -> [String: Any] {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let d = try await request(path, method: method, body: data, timeout: timeout)
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
    }

    private static func list(_ path: String, timeout: Double = 30) async throws -> [[String: Any]] {
        let d = try await request(path, timeout: timeout)
        return ((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? []
    }

    static func status() async throws -> [String: Any] { try await json("/status") }
    static func jobs() async throws -> [ServerJob] { try await list("/jobs").map(ServerJob.init) }
    static func sites() async throws -> [ServerSite] { try await list("/sites").map(ServerSite.init) }
    static func followed() async throws -> [ServerNovel] {
        ((try await json("/followed", timeout: 60))["novels"] as? [[String: Any]] ?? []).map(ServerNovel.init)
    }
    static func estimate(_ site: String) async throws -> [String: Any] { try await json("/estimate", method: "POST", body: ["site": site], timeout: 180) }
    static func startSite(_ site: String) async throws { _ = try await json("/jobs", method: "POST", body: ["type": "site", "site": site]) }
    static func startNovels(_ urls: [String]) async throws {
        // a few hundred at a time keeps every request small
        var i = 0
        while i < urls.count {
            let part = Array(urls[i..<min(i + 300, urls.count)])
            _ = try await json("/jobs", method: "POST", body: ["type": "novels", "urls": part], timeout: 60)
            i += 300
        }
    }
    static func jobAction(_ id: String, _ action: String) async throws { _ = try await json("/jobs/\(id)/\(action)", method: "POST") }
    static func clearJobs() async throws { _ = try await json("/jobs", method: "DELETE") }
    static func novelAction(_ id: String, _ action: String) async throws { _ = try await json("/novels/\(id)/\(action)", method: "POST") }
    static func checkAllNow() async throws { _ = try await json("/check?force=1", method: "POST") }
    static func settings() async throws -> [String: Double] {
        (try await json("/settings")).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
    static func saveSettings(_ s: [String: Double]) async throws -> [String: Double] {
        (try await json("/settings", method: "PUT", body: s)).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
    static func storage() async throws -> [String: Any] { try await json("/storage", timeout: 120) }
    static func cleanup(epubs: Bool, versions: Bool, orphans: Bool, jobs: Bool) async throws -> Double {
        let r = try await json("/cleanup", method: "POST", body: ["epubs": epubs, "versions": versions, "orphans": orphans, "jobs": jobs], timeout: 300)
        let f = (r["freed"] as? [String: Any]) ?? [:]
        return f.values.reduce(0) { $0 + ArchiveFormat.num($1) }
    }
    static func exportList() async throws -> String {
        let d = try await request("/export", timeout: 60)
        return String(data: d, encoding: .utf8) ?? ""
    }
    static func importList(_ text: String) async throws -> Int {
        guard let d = text.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw NovelError.message("النص مو قائمة أرشيف من جليس") }
        let r = try await json("/import", method: "POST", body: o, timeout: 120)
        return Int(ArchiveFormat.num(r["novels"]))
    }

    /// «نزّل الجديد من السيرفر»: for every library novel, the chapters the server has and the phone lacks (rows are added
    /// when the phone doesn't know them yet: the site may be down or refuse the phone), and the chapters the server saw
    /// change since the last pull. Returns how many novels got something, and how many chapters.
    static func pullNew(progress: @escaping (String) -> Void) async throws -> (novels: Int, chapters: Int) {
        let library = Novels.shared.list.filter { !["epub", "sample", "archive"].contains($0.source) && !$0.book.isEmpty }
        var touched = 0, total = 0, lastError: Error?, failedNovels = 0
        for (i, n) in library.enumerated() {
            if Task.isCancelled { break }
            progress("أنزّل من السيرفر: \(i + 1) من \(library.count)")
            let since = Double(DB.shared.get("server.pull.\(n.id)") ?? "") ?? 0
            var have = Set(Novels.shared.chapters(n.id).filter { $0.saved }.map { $0.url })
            var got = 0, added = 0, stamp = 0.0, rounds = 0
            // changed chapters already taken: they stay in \`have\`, so the server is told not to send them again
            var taken = Set<String>()
            // the pull reached its end; the stamp is kept only then, or a failed novel would skip its changes next time
            var finished = false
            while rounds < 80 {
                rounds += 1
                let body: [String: Any] = ["url": n.url, "have": Array(have), "done": Array(taken), "since": since, "limit": 40]
                let r: [String: Any]
                do { r = try await json("/pull", method: "POST", body: body, timeout: 120) }
                catch Failure.status(404) { finished = true; break }
                catch {
                    // one novel failing doesn't stop the others
                    if Task.isCancelled { throw error }
                    lastError = error; failedNovels += 1
                    break
                }
                stamp = ArchiveFormat.num(r["now"])
                let chapters = (r["chapters"] as? [[String: Any]]) ?? []
                var progressed = false
                for c in chapters {
                    guard let url = c["url"] as? String, let paras = c["paras"] as? [String], !paras.isEmpty else { continue }
                    var row = chapterRow(n.id, url)
                    if row == nil {
                        let maxIdx = DB.shared.query("SELECT MAX(idx) AS m FROM chapters WHERE novel=?", [n.id]).first?.int("m") ?? -1
                        let fields: [String: Any] = ["url": url, "num": (c["num"] as? String) ?? "", "title": (c["title"] as? String) ?? "",
                                                      "volume": (c["volume"] as? String) ?? "", "date": (c["date"] as? String) ?? "", "locked": false]
                        Novels.shared.insert(fields, novel: n.id, idx: maxIdx + 1, found: Date().timeIntervalSince1970)
                        row = chapterRow(n.id, url)
                        if row != nil { added += 1 }
                    }
                    guard let ch = row else { continue }
                    Novels.shared.keep(ch, ChapterText(title: (c["title"] as? String) ?? "", paras: paras, removed: 0))
                    if have.insert(url).inserted { progressed = true }
                    // a changed chapter counts as progress too (it is already in \`have\`)
                    if (c["changed"] as? Bool) == true, taken.insert(url).inserted { progressed = true }
                    got += 1
                }
                if !((r["more"] as? Bool) ?? false) || chapters.isEmpty { finished = true; break }
                if !progressed && rounds > 1 { break }
            }
            if stamp > 0 && finished { DB.shared.set("server.pull.\(n.id)", String(stamp)) }
            if added > 0 {
                DB.shared.run("UPDATE novels SET total=(SELECT COUNT(*) FROM chapters WHERE novel=?), updated=? WHERE id=?", [n.id, Date().timeIntervalSince1970, n.id])
                Novels.shared.reload()
            }
            if got > 0 { touched += 1; total += got; NovelBridge.sync(n.id) }
        }
        NewChapters.afterCheck()
        // every novel failed: that is the server's problem, and the page says so
        if let e = lastError, failedNovels == library.count, touched == 0 { throw e }
        return (touched, total)
    }

    private static func chapterRow(_ novel: Int, _ url: String) -> ChapterRow? {
        DB.shared.query("SELECT c.*, (SELECT 1 FROM texts t WHERE t.chapter = c.id) AS saved FROM chapters c WHERE c.novel=? AND c.url=?", [novel, url]).first.map(ChapterRow.init(row:))
    }
}

// MARK: - the page's state

@MainActor
final class ServerModel: ObservableObject {
    @Published var jobs: [ServerJob] = []
    @Published var followed: [ServerNovel] = []
    @Published var settings: [String: Double] = [:]
    @Published var storage: [String: Any] = [:]
    @Published var status: [String: Any] = [:]
    @Published var note: String?
    @Published var busy = false
    @Published var reachable = true

    var anyActive: Bool { jobs.contains { $0.state == "running" || $0.state == "queued" } }

    /// Polls while the page is open (cancelled by .task when it closes): the jobs every 3 s while one runs, every 15 s
    /// otherwise. The slow reads (status, the followed list, which can take a minute) run on their own beat so they
    /// never hold the jobs back.
    func poll() async {
        guard ServerLink.isOn else { return }
        let slow = Task { @MainActor in
            while !Task.isCancelled {
                await self.refreshSlow()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        defer { slow.cancel() }
        while !Task.isCancelled {
            await refreshJobs()
            try? await Task.sleep(nanoseconds: anyActive ? 3_000_000_000 : 15_000_000_000)
        }
    }

    func refresh(full: Bool = true) async {
        guard ServerLink.isOn else { return }
        await refreshJobs()
        if full { await refreshSlow() }
    }

    private func refreshJobs() async {
        do { jobs = try await ServerLink.jobs(); reachable = true } catch { reachable = false }
    }

    private func refreshSlow() async {
        do {
            status = try await ServerLink.status()
            followed = try await ServerLink.followed()
            if settings.isEmpty { settings = try await ServerLink.settings() }
        } catch {}
    }

    func loadStorage() async {
        do { storage = try await ServerLink.storage() } catch { note = error.localizedDescription }
    }

    /// An action on the server, then a refresh; its failure is the note.
    func act(_ message: String? = nil, _ f: @escaping () async throws -> String?) {
        busy = true
        note = nil
        Task { @MainActor in
            do { note = try await f() ?? message } catch { note = error.localizedDescription }
            await refresh()
            busy = false
        }
    }

    func setting(_ key: String) -> Binding<Double> {
        Binding(get: { self.settings[key] ?? 0 }, set: { v in
            self.settings[key] = v
            Task { @MainActor in
                if let s = try? await ServerLink.saveSettings([key: v]) { self.settings = s }
            }
        })
    }
}

// MARK: - the sections of the page

private struct ArchiveCard<C: View>: View {
    @ViewBuilder let content: () -> C
    @Environment(\.look) private var L
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }
}

private struct Bar: View {
    let value: Double
    @Environment(\.look) private var L
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(L.surface2))
                Capsule().fill(Color(L.primary)).frame(width: max(6, g.size.width * value))
            }
        }
        .frame(height: 6)
    }
}

/// «الأرشيف»: start an archive, and the jobs.
struct ServerArchiveSection: View {
    @ObservedObject var model: ServerModel
    @Environment(\.look) private var L
    @State private var siteSheet = false
    @State private var chooseSheet = false

    var body: some View {
        SettingsSection(title: "الأرشيف") {
            if !model.reachable {
                Label("تعذّر الوصول إلى السيرفر. ما تراه هنا قد لا يكون محدّثًا.", systemImage: "wifi.exclamationmark")
                    .font(JFont.body(13.5, .medium)).foregroundStyle(Color(L.danger))
            }
            SettingsNote("السيرفر يحفظ نص كل فصل عنده، فتقدر تقرأ حتى لو الموقع وقف. اختر موقع كامل (مثل ملوك الروايات) أو روايات بعينها، وهو يمشي عليها بهدوء، طلب كل ٢-٣ ثواني.")
            HStack(spacing: 8) {
                Button("أرشفة موقع كامل") { siteSheet = true }
                Button("اختيار روايات") { chooseSheet = true }
            }
            .buttonStyle(JButtonStyle(look: L, small: true))
            .disabled(model.busy)
            if model.jobs.isEmpty {
                SettingsNote("ما فيه مهام أرشفة الحين.")
            } else {
                ForEach(model.jobs) { j in JobRow(job: j, model: model) }
                if model.jobs.contains(where: { !$0.active }) {
                    Button("امسح المنتهية") { model.act { try await ServerLink.clearJobs(); return nil } }
                        .buttonStyle(JButtonStyle(look: L, small: true))
                }
            }
        }
        .sheet(isPresented: $siteSheet) { ArchiveSiteSheet(model: model) }
        .sheet(isPresented: $chooseSheet) { ChooseNovelsSheet(model: model) }
    }
}

private struct JobRow: View {
    let job: ServerJob
    @ObservedObject var model: ServerModel
    @Environment(\.look) private var L

    var body: some View {
        ArchiveCard {
            HStack {
                Text(job.title).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink))
                Spacer(minLength: 4)
                Text(job.stateText).font(JFont.body(12.5)).foregroundStyle(Color(job.state == "paused" ? L.danger : L.ink2))
            }
            Bar(value: job.discovering ? 0 : job.fraction)
            Text(summary).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).monospacedDigit()
            if !job.current.isEmpty, job.state == "running" {
                Text("الحين: \(job.current)").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).lineLimit(1)
            }
            if job.errors > 0 {
                Text("أخطاء: \(job.errors)" + (job.lastError.isEmpty ? "" : " · " + job.lastError)).font(JFont.body(12)).foregroundStyle(Color(L.ink2)).lineLimit(2)
            }
            HStack(spacing: 8) {
                if job.state == "paused" { Button("كمّل") { run("resume") } }
                if job.state == "running" || job.state == "queued" { Button("وقّف مؤقتًا") { run("pause") } }
                if job.active { Button("ألغِ") { run("cancel") } }
            }
            .buttonStyle(JButtonStyle(look: L, small: true))
        }
    }

    private var summary: String {
        var s = "روايات: \(job.novelsDone) من \(job.found) · فصول: \(job.chaptersFetched) من \(job.chaptersTotal) · \(ArchiveFormat.bytes(job.bytes))"
        if let e = job.eta, job.state == "running" { s += " · باقي نحو " + ArchiveFormat.duration(e) }
        return s
    }

    private func run(_ action: String) { model.act { try await ServerLink.jobAction(job.id, action); return nil } }
}

/// «أرشفة موقع كامل»: pick a site, see an estimate, start.
private struct ArchiveSiteSheet: View {
    @ObservedObject var model: ServerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var sites: [ServerSite] = []
    @State private var loading = true
    @State private var picked: ServerSite?
    @State private var estimate: [String: Any]?
    @State private var estimating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        JSheet(title: "أرشفة موقع كامل") {
            if loading { ProgressView() }
            ForEach(sites) { s in
                JMenuRow(icon: "building.columns", title: Novel.siteNames[s.id] ?? s.name,
                         sub: s.job != nil ? "فيه أرشفة شغّالة" : (s.novels > 0 ? "عند السيرفر \(s.novels) رواية من هذا الموقع" : nil),
                         checked: picked?.id == s.id) { choose(s) }
            }
            if let p = picked {
                ArchiveCard {
                    if estimating {
                        HStack(spacing: 8) { ProgressView(); Text("أقدّر حجم الموقع…").font(JFont.body(14)).foregroundStyle(Color(L.ink2)) }
                    } else if let e = estimate {
                        let novels = Int(ArchiveFormat.num(e["novels"])), hours = ArchiveFormat.num(e["hours"]), gb = ArchiveFormat.num(e["gb"])
                        Text("نحو \(novels) رواية").font(JFont.body(16, .semibold)).foregroundStyle(Color(L.ink))
                        Text("تقدير: حوالي \(Int(ArchiveFormat.num(e["chapters"]))) فصل، \(ArchiveFormat.duration(hours * 3600))، ومساحة \(String(format: "%.1f", gb)) جيجا (على أساس ١٥٠ فصل لكل رواية).")
                            .font(JFont.body(13)).foregroundStyle(Color(L.ink2)).fixedSize(horizontal: false, vertical: true)
                    }
                    if let e = error { Text(e).font(JFont.body(13)).foregroundStyle(Color(L.danger)) }
                    Button(p.job != nil ? "الأرشفة شغّالة" : "ابدأ الأرشفة") { start(p) }
                        .buttonStyle(JButtonStyle(look: L, primary: true))
                        .disabled(estimating || p.job != nil)
                }
            }
        }
        .task { await load() }
        .onDisappear { task?.cancel() }
    }

    private func load() async {
        sites = (try? await ServerLink.sites()) ?? []
        loading = false
    }

    private func choose(_ s: ServerSite) {
        picked = s
        estimate = nil
        error = nil
        estimating = true
        task?.cancel()
        task = Task { @MainActor in
            let result: Result<[String: Any], Error>
            do { result = .success(try await ServerLink.estimate(s.id)) } catch { result = .failure(error) }
            // a cancelled estimate, or one for a site no longer picked, writes nothing (it would overwrite the newer one)
            guard !Task.isCancelled, picked?.id == s.id else { return }
            switch result {
            case .success(let e): estimate = e
            case .failure(let e): self.error = e.localizedDescription
            }
            estimating = false
        }
    }

    private func start(_ s: ServerSite) {
        model.act("بدأت أرشفة الموقع") { try await ServerLink.startSite(s.id); return nil }
        dismiss()
    }
}

/// «اختيار روايات»: from the library, or from a site's list, with multi-select.
private struct ChooseNovelsSheet: View {
    @ObservedObject var model: ServerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @ObservedObject private var novels = Novels.shared
    @State private var from = 0
    @State private var picked = Set<String>()
    // a site's list
    @State private var sites: [[String: Any]] = []
    @State private var site = ""
    @State private var kind = "latest"
    @State private var query = ""
    @State private var items: [[String: Any]] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error: String?

    private var sendAction: (label: String, run: () -> Void)? {
        if picked.isEmpty { return nil }
        return (label: "أرشف", run: { send() })
    }

    private var library: [Novel] {
        novels.list.filter { !["epub", "sample", "archive"].contains($0.source) && !$0.book.isEmpty }
    }

    var body: some View {
        JSheet(title: "اختيار روايات", subtitle: picked.isEmpty ? nil : "المختار: \(picked.count)", action: sendAction) {
            JSeg(options: [(0, "من مكتبتي"), (1, "من موقع")], value: $from)
            if from == 0 { libraryList } else { siteList }
        }
    }

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(picked.count == library.count && !library.isEmpty ? "ألغِ الكل" : "اختر الكل") {
                    picked = picked.count == library.count ? [] : Set(library.map { $0.url })
                }
                .buttonStyle(JButtonStyle(look: L, small: true))
                Spacer()
            }
            .padding(.bottom, 8)
            ForEach(library) { n in row(n.title, n.siteName, n.url) }
            if library.isEmpty { SettingsNote("مكتبتك ما فيها روايات من مواقع.") }
        }
    }

    private var siteList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sites.indices, id: \.self) { i in
                        let id = (sites[i]["id"] as? String) ?? ""
                        Button(Novel.siteNames[id] ?? ((sites[i]["name"] as? String) ?? id)) { site = id; reload() }
                            .buttonStyle(JButtonStyle(look: L, primary: site == id, small: true))
                    }
                }
            }
            if !site.isEmpty {
                JSeg(options: [("latest", "الأحدث"), ("popular", "الأشهر")], value: Binding(get: { kind }, set: { kind = $0; reload() }))
                TextField("ابحث في الموقع", text: $query)
                    .submitLabel(.search).onSubmit { reload() }
                    .font(JFont.body(15)).padding(.horizontal, 12).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(L.bg)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
            }
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                row((it["title"] as? String) ?? "", (it["meta"] as? String) ?? "", (it["url"] as? String) ?? "")
            }
            if loading { ProgressView() }
            if let e = error { Text(e).font(JFont.body(13)).foregroundStyle(Color(L.danger)) }
            if more && !loading { Button("حمّل المزيد") { load(page + 1) }.buttonStyle(JButtonStyle(look: L, small: true)) }
        }
        .task {
            if sites.isEmpty {
                sites = await SourceEngine.shared.list()
                if let first = sites.first?["id"] as? String { site = first; reload() }
            }
        }
    }

    private func row(_ title: String, _ sub: String, _ url: String) -> some View {
        Button { ArchiveFormat.toggle(&picked, url); Haptics.play("sel") } label: {
            HStack(spacing: 12) {
                Image(systemName: picked.contains(url) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(Color(picked.contains(url) ? L.primary : L.ink2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(JFont.body(15.5, .medium)).foregroundStyle(Color(L.ink)).lineLimit(2).multilineTextAlignment(.leading)
                    if !sub.isEmpty { Text(sub).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reload() {
        items = []
        page = 1
        more = false
        load(1)
    }

    private func load(_ p: Int) {
        guard !site.isEmpty else { return }
        loading = true
        error = nil
        let (s, k, q) = (site, query.isEmpty ? kind : "search", query)
        Task { @MainActor in
            do {
                let r = try await SourceEngine.shared.browse(s, kind: k, page: p, query: q)
                guard s == site else { return }
                let have = Set(items.compactMap { $0["url"] as? String })
                items += r.items.filter { !have.contains(($0["url"] as? String) ?? "") }
                page = p
                more = r.more
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func send() {
        let urls = Array(picked)
        model.act("طلبت من السيرفر يأرشف \(urls.count) رواية") { try await ServerLink.startNovels(urls); return nil }
        dismiss()
    }
}

/// «المتابعة»: pulling, intervals, followed novels.
struct ServerFollowSection: View {
    @ObservedObject var model: ServerModel
    @Environment(\.look) private var L
    @State private var all = false

    var body: some View {
        SettingsSection(title: "المتابعة") {
            SettingsNote("السيرفر يفحص رواياتك ويجيب الفصل الجديد أول ما ينزل، ويعيد فحص آخر الفصول عشان لو الموقع عدّل نص فصل يحفظ الجديد ويبقي القديم.")
            Button("نزّل الجديد من السيرفر") {
                model.act {
                    let r = try await ServerLink.pullNew { m in model.note = m }
                    return r.chapters == 0 ? "ما فيه جديد عند السيرفر" : "نزلت \(r.chapters) فصل من \(r.novels) رواية"
                }
            }
            .buttonStyle(JButtonStyle(look: L, primary: true))
            .disabled(model.busy)
            if let n = model.note { Text(n).font(JFont.body(13)).foregroundStyle(Color(L.ink2)).fixedSize(horizontal: false, vertical: true) }
            SettingsField(label: "يفحص رواياتك كل") {
                JSeg(options: [(30.0, "نص ساعة"), (60.0, "ساعة"), (180.0, "3 ساعات"), (360.0, "6 ساعات")], value: model.setting("checkMinutes"))
            }
            SettingsField(label: "يفحص روايات أرشيف الموقع الكامل كل") {
                JSeg(options: [(6.0, "6 ساعات"), (24.0, "يوم"), (72.0, "3 أيام")], value: model.setting("siteCheckHours"))
            }
            SettingsField(label: "يعيد فحص آخر … فصل لو تغيّر نصها") {
                JSeg(options: [(0.0, "لا"), (10.0, "10"), (20.0, "20"), (50.0, "50")], value: model.setting("recheckLast"))
            }
            SettingsField(label: "سرعة الطلبات على المواقع") {
                JSeg(options: [(1500.0, "أسرع"), (2500.0, "عادي"), (5000.0, "هادئ")], value: model.setting("paceMs"))
            }
            Button("افحص الكل الحين") { model.act("بدأ الفحص") { try await ServerLink.checkAllNow(); return nil } }
                .buttonStyle(JButtonStyle(look: L, small: true)).disabled(model.busy)
            let shown = all ? model.followed : Array(model.followed.prefix(20))
            ForEach(shown) { n in FollowedRow(novel: n, model: model) }
            if model.followed.count > 20 {
                Button(all ? "أقل" : "كل المتابَعة (\(model.followed.count))") { all.toggle() }.buttonStyle(JButtonStyle(look: L, small: true))
            }
        }
    }
}

private struct FollowedRow: View {
    let novel: ServerNovel
    @ObservedObject var model: ServerModel
    @Environment(\.look) private var L

    var body: some View {
        ArchiveCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(novel.title).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(2)
                    Text("فصول: \(novel.saved) محفوظ من \(novel.chapters)" + (novel.complete ? " · مكتملة" : "")).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).monospacedDigit()
                    Text((novel.checked > 0 ? "آخر فحص: " + Words.date(novel.checked) : "ما انفحصت بعد") + " · جديد: \(novel.newCount) · تحدّث: \(novel.updatedCount)")
                        .font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).monospacedDigit()
                }
                Spacer(minLength: 6)
                Button { model.act { try await ServerLink.novelAction(novel.id, "check"); return "بدأ فحص الرواية" } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(JButtonStyle(look: L, small: true)).accessibilityLabel("افحص الحين")
            }
            Toggle("وقّف متابعتها", isOn: Binding(get: { novel.paused }, set: { v in
                model.act { try await ServerLink.novelAction(novel.id, v ? "pause" : "resume"); return nil }
            }))
            .tint(Color(L.primary)).font(JFont.body(14))
        }
    }
}

/// «التخزين»: what is on the server's disk, cleaning, and the list of the archive.
struct ServerStorageSection: View {
    @ObservedObject var model: ServerModel
    @Environment(\.look) private var L
    @State private var epubs = true
    @State private var versions = false
    @State private var orphans = true
    @State private var ask = false

    var body: some View {
        SettingsSection(title: "التخزين") {
            Button("اعرض المساحة") { Task { @MainActor in await model.loadStorage() } }
                .buttonStyle(JButtonStyle(look: L, small: true))
            if !model.storage.isEmpty { storageInfo }
            SettingsField(label: "تنظيف") {
                VStack(alignment: .leading, spacing: 0) {
                    JSwitchRow(title: "ملفات EPUB", sub: "تنعاد أول ما تطلبها", on: $epubs)
                    JSwitchRow(title: "النسخ القديمة للفصول اللي تعدّلت", on: $versions)
                    JSwitchRow(title: "بقايا روايات انحذفت", on: $orphans)
                }
            }
            Button("نظّف") { ask = true }.buttonStyle(JButtonStyle(look: L, small: true)).disabled(model.busy)
            HStack(spacing: 8) {
                Button("انسخ قائمة الأرشيف") {
                    model.act { UIPasteboard.general.string = try await ServerLink.exportList(); return "اننسخت القائمة (روايات وإعدادات)" }
                }
                Button("استورد من النسخ") {
                    model.act {
                        let n = try await ServerLink.importList(UIPasteboard.general.string ?? "")
                        return "السيرفر بيأرشف \(n) رواية جديدة"
                    }
                }
            }
            .buttonStyle(JButtonStyle(look: L, small: true)).disabled(model.busy)
        }
        .confirmationDialog("ينحذف من السيرفر اللي اخترته. نصوص الفصول نفسها ما تنحذف.", isPresented: $ask, titleVisibility: .visible) {
            Button("نظّف", role: .destructive) {
                model.act {
                    let freed = try await ServerLink.cleanup(epubs: epubs, versions: versions, orphans: orphans, jobs: false)
                    await model.loadStorage()
                    return "تحرّر " + ArchiveFormat.bytes(freed)
                }
            }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private var storageInfo: some View {
        let s = model.storage
        let sites = ((s["sites"] as? [String: Any]) ?? [:]).map { ($0.key, ArchiveFormat.num($0.value)) }.sorted { $0.1 > $1.1 }
        let top = ((s["novels"] as? [[String: Any]]) ?? []).prefix(8)
        return ArchiveCard {
            Text("المحفوظ: " + ArchiveFormat.bytes(ArchiveFormat.num(s["total"]))
                 + ((s["free"] as? NSNumber).map { " · الفاضي على السيرفر: " + ArchiveFormat.bytes($0.doubleValue) } ?? ""))
                .font(JFont.body(14.5, .semibold)).foregroundStyle(Color(L.ink)).monospacedDigit()
            Text("الفصول " + ArchiveFormat.bytes(ArchiveFormat.num(s["chapters"])) + " · EPUB " + ArchiveFormat.bytes(ArchiveFormat.num(s["epubs"])) + " · النسخ الاحتياطية " + ArchiveFormat.bytes(ArchiveFormat.num(s["backups"])))
                .font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).monospacedDigit()
            ForEach(sites, id: \.0) { site in
                Text((Novel.siteNames[site.0] ?? site.0) + ": " + ArchiveFormat.bytes(site.1)).font(JFont.body(13)).foregroundStyle(Color(L.ink)).monospacedDigit()
            }
            if !top.isEmpty { JLabel(text: "الأكبر") }
            ForEach(Array(top.enumerated()), id: \.offset) { _, n in
                Text(((n["title"] as? String) ?? "") + " · " + ArchiveFormat.bytes(ArchiveFormat.num(n["bytes"]))).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).lineLimit(1)
            }
        }
    }
}
