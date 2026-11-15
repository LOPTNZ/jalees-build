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
}
