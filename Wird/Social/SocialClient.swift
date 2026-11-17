import SwiftUI
import UIKit
import Combine

// «الأصدقاء»: the network and the state behind the screens (SocialViews.swift). Once signed in, everything happens by
// itself: library changes become events in an outbox, sent in the background with growing waits, and the screens
// only read the state. Nothing here waits for the network on the screen's thread.

enum SocialError: Error {
    case offline, auth, noServer
    case api(String)
    case status(Int)

    var message: String {
        switch self {
        case .offline: return "تعذّر الوصول إلى السيرفر. تحقق من الاتصال ومن العنوان."
        case .auth: return "انتهت الجلسة. سجّل الدخول من جديد."
        case .noServer: return "اكتب عنوان سيرفر الأصدقاء أولًا."
        case .status(let c): return "السيرفر ردّ بخطأ (\(c))."
        case .api(let code):
            return ["bad_login": "اسم المستخدم أو كلمة السر غير صحيحة.", "locked": "محاولات كثيرة خاطئة. جرّب بعد قليل.",
                    "slow_down": "طلبات كثيرة. جرّب بعد قليل.", "taken": "اسم المستخدم محجوز.",
                    "bad_username": "اسم المستخدم: من 3 إلى 20 حرفًا إنجليزيًا صغيرًا أو أرقامًا أو _",
                    "bad_password": "كلمة السر 8 أحرف على الأقل.", "closed": "التسجيل مغلق: تحتاج دعوة من صديق.",
                    "full": "السيرفر ممتلئ.", "no_user": "ما وجدنا هذا المستخدم.", "already": "أنتما صديقان بالفعل.",
                    "bad_code": "رمز الدعوة غير صالح أو منتهٍ.", "own_code": "هذا رمز دعوتك أنت.", "too_big": "الصورة كبيرة.",
                    "bad_image": "الصورة غير صالحة.", "too_many_friends": "وصلت الحد الأعلى للأصدقاء.",
                    "too_many_requests": "عندك طلبات كثيرة معلّقة.", "too_many_invites": "عندك دعوات كثيرة فعّالة.",
                    "bad_name": "اكتب اسمًا."][code] ?? "تعذّر الطلب (\(code))."
        }
    }
}

// MARK: - what the server sends

struct SocialUser: Identifiable, Hashable {
    var username: String
    var name: String
    var av = 0
    var id: String { username }
    init(_ d: [String: Any]) {
        username = d["username"] as? String ?? ""
        name = d["name"] as? String ?? ""
        av = (d["av"] as? NSNumber)?.intValue ?? 0
    }
}

struct SocialBookRef: Identifiable, Hashable {
    var key: String, title: String, author: String
    var rating = 0.0, hue: Double? = nil, status = "", finish = 0.0
    var text = "", spoiler = false
    var id: String { key + "|" + String(text.prefix(12)) }
    init(_ d: [String: Any]) {
        key = d["key"] as? String ?? ""
        title = d["title"] as? String ?? ""
        author = d["author"] as? String ?? ""
        rating = (d["rating"] as? NSNumber)?.doubleValue ?? 0
        hue = (d["hue"] as? NSNumber)?.doubleValue
        status = d["status"] as? String ?? ""
        finish = (d["finish"] as? NSNumber)?.doubleValue ?? 0
        text = d["text"] as? String ?? ""
        spoiler = d["spoiler"] as? Bool ?? false
    }
}

struct SocialFeedItem: Identifiable, Hashable {
    var id: String
    var type: String            // started, finished, rated, reviewed, quote
    var at: Double
    var book: SocialBookRef
    var rating: Double
    var text: String
    var spoiler: Bool
    var user: SocialUser
    var mine: Bool
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        type = d["type"] as? String ?? ""
        at = (d["at"] as? NSNumber)?.doubleValue ?? 0
        book = SocialBookRef(d["book"] as? [String: Any] ?? [:])
        rating = (d["rating"] as? NSNumber)?.doubleValue ?? 0
        text = d["text"] as? String ?? ""
        spoiler = d["spoiler"] as? Bool ?? false
        user = SocialUser(d["user"] as? [String: Any] ?? [:])
        mine = d["mine"] as? Bool ?? false
    }
}

