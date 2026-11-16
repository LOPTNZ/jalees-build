import XCTest
@testable import Wird

/// The logic under the owner's notes, checked without a screen: the replacement rules, the server's address, the
/// orders a site's search is tried in.
@MainActor
final class LogicTests: XCTestCase {
    private let scope = "990001"

    override func tearDown() {
        Replacer.save([], scope)
        super.tearDown()
    }

    private func rule(_ from: String, _ to: String, forms: Bool = true, more: [(String, String)] = []) {
        var r = ReplaceRule()
        r.from = from
        r.to = to
        r.forms = forms
        r.more = more.map { ReplaceRule.Form(from: $0.0, to: $0.1) }
        Replacer.save([r], scope)
    }

    private func apply(_ s: String) -> String { Replacer.apply([s], novel: Int(scope)!)[0] }

    // MARK: replacement rules

    /// «اميليا» catches «إميليا» (the owner's example): hamza and alef forms don't matter.
    func testHamzaDoesNotMatter() {
        rule("اميليا", "العبده")
        XCTAssertEqual(apply("قالت إميليا شيئًا"), "قالت العبده شيئًا")
        XCTAssertEqual(apply("قالت أميليا شيئًا"), "قالت العبده شيئًا")
        XCTAssertEqual(apply("قالت اميليا شيئًا"), "قالت العبده شيئًا")
    }

    func testDiacriticsAndTaMarbuta() {
        rule("مكتبه", "دار")
        XCTAssertEqual(apply("في المكتبة القديمة"), "في الدار القديمة")
        XCTAssertEqual(apply("في مَكْتَبَة"), "في دار")
    }

    /// The forms with و ف ب ك ل ال and endings keep their pieces around the new word.
    func testFormsKeepPrefixesAndEndings() {
        rule("اله", "رب")
        XCTAssertEqual(apply("والإله قال"), "والرب قال")
        XCTAssertEqual(apply("بالإله"), "بالرب")
        XCTAssertEqual(apply("إلهه"), "ربه")
        XCTAssertEqual(apply("للإله"), "للرب")
    }

    /// Without forms only the word itself changes.
    func testWithoutForms() {
        rule("سالم", "سليم", forms: false)
        XCTAssertEqual(apply("سالم وبسالم"), "سليم وبسالم")
    }

    /// A word inside another word is left alone.
    func testWholeWordsOnly() {
        rule("ال", "X", forms: false)
        XCTAssertEqual(apply("المكتبة"), "المكتبة")
    }

    /// One rule, a family: each word becomes its own.
    func testFamilyInOneRule() {
        rule("إله", "رب", more: [("آلهة", "أرباب"), ("ألوهية", "ربوبية")])
        XCTAssertEqual(apply("الإله والآلهة والألوهية"), "الرب والأرباب والربوبية")
    }

    /// An empty «to» in a family member means the rule's own word.
    func testFamilyMemberWithoutItsOwnWord() {
        rule("اميليا", "العبده", more: [("ايمي", "")])
        XCTAssertEqual(apply("ايمي هنا"), "العبده هنا")
    }

    func testLatinNamesAnyCase() {
        rule("Emilia", "Emy")
        XCTAssertEqual(apply("EMILIA and emilia"), "Emy and Emy")
    }

    /// A rule turned off changes nothing.
    func testRuleOff() {
        var r = ReplaceRule()
        r.from = "سالم"
        r.to = "سليم"
        r.on = false
        Replacer.save([r], scope)
        XCTAssertEqual(apply("سالم"), "سالم")
    }

    /// Rules saved by an older build (no «more», no «on») still load.
    func testOldRulesDecode() throws {
        let old = #"[{"id":"x","from":"سالم","to":"سليم","forms":true}]"#.data(using: .utf8)!
        let list = try JSONDecoder().decode([ReplaceRule].self, from: old)
        XCTAssertEqual(list.first?.from, "سالم")
        XCTAssertEqual(list.first?.on, true)
        XCTAssertEqual(list.first?.more.count, 0)
    }

    func testPlain() {
        XCTAssertEqual(Replacer.plain("إِمِيلْيَا"), "اميليا")
        XCTAssertEqual(Replacer.plain("مكتبة"), "مكتبه")
        XCTAssertEqual(Replacer.plain("على"), "علي")
    }

    // MARK: searching sites

    /// The owner's novel: «Deep Sea Embers», searched as «embers of the deep sea».
    func testRotationsFindTheTitleOrder() {
        XCTAssertTrue(SearchWords.rotations("embers of the deep sea").contains("deep sea embers"))
    }

    func testRotationsLeaveArabicAlone() {
        XCTAssertTrue(SearchWords.rotations("جمرات البحر العميق").isEmpty)
        XCTAssertTrue(SearchWords.rotations("ember").isEmpty)
    }

    func testHasArabic() {
        XCTAssertTrue(SearchWords.hasArabic("جمرات"))
        XCTAssertFalse(SearchWords.hasArabic("Deep Sea"))
    }

    // MARK: the server's address

    func testServerAddress() {
        XCTAssertEqual(ServerLink.normalized("100.75.48.114"), "http://100.75.48.114:8790")
        XCTAssertEqual(ServerLink.normalized(" http://100.75.48.114:8790/ "), "http://100.75.48.114:8790")
        XCTAssertEqual(ServerLink.normalized("100.75.48.114:8790/novels"), "http://100.75.48.114:8790")
        XCTAssertEqual(ServerLink.normalized("https://jalees.example.com"), "https://jalees.example.com")
        XCTAssertEqual(ServerLink.normalized(""), "")
    }

