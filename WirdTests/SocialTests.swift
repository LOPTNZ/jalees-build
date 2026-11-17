import XCTest
@testable import Wird

/// «الأصدقاء»: the invite link, the server's address, the outbox and what changed in the library (no network, no screen).
final class SocialTests: XCTestCase {
    // MARK: links and addresses

    func testInviteLinkRoundTrip() {
        let u = SocialLink.make(server: "https://jalees.example.com", code: "ABCDEF123456")!
        XCTAssertEqual(SocialLink.parse(u), SocialLink(server: "https://jalees.example.com", code: "ABCDEF123456"))
    }

    func testInviteLinkParsing() {
        let l = SocialLink.parse(URL(string: "wird://friends/join?s=https%3A%2F%2Fjalees.example.com%2Fx&c=abcdef-123456")!)
        XCTAssertEqual(l, SocialLink(server: "https://jalees.example.com", code: "ABCDEF123456"))
        // not a join link, no code, a short code, a server that isn't https, other schemes
        XCTAssertNil(SocialLink.parse(URL(string: "wird://open?tab=notebook")!))
        XCTAssertNil(SocialLink.parse(URL(string: "wird://friends/join?s=https://a.example.com")!))
        XCTAssertNil(SocialLink.parse(URL(string: "wird://friends/join?s=https://a.example.com&c=ABC")!))
        XCTAssertNil(SocialLink.parse(URL(string: "wird://friends/join?s=http://evil.example.com&c=ABCDEF123456")!))
        XCTAssertNil(SocialLink.parse(URL(string: "https://friends/join?s=https://a.example.com&c=ABCDEF123456")!))
    }

    func testServerAddress() {
        XCTAssertEqual(SocialServer.normalized("jalees.example.com"), "https://jalees.example.com")
        XCTAssertEqual(SocialServer.normalized(" HTTPS://Jalees.Example.com/some/path?x=1 "), "https://jalees.example.com")
        XCTAssertEqual(SocialServer.normalized("http://192.168.0.194:8792"), "http://192.168.0.194:8792")
        XCTAssertEqual(SocialServer.normalized("http://100.75.48.114:8792"), "http://100.75.48.114:8792")
        XCTAssertEqual(SocialServer.normalized("http://localhost:8792"), "http://localhost:8792")
        // plain http to the internet, credentials in the address, nothing
        XCTAssertEqual(SocialServer.normalized("http://jalees.example.com"), "")
        XCTAssertEqual(SocialServer.normalized("https://user:pw@jalees.example.com"), "")
        XCTAssertEqual(SocialServer.normalized(""), "")
        XCTAssertEqual(SocialServer.normalized("ftp://example.com"), "")
    }

    func testNoDefaultServerYet() { XCTAssertEqual(SocialServer.defaultURL, "") }

    // MARK: the outbox

    private func book(_ t: String, kinds: [String] = [], priv: Bool = false, status: String = "reading") -> SocialEvent {
        var e = SocialEvent(cid: UUID().uuidString, type: "book", at: 1, title: t, author: "م")
        e.status = status; e.kinds = kinds; e.priv = priv
        return e
    }

    func testOutboxMergesChangesToTheSameBook() {
        var o = SocialOutbox()
        o.add(book("A", kinds: ["started"]))
        o.add(book("B", kinds: ["started"]))
        o.add(book("a", kinds: ["finished", "rated"], status: "done"))
        XCTAssertEqual(o.events.count, 2)
        XCTAssertEqual(o.events[0].status, "done")
        XCTAssertEqual(o.events[0].kinds, ["started", "finished", "rated"])
    }

    func testPrivateBookAnnouncesNothing() {
        var o = SocialOutbox()
        o.add(book("A", kinds: ["started"]))
        o.add(book("A", priv: true))
        XCTAssertEqual(o.events.count, 1)
        XCTAssertTrue(o.events[0].priv)
        XCTAssertEqual(o.events[0].kinds, [])
    }

    func testForgetRemovesWaitingChanges() {
        var o = SocialOutbox()
        o.add(book("A", kinds: ["started"]))
        o.add(SocialEvent(cid: "x", type: "forget", at: 2, title: "A", author: "م"))
        XCTAssertEqual(o.events.map(\.type), ["forget"])
    }