struct SocialMe {
    var user: SocialUser
    var bio = ""
    var share = true
    var shareStats = true
    var favs: [SocialBookRef] = []
    init(_ d: [String: Any]) {
        user = SocialUser(d)
        bio = d["bio"] as? String ?? ""
        share = d["share"] as? Bool ?? true
        shareStats = d["shareStats"] as? Bool ?? true
        favs = (d["favs"] as? [[String: Any]] ?? []).map(SocialBookRef.init)
    }
}

struct SocialProfile {
    var user: SocialUser
    var relation = "none"
    var bio = ""
    var favs: [SocialBookRef] = []
    var stats: [String: Int]? = nil
    var hidden = false
    var visible = false          // false for a stranger: a name and nothing else
    var reading: [SocialBookRef] = []
    var finished: [SocialBookRef] = []
    var reviews: [SocialBookRef] = []
    var ratings: [Int] = []
    var lists: [(name: String, books: [SocialBookRef])] = []
    var activity: [SocialFeedItem] = []

    init(_ d: [String: Any]) {
        let u = d["user"] as? [String: Any] ?? [:]
        user = SocialUser(u)
        relation = u["relation"] as? String ?? "none"
        bio = u["bio"] as? String ?? ""
        favs = (u["favs"] as? [[String: Any]] ?? []).map(SocialBookRef.init)
        if let s = u["stats"] as? [String: Any] { stats = s.compactMapValues { ($0 as? NSNumber)?.intValue } }
        hidden = u["hidden"] as? Bool ?? false
        visible = relation == "self" || relation == "friend"
        func refs(_ k: String) -> [SocialBookRef] { (d[k] as? [[String: Any]] ?? []).map(SocialBookRef.init) }
        reading = refs("reading"); finished = refs("finished"); reviews = refs("reviews")
        ratings = (d["ratings"] as? [NSNumber] ?? []).map(\.intValue)
        lists = (d["lists"] as? [[String: Any]] ?? []).map { (($0["name"] as? String) ?? "", ($0["books"] as? [[String: Any]] ?? []).map(SocialBookRef.init)) }
        activity = (d["activity"] as? [[String: Any]] ?? []).map(SocialFeedItem.init)
    }
}

// MARK: - the network

enum SocialAPI {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func raw(_ method: String, _ path: String, body: [String: Any]? = nil, token: String?, server: String) async throws -> Data {
        guard !server.isEmpty, let u = URL(string: server + path) else { throw SocialError.noServer }
        var r = URLRequest(url: u, timeoutInterval: 20)
        r.httpMethod = method
        if let t = token { r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        if let b = body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: b)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp): (Data, URLResponse)
        do { (d, resp) = try await session.data(for: r) } catch { throw SocialError.offline }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return d }
        let err = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
        if code == 401 && err == "auth" { throw SocialError.auth }
        if let e = err { throw SocialError.api(e) }
        throw SocialError.status(code)
    }

    static func call(_ method: String, _ path: String, body: [String: Any]? = nil, token: String?, server: String) async throws -> [String: Any] {
        let d = try await raw(method, path, body: body, token: token, server: server)
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}

// MARK: - what is kept on this phone

/// The outbox and what the server last heard, in a file of its own (not in the library, so backups don't carry it).
struct SocialDisk: Codable {
    var outbox = SocialOutbox()
    var snaps: [String: SocialBookSnap] = [:]
    var baselined = false
    var statsSig = ""
    var statsAt = 0.0
    var listsSig = ""
    var inviteCode = ""
}

@MainActor
final class SocialStore: ObservableObject {
    static let shared = SocialStore()

