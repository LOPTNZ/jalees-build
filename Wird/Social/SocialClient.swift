import SwiftUI
import UIKit
import Combine

// «الأصدقاء»: the network and the state behind the screens (SocialViews.swift). Once signed in, everything happens by
// itself: library changes become events in an outbox, sent in the background with growing waits, and the screens
// only read the state. Nothing here waits for the network on the screen's thread.

enum SocialError: Error {
    case offline, auth, noServer, insecure
    case api(String)
    /// a 400: the server will never accept this request as it is (the outbox drops such events)
    case bad(String)
    case status(Int)

    var message: String {
        switch self {
        case .offline: return "تعذّر الوصول إلى السيرفر. تحقق من الاتصال ومن العنوان."
        case .auth: return "انتهت الجلسة. سجّل الدخول من جديد."
        case .noServer: return "اكتب عنوان سيرفر الأصدقاء أولًا."
        case .insecure: return "كلمة السر لا تُرسل إلا عبر https (أو شبكة Tailscale). غيّر عنوان السيرفر إلى https."
        case .status(let c): return "السيرفر ردّ بخطأ (\(c))."
        case .bad(let code): return SocialError.api(code).message
        case .api(let code):
            return ["bad_login": "اسم المستخدم أو كلمة السر غير صحيحة.", "locked": "محاولات كثيرة خاطئة. جرّب بعد قليل.",
                    "slow_down": "طلبات كثيرة. جرّب بعد قليل.", "taken": "اسم المستخدم محجوز.",
                    "bad_username": "اسم المستخدم: من 3 إلى 20 حرفًا إنجليزيًا صغيرًا أو أرقامًا أو _",
                    "bad_password": "كلمة السر 8 أحرف على الأقل.", "closed": "التسجيل مغلق: تحتاج دعوة من صديق.",
                    "full": "السيرفر ممتلئ.", "no_user": "ما وجدنا هذا المستخدم.", "already": "أنتما صديقان بالفعل.",
                    "bad_code": "رمز الدعوة غير صالح أو منتهٍ.", "own_code": "هذا رمز دعوتك أنت.", "too_big": "الصورة كبيرة.",
                    "bad_image": "الصورة غير صالحة.", "too_many_friends": "وصلت الحد الأعلى للأصدقاء.",
                    "too_many_requests": "عندك طلبات كثيرة معلّقة.", "too_many_invites": "عندك دعوات كثيرة فعّالة.",
                    "bad_name": "اكتب اسمًا.", "keychain": "تعذّر حفظ الجلسة على هذا الجهاز."][code] ?? "تعذّر الطلب (\(code))."
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
        if let e = err { throw code == 400 ? SocialError.bad(e) : SocialError.api(e) }
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
    /// a switch the server hasn't heard yet (PUT /me failed); sent before any event
    var pendingShare: Bool? = nil
    var pendingShareStats: Bool? = nil
    /// private books once sent their content: the first run after the fix tells the server to forget them
    var cleanedPrivate: Bool? = nil
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
    @Published private(set) var blocked: [SocialUser] = []
    /// the first read hasn't finished; and the last read couldn't reach the server
    @Published private(set) var loaded = false
    @Published private(set) var offline = false
    /// an invite link waiting for the owner's confirmation (SocialViews shows it)
    @Published var pendingJoin: SocialLink?

    private var token: String? { Secrets.get("social.token") }
    private var disk = SocialDisk()
    private var cancel = Set<AnyCancellable>()
    private var flushing = false
    private var retry: Task<Void, Never>?
    private var started = false
    /// when stats or lists need another try (seconds since 1970)
    private var wake: Double?
    private var lastRefresh = 0.0

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
        // the friends page shows what is there now, not what was there when the app was last open
        if Date().timeIntervalSince1970 - lastRefresh > 30 { Task { await refreshAll() } }
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
        if disk.cleanedPrivate != true {
            disk.snaps = disk.snaps.filter { !$0.value.priv }
            disk.cleanedPrivate = true
        }
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
        // a private book's quote is never sent
        let key = SocialEvent.key(title, author)
        if Library.shared.state.books.contains(where: { $0.raw.bool("socialPrivate") && SocialEvent.key($0.title, $0.author) == key }) { return }
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
        // no token (the Keychain lost it): that is being signed out, not something to retry every few seconds
        guard let t = token else { signOutLocal(); return }
        let nowT = { Date().timeIntervalSince1970 }
        guard nowT() >= disk.outbox.nextTry else { return }
        wake = nil
        // the switches first: no event goes while the server's idea of them is out of date
        guard await pushSettings(t) else { return }
        var size = 40
        while signedIn, disk.outbox.ready(nowT()) {
            // by bytes too: the server refuses a body over 96 KB
            let batch = disk.outbox.batch(size, maxBytes: 60_000)
            let cids = Set(batch.map(\.cid))
            do {
                _ = try await SocialAPI.call("POST", "/sync", body: ["events": batch.map { $0.payload() }], token: t, server: server)
                disk.outbox.sent(cids: cids)
                size = 40
            } catch let e as SocialError {
                switch e {
                case .auth: signOutLocal(); return
                case .bad(let code) where code.hasPrefix("bad_"):
                    // the server will never take this as it is: a lone event goes, a bigger batch is cut in halves to find it
                    if batch.count == 1 { disk.outbox.drop(cids: cids) } else { size = max(1, batch.count / 2) }
                case .api("too_big") where batch.count > 1:
                    size = max(1, batch.count / 2)
                // too many requests, a server error, no network: the events stay, and it is tried again later
                default: disk.outbox.failed(nowT())
                }
            } catch {
                disk.outbox.failed(nowT())
            }
            persist()
        }
        guard signedIn, disk.outbox.events.isEmpty else { return }
        await pushStatsAndLists(t)
    }

    /// «شارك قراءتي» and «أرقامي» that the server hasn't heard yet. False when sending must wait.
    private func pushSettings(_ t: String) async -> Bool {
        for key in ["share", "shareStats"] {
            guard let on = key == "share" ? disk.pendingShare : disk.pendingShareStats else { continue }
            do { _ = try await SocialAPI.call("PUT", "/me", body: [key: on], token: t, server: server) }
            catch SocialError.auth { signOutLocal(); return false }
            catch { disk.outbox.failed(Date().timeIntervalSince1970); persist(); return false }
            // changed again while this was in the air: the newer value is still waiting
            if key == "share", disk.pendingShare == on { disk.pendingShare = nil }
            if key == "shareStats", disk.pendingShareStats == on { disk.pendingShareStats = nil }
            persist()
        }
        return true
    }

    private func scheduleRetry() {
        retry?.cancel()
        guard signedIn else { return }
        var at: Double?
        if !disk.outbox.events.isEmpty || disk.pendingShare != nil || disk.pendingShareStats != nil { at = disk.outbox.nextTry }
        if let w = wake { at = min(at ?? w, w) }
        guard let when = at else { return }
        let wait = max(5, when - Date().timeIntervalSince1970)
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(wait, 3600) * 1_000_000_000))
            if !Task.isCancelled { self?.flush() }
        }
    }

    private func wakeAt(_ t: Double) { wake = min(wake ?? t, t) }

    /// the numbers and lists on the profile, when they changed (stats at most every two minutes; a change inside that
    /// wait is pushed when it ends, and a failed push is tried again later)
    private func pushStatsAndLists(_ t: String) async {
        guard shareReading else { return }
        let all = Library.shared.state
        // private books are left out of the numbers too
        var st = all
        let hidden = Set(all.books.filter { $0.raw.bool("socialPrivate") }.map(\.id))
        if !hidden.isEmpty {
            st.books.removeAll { hidden.contains($0.id) }
            st.sessions.removeAll { hidden.contains($0.bookId) }
        }
        let stats: [String: Any] = ["booksYear": st.finishedThisYear, "booksTotal": st.finishedBooks.count, "pages": Int(st.unitsRead("page")),
                                    "minutes": Int(st.totalMin), "streak": st.streak.cur]
        let sig = stats.keys.sorted().map { "\($0)=\(stats[$0] ?? 0)" }.joined(separator: ",")
        let nowT = Date().timeIntervalSince1970
        if sig != disk.statsSig {
            if nowT - disk.statsAt > 120 {
                do {
                    _ = try await SocialAPI.call("PUT", "/me/stats", body: stats, token: t, server: server)
                    disk.statsSig = sig
                    disk.statsAt = Date().timeIntervalSince1970
                } catch SocialError.auth { signOutLocal(); return }
                catch { disk.outbox.failed(Date().timeIntervalSince1970); wakeAt(disk.outbox.nextTry) }
            } else {
                wakeAt(disk.statsAt + 120)
            }
        }
        var lists: [[String: Any]] = []
        if shareLists {
            var names: [String] = []
            for b in st.books { for c in b.cols where !names.contains(c) { names.append(c) } }
            for c in names.prefix(20) {
                let bs = st.books.filter { $0.cols.contains(c) && !$0.title.isEmpty }
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
        if lsig != disk.listsSig {
            do {
                _ = try await SocialAPI.call("PUT", "/me/lists", body: ["lists": lists], token: t, server: server)
                disk.listsSig = lsig
            } catch SocialError.auth { signOutLocal(); return }
            catch { disk.outbox.failed(Date().timeIntervalSince1970); wakeAt(disk.outbox.nextTry) }
        }
        persist()
    }

    // MARK: accounts

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        do { return try await SocialAPI.call(method, path, body: body, token: token, server: server) }
        catch SocialError.auth { signOutLocal(); throw SocialError.auth }
    }

    private func began(_ r: [String: Any], _ user: String) async throws {
        // a session that can't be kept is no sign-in
        guard let t = r["token"] as? String, Secrets.set("social.token", t) else { throw SocialError.api("keychain") }
        DB.shared.set("social.user", user)
        me = SocialMe(r["me"] as? [String: Any] ?? [:])
        signedIn = true
        disk = SocialDisk()
        persist()
        // off on this phone: the server must hear it before anything else (sent later if this fails)
        if !shareReading { disk.pendingShare = false; persist(); flush() }
        libraryChanged()
        await refreshAll()
    }

    func signUp(server s: String, username u: String, name: String, password: String, invite: String, ownerCode: String = "") async throws {
        let sv = SocialServer.normalized(s)
        guard !sv.isEmpty else { throw SocialError.noServer }
        guard SocialServer.allowsCredentials(sv) else { throw SocialError.insecure }
        var body: [String: Any] = ["username": u, "name": name, "password": password, "invite": invite, "device": UIDevice.current.name]
        if !ownerCode.isEmpty { body["signup"] = ownerCode }
        let r = try await SocialAPI.call("POST", "/register", body: body, token: nil, server: sv)
        DB.shared.set("social.url", sv)
        try await began(r, u.lowercased())
    }

    func signIn(server s: String, username u: String, password: String, invite: String) async throws {
        let sv = SocialServer.normalized(s)
        guard !sv.isEmpty else { throw SocialError.noServer }
        guard SocialServer.allowsCredentials(sv) else { throw SocialError.insecure }
        let r = try await SocialAPI.call("POST", "/login", body: ["username": u, "password": password, "device": UIDevice.current.name], token: nil, server: sv)
        DB.shared.set("social.url", sv)
        try await began(r, u.lowercased())
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
        blocked = []; loaded = false; offline = false
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
        lastRefresh = Date().timeIntervalSince1970
        loading = true
        defer { loading = false }
        async let a = refreshMe()
        async let b = refreshFriends()
        async let c = refreshFeed()
        let ok = await (a, b, c)
        guard signedIn else { return }
        offline = !(ok.0 && ok.1 && ok.2)
        if ok.0 || ok.1 || ok.2 { loaded = true }
        if !disk.inviteCode.isEmpty { let code = disk.inviteCode; disk.inviteCode = ""; persist(); _ = try? await redeem(code) }
    }

    @discardableResult
    func refreshMe() async -> Bool {
        guard let r = try? await call("GET", "/me") else { return false }
        me = SocialMe(r["me"] as? [String: Any] ?? [:])
        return true
    }

    @discardableResult
    func refreshFriends() async -> Bool {
        guard let r = try? await call("GET", "/friends") else { return false }
        func list(_ k: String) -> [SocialUser] { (r[k] as? [[String: Any]] ?? []).map(SocialUser.init) }
        friends = list("friends"); incoming = list("incoming"); outgoing = list("outgoing")
        return true
    }

    @discardableResult
    func refreshFeed() async -> Bool {
        guard let r = try? await call("GET", "/feed?limit=40") else { return false }
        feed = (r["items"] as? [[String: Any]] ?? []).map(SocialFeedItem.init)
        return true
    }

    func loadMoreFeed() async {
        // paged by time and id: several events can share one time
        guard let last = feed.last, let r = try? await call("GET", "/feed?limit=40&before=\(last.at):\(last.id)") else { return }
        let more = (r["items"] as? [[String: Any]] ?? []).map(SocialFeedItem.init)
        feed += more.filter { m in !feed.contains { $0.id == m.id } }
    }

    func refreshBlocks() async {
        guard let r = try? await call("GET", "/blocks") else { return }
        blocked = (r["blocks"] as? [[String: Any]] ?? []).map(SocialUser.init)
    }

    func unblock(_ u: String) async throws {
        _ = try await call("POST", "/unblock", body: ["username": u])
        await refreshBlocks()
        await refreshFriends()
        await refreshFeed()
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
        if what == "block" { await refreshBlocks() }
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
        // kept until the server has heard it (a failed PUT is sent again before any event)
        disk.pendingShare = on
        disk.outbox.nextTry = 0
        persist()
        objectWillChange.send()
        if on { libraryChanged() }
        flush()
        Task { await refreshMe() }
    }

    func setShareStats(_ on: Bool) {
        disk.pendingShareStats = on
        disk.outbox.nextTry = 0
        persist()
        // the switch shows the new value at once, whatever the server has said so far
        me?.shareStats = on
        flush()
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
        // signed in on another server: say so now, not after a confirmation that can't lead anywhere
        if signedIn && server != l.server { ToastCenter.shared.show("أنت مسجّل في سيرفر آخر. اخرج منه أولًا"); return }
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
        guard SocialServer.allowsCredentials(l.server) else { ToastCenter.shared.show(SocialError.insecure.message); return }
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
    /// drop what an invite link set while signed out: the waiting code and the server address
    func clearJoin() { disk.inviteCode = ""; persist(); DB.shared.set("social.url", ""); objectWillChange.send() }
}
