import SwiftUI
import WebKit

/// مستودع المواقع (v2, like Tachimanga's extension repositories): a link to an index of site definitions that Jalees
/// downloads and keeps, so a site that changed its pages, or a new site, works without a new build of the app. A
/// downloaded definition takes the place of the one inside the app with the same id.
///
/// The index (tools/sites_index.py writes one from Wird/www/reader/sites):
/// `{"name": "…", "sites": [{"id": "cenele", "name": "فضاء الروايات", "version": 3, "file": "cenele.js", "lang": "ar"}]}`
/// with each file beside it (or a full address).
@MainActor
enum SiteRepo {
    struct Site: Codable, Hashable {
        let id: String
        let name: String
        let version: Int
        let file: String
        var lang: String?
    }

    static var url: String {
        get { DB.shared.get("repo.url") ?? "" }
        set { DB.shared.set("repo.url", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static var installed: [Site] {
        get { (DB.shared.get("repo.sites")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([Site].self, from: $0) } ?? [] }
        set { DB.shared.set("repo.sites", String(data: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), encoding: .utf8)) }
    }

    static var lastUpdate: Double {
        get { Double(DB.shared.get("repo.updated") ?? "") ?? 0 }
        set { DB.shared.set("repo.updated", String(newValue)) }
    }

    static func dir() -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sites", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The downloaded definitions, to run after the ones inside the app.
    static func scripts() -> [String] {
        installed.compactMap { try? String(contentsOf: dir().appendingPathComponent($0.id + ".js"), encoding: .utf8) }
    }

    enum Failure: LocalizedError {
        case badLink, badIndex, http(Int)
        var errorDescription: String? {
            switch self {
            case .badLink: return "الرابط مو صحيح"
            case .badIndex: return "الرابط ما فيه قائمة مواقع (index.json) يفهمها جليس"
            case .http(let c): return "المستودع ردّ بالرمز \(c)"
            }
        }
    }

    /// Reads the index and downloads every site that is new or has a higher version. Returns what changed.
    @discardableResult
    static func update() async throws -> (added: [String], updated: [String]) {
        guard let base = URL(string: url), base.scheme?.hasPrefix("http") == true else { throw Failure.badLink }
        let (d, r) = try await URLSession.shared.data(from: base)
        if let code = (r as? HTTPURLResponse)?.statusCode, code != 200 { throw Failure.http(code) }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let list = o["sites"] as? [[String: Any]] else { throw Failure.badIndex }
        var have = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        var added: [String] = [], updated: [String] = []
        for s in list {
            guard let id = s["id"] as? String, id.range(of: "^[a-z0-9_-]{2,40}$", options: .regularExpression) != nil,
                  let file = s["file"] as? String, let fileURL = URL(string: file, relativeTo: base)?.absoluteURL else { continue }
            let version = (s["version"] as? Int) ?? Int((s["version"] as? String) ?? "") ?? 1
            if let h = have[id], h.version >= version { continue }
            guard let got = try? await URLSession.shared.data(from: fileURL), (got.1 as? HTTPURLResponse)?.statusCode == 200,
                  got.0.count < 600_000, let text = String(data: got.0, encoding: .utf8), text.contains("Sources") else { continue }
            try? text.write(to: dir().appendingPathComponent(id + ".js"), atomically: true, encoding: .utf8)
            let site = Site(id: id, name: (s["name"] as? String) ?? id, version: version, file: fileURL.absoluteString, lang: s["lang"] as? String)
            if have[id] == nil { added.append(site.name) } else { updated.append(site.name) }
            have[id] = site
        }
        installed = Array(have.values).sorted { $0.name < $1.name }
        lastUpdate = Date().timeIntervalSince1970
        if !added.isEmpty || !updated.isEmpty { SourceEngine.shared.restart() }
        return (added, updated)
    }

    /// Once a day, quietly, when Browse opens.
    static func updateIfDue() async {
        guard !url.isEmpty, Date().timeIntervalSince1970 - lastUpdate > 86_400 else { return }
        _ = try? await update()
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir().appendingPathComponent(id + ".js"))
        installed.removeAll { $0.id == id }
        SourceEngine.shared.restart()
    }
}

struct SiteRepoSheet: View {
    let look: JLook
    @Environment(\.dismiss) private var dismiss
    @State private var link = SiteRepo.url
    @State private var sites = SiteRepo.installed
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/index.json", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .environment(\.layoutDirection, .leftToRight)
                    Button {
                        SiteRepo.url = link
                        busy = true
                        Task {
                            do {
                                let r = try await SiteRepo.update()
                                note = r.added.isEmpty && r.updated.isEmpty ? "كل المواقع على آخر نسخة" :
                                    (r.added.isEmpty ? "" : "انضاف: ".tr + r.added.joined(separator: "، ")) + (r.updated.isEmpty ? "" : (r.added.isEmpty ? "" : "\n") + "تحدّث: ".tr + r.updated.joined(separator: "، "))
                            } catch { note = error.localizedDescription }
                            sites = SiteRepo.installed
                            busy = false
                        }
                    } label: {
                        HStack { Text("حدّث من المستودع"); Spacer(); if busy { ProgressView() } }
                    }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                } header: { Text("رابط المستودع") } footer: {
                    Text("قائمة مواقع (index.json) وملفاتها. جليس يحدّثها لحاله مرة باليوم، والموقع المنزّل ياخذ مكان اللي داخل التطبيق. أضف مستودع تثق فيه بس.")
                }
                if !sites.isEmpty {
                    Section("المنزّلة") {
                        ForEach(sites, id: \.id) { s in
                            HStack {
                                Text(s.name)
                                Spacer()
                                Text("v\(s.version)").foregroundStyle(.secondary).monospacedDigit()
                            }
                            .swipeActions { Button("احذف", role: .destructive) { SiteRepo.remove(s.id); sites = SiteRepo.installed } }
                        }
                    }
                }
                if let n = note { Section { Text(n) } }
            }
            .navigationTitle("مستودع المواقع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
        .environment(\.layoutDirection, Lang.direction)
        .preferredColorScheme(look.dark ? .dark : .light)
        .tint(Color(look.primary))
    }
}
