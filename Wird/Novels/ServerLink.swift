import SwiftUI

/// Jalees and your own server (server/jalees-server.js, v2 §7): the server follows your novels hourly and keeps every
/// chapter, so a chapter whose site is down or removed it comes from the server's archive; Jalees sends it a backup
/// once a week. Without a server set, Jalees works on its own exactly as before.
@MainActor
enum ServerLink {
    static var url: String {
        // read normalised too: an address saved before (without http:// or the port) works as it is
        get { normalized(DB.shared.get("server.url") ?? "") }
        set { DB.shared.set("server.url", normalized(newValue)) }
    }

    /// What was typed, as an address the app can use: http:// added when missing, the server's port (8790) when none
    /// is given, and nothing after it («100.75.48.114» → «http://100.75.48.114:8790»).
    static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !t.isEmpty else { return "" }
        if !t.contains("://") { t = "http://" + t }
        guard var c = URLComponents(string: t), let host = c.host, !host.isEmpty else { return t }
        if c.port == nil && c.scheme == "http" { c.port = 8790 }
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.string ?? t
    }
    static var token: String {
        // in the Keychain (Secrets); an older copy in the database moves there on the first read
        get { Secrets.read("server.token", kv: "server.token") ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Secrets.set("server.token", v.isEmpty ? nil : v)
            DB.shared.set("server.token", nil)
        }
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

    static func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: Double = 30) async throws -> Data {
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

    /// «جرّب الاتصال», step by step, saying which step failed: the address, reaching it (Tailscale), then the token.
    static func diagnose() async -> String {
        guard !url.isEmpty, let h = URL(string: url + "/health") else { return "اكتب عنوان السيرفر، مثل http://100.75.48.114:8790" }
        // a Tailscale address on the server: is Tailscale up on this phone at all? (its address is 100.64–127.x.x)
        let host = URL(string: url)?.host ?? ""
        let mine = Self.tailscaleAddress()
        if Self.isTailscale(host) && mine == nil {
            return "Tailscale مو شغّال على جوالك الحين: ما له عنوان 100.x.\nافتح تطبيق Tailscale وشغّله لين يقول Connected، وبعدها جرّب الاتصال مرة ثانية."
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: URLRequest(url: h, timeoutInterval: 10))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 { return "وصلت لـ\(url) بس اللي ردّ مو سيرفر جليس (ردّ بـ\(code)). تأكد من الرقم بعد النقطتين." }
        } catch {
            let ns = error as NSError
            let detail = "(\(ns.code): \(ns.localizedDescription))"
            if ns.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                return "iOS رفض اتصال جليس بعنوان http \(detail).\nهذا خلل في جليس نفسه مو في السيرفر: صوّر لي هذي الرسالة."
            }
            if "\(ns.userInfo)".range(of: "Local network prohibited", options: .caseInsensitive) != nil {
                return "iOS منع جليس يوصل للشبكة \(detail).\nالإعدادات ← الخصوصية والأمان ← الشبكة المحلية ← فعّل جليس."
            }
            let why = (error as? URLError)?.code == .timedOut ? "ما ردّ السيرفر خلال 10 ثواني" : "ما قدرت أتصل على السيرفر"
            if let me = mine, Self.isTailscale(host) {
                return "\(why) \(detail).\nجوالك متصل بـTailscale (عنوانه \(me))، والسيرفر ما وصله طلب. افتح \(url)/health في سفاري: لو فتحت، صوّر لي هذي الرسالة؛ لو ما فتحت، تأكد إن الجوال والسيرفر بنفس حساب Tailscale."
            }
            return "\(why) على \(url) \(detail).\nتأكد إن العنوان نفس اللي في رسالة السيرفر."
        }
        guard !token.isEmpty else { return "وصلت للسيرفر. باقي تحط الرمز." }
        do {
            let n = try await test()
            return "السيرفر شغّال ويتابع \(n) رواية" + plainWarning(host)
        } catch Failure.token {
            return "وصلت للسيرفر، بس الرمز ما طابق (اللي حطيته \(token.count) حرف). انسخ JALEES_TOKEN كامل والصقه بزر «الصق»."
        } catch {
            return error.localizedDescription
        }
    }

    /// One more line when the address is plain http and outside Tailscale and the home network: the token then travels
    /// unencrypted over whatever network is between the phone and the server.
    private static func plainWarning(_ host: String) -> String {
        guard url.lowercased().hasPrefix("http://"), !isTailscale(host), !isLocalNetwork(host) else { return "" }
        return "\nتنبيه: العنوان مو Tailscale ولا شبكة بيتك، والاتصال بدون تشفير (http)، فالرمز يمشي مكشوف في الطريق. استخدم Tailscale أو https."
    }

    /// Private home-network addresses (10.x, 172.16–31.x, 192.168.x, 169.254.x), localhost and «.local» names.
    static func isLocalNetwork(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
    }

    /// 100.64.0.0/10: the addresses Tailscale gives.
    nonisolated static func isTailscale(_ host: String) -> Bool {
        let p = host.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }

    /// This phone's own Tailscale address, when Tailscale is connected (its tunnel has one).
    static func tailscaleAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            p = a.pointee.ifa_next
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buf)
            if isTailscale(ip) { return ip }
        }
        return nil
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
        // the library's novels (not ones only looked at while browsing)
        let urls = Novels.shared.list.filter { !["epub", "sample", "archive"].contains($0.source) && !$0.book.isEmpty }.map(\.url)
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
    @State private var showToken = false

    @StateObject private var model = ServerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsSection(title: "الاتصال") { connection }
            if !url.isEmpty && !token.isEmpty {
                ServerArchiveSection(model: model)
                ServerFollowSection(model: model)
                ServerStorageSection(model: model)
            }
        }
        // polls while the page is open (a few seconds while a job runs); .task stops it when the page closes
        .task(id: url + token) { await model.poll() }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            JLabel(text: "سيرفرك (اختياري)")
            field("100.75.48.114:8790", $url, secure: false)
            HStack(spacing: 8) {
                field("JALEES_TOKEN", $token, secure: !showToken)
                // the token is long: shown to check it, pasted whole
                Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                    .buttonStyle(JButtonStyle(look: L, small: true)).accessibilityLabel(showToken ? "إخفاء الرمز" : "إظهار الرمز")
                Button("الصق") { if let s = UIPasteboard.general.string { token = s } }
                    .buttonStyle(JButtonStyle(look: L, small: true))
            }
            if !url.isEmpty, ServerLink.url != url {
                Text("يتصل بـ".tr + " " + ServerLink.url).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)).environment(\.layoutDirection, .leftToRight)
            }
            HStack(spacing: 8) {
                Button("جرّب الاتصال") { busy = true; note = nil; Task { @MainActor in note = await ServerLink.diagnose(); busy = false } }
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
