import XCTest
@testable import Wird

/// The pure parts of the server archive page: sizes, durations, progress, the multi-select, and the jobs the server describes.
@MainActor
final class ServerArchiveTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(ArchiveFormat.bytes(0), "0 B")
        XCTAssertEqual(ArchiveFormat.bytes(1536), "1.5 KB")
        XCTAssertEqual(ArchiveFormat.bytes(5 * 1024 * 1024), "5.0 MB")
        XCTAssertEqual(ArchiveFormat.bytes(-4), "0 B")
    }

    func testDuration() {
        XCTAssertEqual(ArchiveFormat.duration(20), "أقل من دقيقة")
        XCTAssertEqual(ArchiveFormat.duration(600), "10 دقيقة")
        XCTAssertEqual(ArchiveFormat.duration(7200), "2 ساعة")
        XCTAssertEqual(ArchiveFormat.duration(3 * 86_400), "3 يوم")
    }

    func testFractionAndPace() {
        XCTAssertEqual(ArchiveFormat.fraction(5, 10), 0.5)
        XCTAssertEqual(ArchiveFormat.fraction(5, 0), 0)
        XCTAssertEqual(ArchiveFormat.fraction(15, 10), 1)
        XCTAssertEqual(ArchiveFormat.perMinute(paceMs: 2500), 24)
        XCTAssertEqual(ArchiveFormat.perMinute(paceMs: 0), 0)
    }

    func testMissingAddressesAndToggle() {
        XCTAssertEqual(ArchiveFormat.missing(known: ["a"], incoming: ["a", "b", "b", "c"]), ["b", "c"])
        var s = Set<String>()
        ArchiveFormat.toggle(&s, "x")
        XCTAssertEqual(s, ["x"])
        ArchiveFormat.toggle(&s, "x")
        XCTAssertTrue(s.isEmpty)
    }

    func testJobParsing() {
        let j = ServerJob(["id": "ab12", "type": "site", "site": "kolnovel", "label": "", "state": "paused", "pausedBy": "blocked",
                           "discovering": false, "page": 3, "waiting": 7, "failed": 0, "eta": 3600,
                           "current": ["id": "x", "title": "رواية"],
                           "stats": ["found": 10, "added": 4, "novelsDone": 2, "chaptersFetched": 50, "chaptersTotal": 200, "errors": 1, "bytes": 2048, "lastError": "blocked 403"]])
        XCTAssertEqual(j.novelsDone, 2)
        XCTAssertEqual(j.fraction, 0.2, accuracy: 0.0001)
        XCTAssertTrue(j.active)
        XCTAssertEqual(j.eta, 3600)
        XCTAssertEqual(j.current, "رواية")
        XCTAssertTrue(j.stateText.contains("وقف"))
        XCTAssertTrue(j.title.contains("ملوك الروايات"))
        let done = ServerJob(["id": "z", "state": "done"])
        XCTAssertFalse(done.active)
        XCTAssertNil(done.eta)
    }

    func testFollowedParsing() {
        let n = ServerNovel(["id": "i", "url": "https://x/series/a/", "title": "أ", "chapters": 12, "saved": 10, "checked": 1700000000000.0, "paused": true, "complete": true, "newCount": 2, "updatedCount": 1])
        XCTAssertEqual(n.saved, 10)
        XCTAssertTrue(n.paused && n.complete)
        XCTAssertEqual(n.mode, "library")
        XCTAssertEqual(n.checked, 1700000000000.0)
    }
}
