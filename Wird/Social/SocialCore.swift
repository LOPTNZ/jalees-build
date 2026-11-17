import Foundation

// «الأصدقاء» (friends): the pure parts, with no network and no screen, so tests can check them.
// The server is server/social.js; its address, an invite link, the outbox of events waiting to be sent, and what
// changed in the library since the last send.

/// The social server's address. A default can be compiled in later: put the address in `defaultURL`.
enum SocialServer {
    static let defaultURL = ""

    /// What was typed, as an address the app can use: https:// when no scheme is given; http:// only for a machine
    /// on your own network (a home server, Tailscale, localhost); no path, query or trailing slash. "" when unusable.
    static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 200 else { return "" }
        if !t.contains("://") { t = "https://" + t }
        guard var c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil else { return "" }
        guard scheme == "https" || (scheme == "http" && isLocalHost(host)) else { return "" }
        c.scheme = scheme
        c.host = host
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.string ?? ""
    }

    /// Sign-in and sign-up send a password, so they go only over https, or over plain http inside Tailscale (100.64.0.0/10).
    static func allowsCredentials(_ server: String) -> Bool {
        guard let c = URLComponents(string: server), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        let p = host.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p.allSatisfy { (0...255).contains($0) } && p[0] == 100 && (64...127).contains(p[1])
    }

    /// localhost, a private or Tailscale address, a `.local` name: the only places plain http is accepted
    static func isLocalHost(_ h: String) -> Bool {
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".ts.net") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 100 && (64...127).contains(p[1]))
    }
}

/// wird://friends/join?s=<https server>&c=<code>
struct SocialLink: Equatable {
    let server: String
    let code: String

    static func parse(_ url: URL) -> SocialLink? {
        guard url.scheme == "wird", url.host == "friends", url.path == "/join" || url.path == "join" || url.path.isEmpty else { return nil }
        var q: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        let server = SocialServer.normalized(q["s"] ?? "")
        let code = (q["c"] ?? "").uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !server.isEmpty, (6...32).contains(code.count) else { return nil }
        return SocialLink(server: server, code: code)
    }

    /// the link to share for an invite code on a server
    static func make(server: String, code: String) -> URL? {
        var c = URLComponents()
        c.scheme = "wird"
        c.host = "friends"
        c.path = "/join"
        c.queryItems = [URLQueryItem(name: "s", value: server), URLQueryItem(name: "c", value: code)]
        return c.url
    }
}

// MARK: - what is sent

/// One thing for the server: a book's whole shared state («book»), a quote chosen to share, or a book to forget.
struct SocialEvent: Codable, Equatable {
    var cid: String
    var type: String            // "book" | "quote" | "forget"
    var at: Double              // ms
    var title: String
    var author: String
    var isbn = ""
    var hue: Double? = nil
    // type "book"
    var status = "want"
    var rating = 0.0
    var review = ""
    var spoiler = false
    var start = 0.0
    var finish = 0.0
    var priv = false
    /// what to announce in the feed: "started", "finished", "rated", "reviewed"
    var kinds: [String] = []
    // type "quote"
    var text = ""

    var key: String { SocialEvent.key(title, author) }
    static func key(_ t: String, _ a: String) -> String { t.lowercased() + "|" + a.lowercased() }

    /// the JSON the server reads
    func payload() -> [String: Any] {
        var book: [String: Any] = ["title": title, "author": author]
        if !isbn.isEmpty { book["isbn"] = isbn }
        if let h = hue { book["hue"] = h }
        var o: [String: Any] = ["cid": cid, "type": type, "at": at, "book": book]
        if type == "book" {
            o["status"] = status; o["rating"] = rating; o["review"] = review; o["spoiler"] = spoiler
            o["start"] = start; o["finish"] = finish; o["private"] = priv; o["kinds"] = kinds
        } else if type == "quote" {
            o["text"] = text
        }
        return o
    }
}