    // MARK: 2.2.1

    /// «deep sea»: the novel named so comes before ones that only hold the words somewhere.
    func testSearchRanksTheNameFirst() {
        let items: [[String: Any]] = [
            ["title": "Lighthouse Survival: The Deep Sea Calls"],
            ["title": "I Promise You a Love As Deep As the Sea"],
            ["title": "Deep Sea Embers"],
            ["title": "deep sea"],
        ]
        let titles = SearchWords.ranked(items, for: "Deep sea").compactMap { $0["title"] as? String }
        XCTAssertEqual(titles, ["deep sea", "Deep Sea Embers", "Lighthouse Survival: The Deep Sea Calls", "I Promise You a Love As Deep As the Sea"])
        // Arabic: hamza and marks don't matter
        let ar = SearchWords.ranked([["title": "سيد التمني"], ["title": "لورد الغوامض"]], for: "لُورد")
        XCTAssertEqual(ar.first?["title"] as? String, "لورد الغوامض")
    }

    func testTailscaleAddresses() {
        XCTAssertTrue(ServerLink.isTailscale("100.75.48.114"))
        XCTAssertTrue(ServerLink.isTailscale("100.127.0.1"))
        XCTAssertFalse(ServerLink.isTailscale("100.128.0.1"))
        XCTAssertFalse(ServerLink.isTailscale("192.168.0.194"))
        XCTAssertFalse(ServerLink.isTailscale("jalees.example.com"))
    }

    /// A drag starts where the covers are (they follow the finger from there), and letting go settles on a book.
    func testCarouselDragStartsInPlace() {
        let car = CarouselState()
        car.setBooks(["a", "b", "c", "d"], start: "b")
        XCTAssertEqual(car.pos, 1)
        car.grab()
        car.dragTo(1.3)
        XCTAssertEqual(car.finger, 1.3, accuracy: 0.0001)
        // no jump: the covers move on the display's clock, not all at once with the touch
        XCTAssertEqual(car.pos, 1, accuracy: 0.0001)
        car.go(to: 2)
        XCTAssertFalse(car.dragging)
        XCTAssertEqual(car.target, 2)
    }

    private func utc(_ s: String) -> Double { ISO8601DateFormatter().date(from: s)!.timeIntervalSince1970 }

    /// Daily allowances start again at midnight in California (PST in winter, PDT in summer), plus a minute.
    func testGeminiResetIsPacificMidnight() {
        // 02:00 PST on 16 Nov -> reset at 00:00 PST on 17 Nov = 08:00 UTC
        XCTAssertEqual(GeminiKeyRotation.nextReset(after: utc("2026-11-16T10:00:00Z")), utc("2026-11-17T08:01:00Z"))
        // 23:30 PST on 16 Nov is already 17 Nov in UTC; still the same reset
        XCTAssertEqual(GeminiKeyRotation.nextReset(after: utc("2026-11-17T07:30:00Z")), utc("2026-11-17T08:01:00Z"))
        // summer: 05:00 PDT on 1 Jul -> 00:00 PDT on 2 Jul = 07:00 UTC
        XCTAssertEqual(GeminiKeyRotation.nextReset(after: utc("2026-07-01T12:00:00Z")), utc("2026-07-02T07:01:00Z"))
    }

    /// The first key that isn't out is used; a key that ran out is skipped until its reset, then key 1 is back.
    func testGeminiKeyRotation() {
        let ids = ["a", "b", "c"]
        let now = utc("2026-11-16T10:00:00Z")
        let reset = GeminiKeyRotation.nextReset(after: now)
        XCTAssertEqual(GeminiKeyRotation.pick(ids: ids, outUntil: [:], now: now), "a")
        XCTAssertEqual(GeminiKeyRotation.pick(ids: ids, outUntil: ["a": reset], now: now), "b")
        XCTAssertEqual(GeminiKeyRotation.pick(ids: ids, outUntil: ["a": reset, "b": reset], now: now), "c")
        XCTAssertNil(GeminiKeyRotation.pick(ids: ids, outUntil: ["a": reset, "b": reset, "c": reset], now: now))
        // b is out but a is fine: a stays first
        XCTAssertEqual(GeminiKeyRotation.pick(ids: ids, outUntil: ["b": reset], now: now), "a")
        // after the reset key 1 is used again
        XCTAssertEqual(GeminiKeyRotation.pick(ids: ids, outUntil: ["a": reset, "b": reset], now: reset + 1), "a")
        XCTAssertEqual(GeminiKeyRotation.usable(ids: ids, outUntil: ["a": reset], now: now), ["b", "c"])
    }

    func testGeminiKeyIsMasked() {
        XCTAssertEqual(GeminiKeyRotation.mask("AIzaSyABCDEFGHIJKLMNOP1234"), "AIza…1234")
        XCTAssertEqual(GeminiKeyRotation.mask("short"), "••••••")
    }

    func testNotFoundIsKnown() {
        if case NovelError.http(404) = NovelError.http(404) {} else { XCTFail() }
        XCTAssertEqual(NovelError.http(404).localizedDescription, "الصفحة مو موجودة في الموقع (404)")
    }
}