    func testBackoffGrowsAndResets() {
        var o = SocialOutbox()
        o.add(book("A"))
        XCTAssertTrue(o.ready(100))
        o.failed(100)
        XCTAssertEqual(o.nextTry, 130)
        XCTAssertFalse(o.ready(110))
        o.failed(130)
        XCTAssertEqual(o.nextTry, 190)
        for _ in 0..<20 { o.failed(0) }
        XCTAssertEqual(o.nextTry, 3600)
        o.sent(1)
        XCTAssertTrue(o.events.isEmpty)
        XCTAssertEqual(o.failures, 0)
        XCTAssertFalse(o.ready(0), "nothing waiting")
    }

    func testBatchesAndCap() {
        var o = SocialOutbox()
        for i in 0..<(SocialOutbox.cap + 50) {
            var e = SocialEvent(cid: "\(i)", type: "quote", at: 1, title: "A", author: "م")
            e.text = "q\(i)"
            o.add(e)
        }
        XCTAssertEqual(o.events.count, SocialOutbox.cap)
        XCTAssertEqual(o.batch(40).count, 40)
        o.sent(40)
        XCTAssertEqual(o.events.count, SocialOutbox.cap - 40)
    }

    func testOutboxSurvivesStorage() throws {
        var o = SocialOutbox()
        o.add(book("A", kinds: ["started"]))
        o.failed(5)
        let back = try JSONDecoder().decode(SocialOutbox.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back, o)
    }

    func testPayload() {
        var e = book("A", kinds: ["finished"], status: "done")
        e.rating = 4.5; e.review = "جميل"; e.spoiler = true; e.priv = false
        let p = e.payload()
        XCTAssertEqual(p["type"] as? String, "book")
        XCTAssertEqual(p["status"] as? String, "done")
        XCTAssertEqual(p["rating"] as? Double, 4.5)
        XCTAssertEqual(p["private"] as? Bool, false)
        XCTAssertEqual((p["book"] as? [String: Any])?["title"] as? String, "A")
        XCTAssertEqual(p["kinds"] as? [String], ["finished"])
    }

    // MARK: what changed in the library

    private func snap(_ t: String, _ status: String = "want", rating: Double = 0, review: String = "", priv: Bool = false) -> SocialBookSnap {
        var s = SocialBookSnap(title: t, author: "م")
        s.status = status; s.rating = rating; s.review = review; s.priv = priv
        return s
    }

    private func diff(_ old: [String: SocialBookSnap], _ new: [String: SocialBookSnap], baseline: Bool = false) -> [SocialEvent] {
        var n = 0
        return SocialDiff.events(old: old, new: new, baseline: baseline, now: 10, cid: { n += 1; return "c\(n)" }).events
    }

    func testNothingChangedSendsNothing() {
        let s = ["1": snap("A", "reading")]
        XCTAssertTrue(diff(s, s).isEmpty)
    }

    func testStartedFinishedRatedReviewed() {
        var e = diff(["1": snap("A")], ["1": snap("A", "reading")])
        XCTAssertEqual(e.map(\.kinds), [["started"]])
        e = diff(["1": snap("A", "reading")], ["1": snap("A", "done", rating: 4, review: "رائع")])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].kinds, ["finished", "rated", "reviewed"])
        // the same rating again announces nothing; a changed one does
        XCTAssertEqual(diff(["1": snap("A", "done", rating: 4)], ["1": snap("A", "done", rating: 4, review: "")]).count, 0)
        XCTAssertEqual(diff(["1": snap("A", "done", rating: 4)], ["1": snap("A", "done", rating: 3.5)])[0].kinds, ["rated"])
    }

    func testFirstSendSharesEverythingButAnnouncesNothing() {
        let e = diff([:], ["1": snap("A", "done", rating: 5, review: "x"), "2": snap("B", "reading")], baseline: true)
        XCTAssertEqual(e.count, 2)
        XCTAssertTrue(e.allSatisfy { $0.kinds.isEmpty })
    }

    func testPrivateBookIsHiddenNotAnnounced() {
        let e = diff(["1": snap("A", "reading")], ["1": snap("A", "done", rating: 5, priv: true)])
        XCTAssertEqual(e.count, 1)
        XCTAssertTrue(e[0].priv)
        XCTAssertTrue(e[0].kinds.isEmpty)
    }

    func testDeletedAndRenamedBooksAreForgotten() {
        var e = diff(["1": snap("A")], [:])
        XCTAssertEqual(e.map(\.type), ["forget"])
        e = diff(["1": snap("A")], ["1": snap("B")])
        XCTAssertEqual(e.map(\.type), ["forget", "book"])
        XCTAssertEqual(e[0].title, "A")
        XCTAssertEqual(e[1].title, "B")
    }
}