/// Events waiting to be sent. Sending is tried again later with growing waits; nothing blocks the screen.
struct SocialOutbox: Codable, Equatable {
    var events: [SocialEvent] = []
    var failures = 0
    /// not before this time (seconds since 1970)
    var nextTry = 0.0

    static let cap = 600

    mutating func add(_ e: SocialEvent) {
        switch e.type {
        case "book":
            // a book changed again before the last change was sent: one event, the newer state, both announcements
            if let i = events.firstIndex(where: { $0.type == "book" && $0.key == e.key }) {
                var n = e
                n.kinds = events[i].kinds + e.kinds.filter { !events[i].kinds.contains($0) }
                // a private book announces nothing
                if n.priv { n.kinds = [] }
                events[i] = n
            } else { events.append(e) }
        case "forget":
            events.removeAll { $0.type == "book" && $0.key == e.key }
            events.append(e)
        default:
            events.append(e)
        }
        if events.count > Self.cap { events.removeFirst(events.count - Self.cap) }
    }

    func ready(_ now: Double) -> Bool { !events.isEmpty && now >= nextTry }

    func batch(_ n: Int = 40) -> [SocialEvent] { Array(events.prefix(n)) }

    /// the first `n` events were taken by the server
    mutating func sent(_ n: Int) {
        events.removeFirst(min(n, events.count))
        failures = 0
        nextTry = 0
    }

    /// 30 s, 1 min, 2 min … at most an hour
    mutating func failed(_ now: Double) {
        failures += 1
        nextTry = now + min(3600, 30 * pow(2, Double(min(failures - 1, 8))))
    }

    /// a wrong answer the server will never accept (a bad request): that batch is dropped so it doesn't block the rest
    mutating func drop(_ n: Int) { events.removeFirst(min(n, events.count)); failures = 0; nextTry = 0 }
}

/// What the server last heard about one book.
struct SocialBookSnap: Codable, Equatable {
    var title: String
    var author: String
    var isbn = ""
    var hue = 0.0
    var status = "want"
    var rating = 0.0
    var review = ""
    var spoiler = false
    var start = 0.0
    var finish = 0.0
    var priv = false
}

enum SocialDiff {
    /// The events for what changed between the last sent snapshots and the library now.
    /// `baseline`: the first send after signing in (or turning sharing on): everything is shared as it stands,
    /// nothing is announced in the feed. Returns the events and the snapshots to remember once they are queued.
    static func events(old: [String: SocialBookSnap], new: [String: SocialBookSnap], baseline: Bool, now: Double,
                       cid: () -> String = { UUID().uuidString }) -> (events: [SocialEvent], snaps: [String: SocialBookSnap]) {
        var out: [SocialEvent] = []
        for (id, n) in new.sorted(by: { $0.key < $1.key }) {
            let o = old[id]
            if o == n { continue }
            var kinds: [String] = []
            if !baseline && !n.priv {
                if n.status == "reading" && o?.status != "reading" { kinds.append("started") }
                if n.status == "done" && o?.status != "done" { kinds.append("finished") }
                if n.rating > 0 && n.rating != o?.rating { kinds.append("rated") }
                if !n.review.isEmpty && n.review != o?.review { kinds.append("reviewed") }
            }
            // the book's title or author changed: the old one goes, the new one comes
            if let o = o, SocialEvent.key(o.title, o.author) != SocialEvent.key(n.title, n.author) {
                out.append(SocialEvent(cid: cid(), type: "forget", at: now, title: o.title, author: o.author))
            }
            var e = SocialEvent(cid: cid(), type: "book", at: now, title: n.title, author: n.author)
            e.isbn = n.isbn; e.hue = n.hue; e.status = n.status; e.rating = n.rating; e.review = n.review; e.spoiler = n.spoiler
            e.start = n.start; e.finish = n.finish; e.priv = n.priv; e.kinds = kinds
            out.append(e)
        }
        for (id, o) in old.sorted(by: { $0.key < $1.key }) where new[id] == nil {
            out.append(SocialEvent(cid: cid(), type: "forget", at: now, title: o.title, author: o.author))
        }
        return (out, new)
    }
}