    @Published private(set) var signedIn = false
    @Published private(set) var me: SocialMe?
    @Published private(set) var friends: [SocialUser] = []
    @Published private(set) var incoming: [SocialUser] = []
    @Published private(set) var outgoing: [SocialUser] = []
    @Published private(set) var feed: [SocialFeedItem] = []
    @Published private(set) var loading = false
    @Published private(set) var pending = 0
    /// an invite link waiting for the owner's confirmation (SocialViews shows it)
    @Published var pendingJoin: SocialLink?

    private var token: String? { Secrets.get("social.token") }
    private var disk = SocialDisk()
    private var cancel = Set<AnyCancellable>()
    private var flushing = false
    private var retry: Task<Void, Never>?
    private var started = false

    private static var file: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wird", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("social.json")
    }

    // MARK: settings

    var server: String {
        get { let s = DB.shared.get("social.url") ?? ""; return s.isEmpty ? SocialServer.normalized(SocialServer.defaultURL) : s }
        set { DB.shared.set("social.url", SocialServer.normalized(newValue)) }
    }
    var username: String { DB.shared.get("social.user") ?? "" }
    /// the global switch: «شارك قراءتي»
    var shareReading: Bool { DB.shared.get("social.share") != "0" }
    var shareLists: Bool { DB.shared.get("social.lists") != "0" }

    // MARK: starting (once, at launch)

    func start() {
        guard !started else { return }
        started = true
        if let d = try? Data(contentsOf: Self.file), let x = try? JSONDecoder().decode(SocialDisk.self, from: d) { disk = x }
        signedIn = token != nil && !server.isEmpty
        pending = disk.outbox.events.count
        // every library change, a moment later: what changed for friends becomes events (SocialDiff)
        Library.shared.$state.dropFirst().debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.libraryChanged() }.store(in: &cancel)
        if signedIn { libraryChanged(); flush() }
    }

    /// the app came to the front
    func becameActive() {
        guard signedIn else { return }
        flush()
    }

    private func persist() {
        pending = disk.outbox.events.count
        if let d = try? JSONEncoder().encode(disk) { try? d.write(to: Self.file, options: .atomic) }
    }

    // MARK: library → outbox

    nonisolated static func snapshots(_ st: AppState) -> [String: SocialBookSnap] {
        var m: [String: SocialBookSnap] = [:]
        for b in st.books where !b.title.trimmingCharacters(in: .whitespaces).isEmpty {
            var s = SocialBookSnap(title: b.title, author: b.author)
            s.isbn = b.isbn
            s.hue = b.hue
            s.status = b.status.rawValue
            s.rating = b.rating
            s.review = b.review
            s.spoiler = b.raw.bool("reviewSpoiler")
            s.start = b.start ?? 0
            s.finish = b.finish ?? 0
            s.priv = b.raw.bool("socialPrivate")
            m[b.id] = s
        }
        return m
    }

    private func libraryChanged() {
        guard signedIn, shareReading else { return }
        let st = Library.shared.state
        let r = SocialDiff.events(old: disk.snaps, new: Self.snapshots(st), baseline: !disk.baselined, now: Millis.now)
        disk.baselined = true
        disk.snaps = r.snaps
        for e in r.events { disk.outbox.add(e) }
        persist()
        flush()
    }

    /// A quote the owner chose to share.
    func shareQuote(title: String, author: String, text: String) {
        guard signedIn, shareReading else { return }
        var e = SocialEvent(cid: UUID().uuidString, type: "quote", at: Millis.now, title: title, author: author)
        e.text = text
        disk.outbox.add(e)
        persist()
        flush()
    }

    // MARK: outbox → server (in the background, with waits)

    func flush() {
        guard signedIn, !flushing else { return }
        flushing = true
        Task { [weak self] in
            await self?.sendAll()
            self?.flushing = false
            self?.scheduleRetry()
        }
    }

    private func sendAll() async {
        guard let t = token else { return }
        while signedIn, disk.outbox.ready(Date().timeIntervalSince1970) {
            let batch = disk.outbox.batch()
            do {
                _ = try await SocialAPI.call("POST", "/sync", body: ["events": batch.map { $0.payload() }], token: t, server: server)
                disk.outbox.sent(batch.count)
            } catch let e as SocialError {
                switch e {
                case .auth: signOutLocal(); return
                // the server will never take this batch: it goes, so the rest can follow
                case .api: disk.outbox.drop(batch.count)
                default: disk.outbox.failed(Date().timeIntervalSince1970)
                }
            } catch {
                disk.outbox.failed(Date().timeIntervalSince1970)
            }
            persist()
        }
        await pushStatsAndLists(t)
    }

    private func scheduleRetry() {
        retry?.cancel()
        guard signedIn, !disk.outbox.events.isEmpty else { return }
        let wait = max(5, disk.outbox.nextTry - Date().timeIntervalSince1970)
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(wait, 3600) * 1_000_000_000))
            if !Task.isCancelled { self?.flush() }
        }
    }

    /// the numbers and lists on the profile, when they changed (at most every few minutes)
    private func pushStatsAndLists(_ t: String) async {
        guard shareReading else { return }
        let st = Library.shared.state
        let stats: [String: Any] = ["booksYear": st.finishedThisYear, "booksTotal": st.finishedBooks.count, "pages": Int(st.unitsRead("page")),
                                    "minutes": Int(st.totalMin), "streak": st.streak.cur]
        let sig = stats.keys.sorted().map { "\($0)=\(stats[$0] ?? 0)" }.joined(separator: ",")
        if sig != disk.statsSig, Date().timeIntervalSince1970 - disk.statsAt > 120 {
            if (try? await SocialAPI.call("PUT", "/me/stats", body: stats, token: t, server: server)) != nil {
                disk.statsSig = sig
                disk.statsAt = Date().timeIntervalSince1970
            }
        }
        var lists: [[String: Any]] = []
        if shareLists {
            var names: [String] = []
            for b in st.books { for c in b.cols where !names.contains(c) { names.append(c) } }
            for c in names.prefix(20) {
                let bs = st.books.filter { $0.cols.contains(c) && !$0.raw.bool("socialPrivate") && !$0.title.isEmpty }
                if bs.isEmpty { continue }
                lists.append(["id": c, "name": st.colLabel(c), "books": bs.prefix(100).map { ["title": $0.title, "author": $0.author] }])
            }
        }
        var lsig = ""
        for l in lists {
            lsig += (l["name"] as? String ?? "") + ":"
            for b in (l["books"] as? [[String: String]] ?? []) { lsig += (b["title"] ?? "") + "," }
            lsig += ";"
        }
        if lsig != disk.listsSig, (try? await SocialAPI.call("PUT", "/me/lists", body: ["lists": lists], token: t, server: server)) != nil {
            disk.listsSig = lsig
        }
        persist()
    }

    // MARK: accounts

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        do { return try await SocialAPI.call(method, path, body: body, token: token, server: server) }
        catch SocialError.auth { signOutLocal(); throw SocialError.auth }
    }

    private func began(_ r: [String: Any], _ user: String) async {
        if let t = r["token"] as? String { Secrets.set("social.token", t) }
        DB.shared.set("social.user", user)
        me = SocialMe(r["me"] as? [String: Any] ?? [:])
        signedIn = true
        disk = SocialDisk()
        persist()
        if !shareReading { _ = try? await call("PUT", "/me", body: ["share": false]) }
        libraryChanged()
        await refreshAll()
    }

    func signUp(server s: String, username u: String, name: String, password: String, invite: String) async throws {
        let sv = SocialServer.normalized(s)
        guard !sv.isEmpty else { throw SocialError.noServer }
        let r = try await SocialAPI.call("POST", "/register", body: ["username": u, "name": name, "password": password, "invite": invite, "device": UIDevice.current.name], token: nil, server: sv)
        DB.shared.set("social.url", sv)
        await began(r, u.lowercased())
    }

    func signIn(server s: String, username u: String, password: String, invite: String) async throws {
        let sv = SocialServer.normalized(s)
        guard !sv.isEmpty else { throw SocialError.noServer }
        let r = try await SocialAPI.call("POST", "/login", body: ["username": u, "password": password, "device": UIDevice.current.name], token: nil, server: sv)
        DB.shared.set("social.url", sv)
        await began(r, u.lowercased())
        if !invite.isEmpty { _ = try? await redeem(invite) }
    }

    func signOut() async {
        _ = try? await call("POST", "/logout", body: [:])
        signOutLocal()
    }

    private func signOutLocal() {
        Secrets.set("social.token", nil)
        signedIn = false
        me = nil; friends = []; incoming = []; outgoing = []; feed = []
        disk = SocialDisk()
        persist()
        retry?.cancel()
    }

    func deleteAccount(password: String) async throws {
        _ = try await call("POST", "/delete", body: ["password": password])
        signOutLocal()
    }

    func changePassword(old: String, new: String) async throws {
        _ = try await call("POST", "/password", body: ["old": old, "new": new])
    }

    // MARK: reading what is there

    func refreshAll() async {
        guard signedIn else { return }
        loading = true
        defer { loading = false }
        async let a: Void = refreshMe()
        async let b: Void = refreshFriends()
        async let c: Void = refreshFeed()
        _ = await (a, b, c)
        if !disk.inviteCode.isEmpty { let code = disk.inviteCode; disk.inviteCode = ""; persist(); _ = try? await redeem(code) }
    }

    func refreshMe() async {
        if let r = try? await call("GET", "/me") { me = SocialMe(r["me"] as? [String: Any] ?? [:]) }
    }

    func refreshFriends() async {
        guard let r = try? await call("GET", "/friends") else { return }
        func list(_ k: String) -> [SocialUser] { (r[k] as? [[String: Any]] ?? []).map(SocialUser.init) }
        friends = list("friends"); incoming = list("incoming"); outgoing = list("outgoing")
    }

    func refreshFeed() async {
        if let r = try? await call("GET", "/feed?limit=40") { feed = (r["items"] as? [[String: Any]] ?? []).map(SocialFeedItem.init) }
    }

    func loadMoreFeed() async {
        guard let last = feed.last, let r = try? await call("GET", "/feed?limit=40&before=\(Int(last.at))") else { return }
        let more = (r["items"] as? [[String: Any]] ?? []).map(SocialFeedItem.init)
        feed += more.filter { m in !feed.contains { $0.id == m.id } }
    }

    func profile(_ username: String) async throws -> SocialProfile {
        SocialProfile(try await call("GET", "/u/" + username))
    }

    // MARK: friends

    func request(_ u: String) async throws {
        let name = u.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
        _ = try await call("POST", "/friends/request", body: ["username": name])
        await refreshFriends()
    }

    /// accept, decline, cancel, remove, block
    func act(_ what: String, _ u: String) async throws {
        _ = try await call("POST", what == "block" ? "/blocks" : "/friends/" + what, body: ["username": u])
        await refreshFriends()
        await refreshFeed()
    }

    /// A link to share: it carries the server and a code, so the friend's phone connects by itself.
    func inviteLink() async throws -> URL {
        let r = try await call("POST", "/invites", body: ["max": 5, "days": 7])
        guard let code = r["code"] as? String, let u = SocialLink.make(server: server, code: code) else { throw SocialError.api("server") }
        return u
    }

    @discardableResult
    func redeem(_ code: String) async throws -> SocialUser {
        let r = try await call("POST", "/invites/redeem", body: ["code": code])
        await refreshFriends()
        await refreshFeed()
        return SocialUser(r["friend"] as? [String: Any] ?? [:])
    }

    // MARK: my profile

    func saveProfile(name: String, bio: String, favs: [(String, String)]) async throws {
        let r = try await call("PUT", "/me", body: ["name": name, "bio": bio, "favs": favs.map { ["title": $0.0, "author": $0.1] }])
        me = SocialMe(r["me"] as? [String: Any] ?? [:])
    }

    func setShare(_ on: Bool) {
        DB.shared.set("social.share", on ? "1" : "0")
        if on {
            // shared again: everything as it stands now, announced as nothing new
            disk.baselined = false
            disk.snaps = [:]
        } else {
            disk.outbox.events.removeAll()
        }
        persist()
        objectWillChange.send()
        Task {
            _ = try? await call("PUT", "/me", body: ["share": on])
            await refreshMe()
            if on { libraryChanged() }
        }
    }

    func setShareStats(_ on: Bool) {
        Task { _ = try? await call("PUT", "/me", body: ["shareStats": on]); await refreshMe() }
    }

    func setShareLists(_ on: Bool) {
        DB.shared.set("social.lists", on ? "1" : "0")
        disk.listsSig = ""
        persist()
        objectWillChange.send()
        Task { if let t = token { await pushStatsAndLists(t) } }
    }

    func uploadAvatar(_ img: UIImage) async throws {
        let side: CGFloat = 256
        let k = min(1, side / max(img.size.width, img.size.height))
        let size = CGSize(width: max(1, img.size.width * k), height: max(1, img.size.height * k))
        let r = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        guard let d = r.image(actions: { _ in img.draw(in: CGRect(origin: .zero, size: size)) }).jpegData(compressionQuality: 0.8) else { return }
        let res = try await call("PUT", "/me/avatar", body: ["data": d.base64EncodedString()])
        me = SocialMe(res["me"] as? [String: Any] ?? [:])
        avatars.removeAllObjects()
    }

    func removeAvatar() async {
        if let res = try? await call("DELETE", "/me/avatar") { me = SocialMe(res["me"] as? [String: Any] ?? [:]) }
        avatars.removeAllObjects()
    }

    // MARK: pictures of friends (fetched with the token, kept in memory)

    private let avatars = NSCache<NSString, UIImage>()

    func avatar(_ u: SocialUser) async -> UIImage? {
        guard u.av > 0, let t = token else { return nil }
        let key = "\(u.username)|\(u.av)" as NSString
        if let i = avatars.object(forKey: key) { return i }
        guard let d = try? await SocialAPI.raw("GET", "/u/\(u.username)/avatar", token: t, server: server), let i = UIImage(data: d) else { return nil }
        avatars.setObject(i, forKey: key)
        return i
    }

    // MARK: an invite link opened in the app

    /// Called by DeepLink: shows where we are going and waits for the owner's tap, since any app can open a wird:// link.
    func receiveJoin(_ url: URL) {
        guard let l = SocialLink.parse(url) else { ToastCenter.shared.show("رابط الدعوة غير صالح"); return }
        NovelBridge.clearScreen {
            BookLayer.shared.dismissNow()
            UserDefaults.standard.set("friends", forKey: "progress.sub")
            Router.shared.paths[.progress] = []
            if Router.shared.tab != .progress { Router.shared.select(.progress) }
            self.pendingJoin = l
        }
    }

    /// The owner said yes: the server is set, and the code is used (now when signed in there, else after signing up or in).
    func acceptJoin(_ l: SocialLink) async {
        pendingJoin = nil
        if signedIn && server != l.server {
            ToastCenter.shared.show("أنت مسجّل في سيرفر آخر. اخرج منه أولًا")
            return
        }
        if signedIn {
            do { let f = try await redeem(l.code); ToastCenter.shared.show("صرت صديق \(f.name)") }
            catch let e as SocialError { ToastCenter.shared.show(e.message) } catch {}
        } else {
            server = l.server
            disk.inviteCode = l.code
            persist()
            objectWillChange.send()
        }
    }

    /// the code waiting for the sign-up form (an invite link opened while signed out)
    var waitingInvite: String { disk.inviteCode }
    func clearWaitingInvite() { disk.inviteCode = ""; persist() }
}
