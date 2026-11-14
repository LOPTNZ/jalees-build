import SwiftUI

/// Jalees and your own server (server/jalees-server.js, v2 §7): the server follows your novels hourly and keeps every
/// chapter, so a chapter whose site is down or removed it comes from the server's archive; Jalees sends it a backup
/// once a week. Without a server set, Jalees works on its own exactly as before.
@MainActor
enum ServerLink {
    static var url: String {
        get { DB.shared.get("server.url") ?? "" }
        set { DB.shared.set("server.url", newValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    }
    static var token: String {
        get { DB.shared.get("server.token") ?? "" }
        set { DB.shared.set("server.token", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    static var isOn: Bool { !url.isEmpty && !token.isEmpty }
    static var lastBackup: Double {
        get { Double(DB.shared.get("server.backup") ?? "") ?? 0 }
        set { DB.shared.set("server.backup", String(newValue)) }
    }

    enum Failure: LocalizedError {
        case off, token, status(Int), offline
        var errorDescription: String? {
            switch self {
            case .off: return "ما فيه سيرفر مضبوط"
            case .token: return "السيرفر رفض الرمز، تأكد إنه نفس JALEES_TOKEN"
            case .status(let c): return "السيرفر ردّ بالرمز \(c)"
            case .offline: return "ما وصلت للسيرفر (شغّال؟ وTailscale متصل؟)"
            }
        }
    }

    private static func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: Double = 30) async throws -> Data {
        guard isOn, let u = URL(string: url + path) else { throw Failure.off }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(token, forHTTPHeaderField: "x-jalees-token")
        if let b = body { r.httpBody = b; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp): (Data, URLResponse)
        do { (d, resp) = try await URLSession.shared.data(for: r) } catch { throw Failure.offline }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw Failure.token }
        guard code == 200 else { throw Failure.status(code) }
        return d
    }

    /// For «جرّب الاتصال»: how many novels the server follows.
    static func test() async throws -> Int {
        let d = try await request("/novels")
        return ((try? JSONSerialization.jsonObject(with: d)) as? [Any])?.count ?? 0
    }

    /// The server follows these novels too (when one is added in Jalees, and «أرسل رواياتي»).
    static func follow(_ urls: [String]) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["urls": urls])
        let d = try await request("/novels", method: "POST", body: body, timeout: 600)
        let rows = ((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? []
        return rows.filter { $0["error"] == nil }.count
    }

    static func followAll() async throws -> Int {
        let urls = Novels.shared.list.filter { !["epub", "sample", "archive"].contains($0.source) }.map(\.url)
        return try await follow(urls)
    }

    /// A chapter from the server's archive.
    static func chapter(_ chapterURL: String) async throws -> ChapterText {
        let q = chapterURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let d = try await request("/chapter?url=" + q, timeout: 60)
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let paras = o["paras"] as? [String], !paras.isEmpty else { throw NovelError.empty }
        return ChapterText(title: (o["title"] as? String) ?? "", paras: paras, removed: 0)
    }

    /// The weekly backup, quietly, when Jalees opens.
    static func backupIfDue() async {
        guard isOn, Date().timeIntervalSince1970 - lastBackup > 7 * 86_400 else { return }
        try? await backupNow()
    }

    static func backupNow() async throws {
        guard let out = await Backup.export() else { throw Failure.status(0) }
        _ = try await request("/backup", method: "POST", body: out.0, timeout: 300)
        lastBackup = Date().timeIntervalSince1970
    }
}

/// «السيرفر» in the advanced settings.
struct ServerSettings: View {
    @Environment(\.look) private var L
    @State private var url = ServerLink.url
    @State private var token = ServerLink.token
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            JLabel(text: "سيرفرك (اختياري)")
            field("http://100.x.x.x:8787", $url, secure: false)
            field("JALEES_TOKEN", $token, secure: true)
            HStack(spacing: 8) {
                Button("جرّب الاتصال") { act { "السيرفر شغّال ويتابع \(try await ServerLink.test()) رواية" } }
                Button("أرسل رواياتي") { act { "السيرفر صار يتابع \(try await ServerLink.followAll()) رواية" } }
                Button("نسخة الحين") { act { try await ServerLink.backupNow(); return "انحفظت نسخة احتياطية في السيرفر" } }
            }
            .buttonStyle(JButtonStyle(look: L, small: true))
            .disabled(busy || url.isEmpty || token.isEmpty)
            if busy { ProgressView() }
            if let n = note { Text(n).font(JFont.body(13)).foregroundStyle(Color(L.ink2)) }
            Text("السيرفر يفحص الجديد كل ساعة ويحفظ كل الفصول ويسوي EPUB لكل رواية، وجليس يرسل له نسخة احتياطية كل أسبوع".tr +
                 (ServerLink.lastBackup > 0 ? " (آخر وحدة {})".tr.replacingOccurrences(of: "{}", with: Words.date(ServerLink.lastBackup * 1000)) : "") +
                 ". لو موقع وقف أو حذف فصل، جليس يجيبه من السيرفر. طريقة تشغيله في server/README.md.".tr)
                .font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: url) { ServerLink.url = $0 }
        .onChange(of: token) { ServerLink.token = $0 }
    }

    private func field(_ placeholder: String, _ text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text).keyboardType(.URL) }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .font(JFont.body(15)).foregroundStyle(Color(L.ink))
        .environment(\.layoutDirection, .leftToRight)
        .padding(.horizontal, 14).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    private func act(_ f: @escaping () async throws -> String) {
        busy = true
        note = nil
        Task { @MainActor in
            do { note = try await f() } catch { note = error.localizedDescription }
            busy = false
        }
    }
}
