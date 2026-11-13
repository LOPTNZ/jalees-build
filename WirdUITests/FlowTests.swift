import XCTest

/// Walks the app the way the owner uses it, across screens (the paths that broke before), keeping a picture of each
/// step. Pictures go to the folder in the SHOTS environment value (set with TEST_RUNNER_SHOTS on the build machine)
/// and into the test results. Tests run in name order on one install: the demo library first, then what they add.
final class FlowTests: XCTestCase {
    private var app: XCUIApplication!
    private static var dir: URL? { ProcessInfo.processInfo.environment["SHOTS"].map { URL(fileURLWithPath: $0) } }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        app.launch()
        _ = app.buttons["المكتبة"].waitForExistence(timeout: 15)
        sleep(1)
    }

    // MARK: helpers

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let d = Self.dir {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: d.appendingPathComponent(name + ".png"))
        }
    }

    @discardableResult
    private func tap(_ e: XCUIElement, _ what: String, timeout: Double = 6) -> Bool {
        guard e.waitForExistence(timeout: timeout) else { XCTFail("not found: \(what)"); return false }
        if !e.isHittable { sleep(1) }
        e.tap()
        return true
    }

    private func button(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }

    private func buttonStarting(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func tab(_ name: String) { tap(button(name), "tab " + name); sleep(1) }

    // MARK: flows

    /// Every tab of both groups opens, and coming back to the library keeps it as it was.
    func test01Tabs() {
        shot("ui01-library")
        for (t, n) in [("دفتري", "ui02-notebook"), ("إنجازاتي", "ui03-progress"), ("الإعدادات", "ui04-settings")] { tab(t); shot(n) }
        tab("تصفّح"); shot("ui05-browse")
        for (t, n) in [("التحديثات", "ui06-updates"), ("التحميلات", "ui07-downloads"), ("السجل", "ui08-history")] { tab(t); shot(n) }
        tab("المكتبة"); shot("ui09-library-again")
        XCTAssertTrue(button("إضافة كتاب").exists, "the library header is back")
    }

    /// A book typed by hand: + → كتاب واحد → title → save → it shows in the library.
    func test02AddBookByHand() {
        tap(button("إضافة كتاب"), "add")
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "كتاب واحد")).firstMatch, "one book")
        sleep(1)
        shot("ui10-form")
        let title = app.textFields["العنوان"].firstMatch
        if tap(title, "title field") {
            title.typeText("كتاب تجربة الواجهة")
            shot("ui11-form-typed")
            tap(button("حفظ"), "save")
            sleep(2)
            shot("ui12-after-add")
            XCTAssertTrue(app.staticTexts["كتاب تجربة الواجهة"].waitForExistence(timeout: 4), "the new book is in the library")
        }
    }

    /// The middle book: quick progress sheet, then its page (swipe up), its edit form and back.
    func test03BookPage() {
        if tap(button("تحديث التقدم"), "quick progress") {
            sleep(1)
            shot("ui13-quick-progress")
            app.swipeDown(velocity: .fast)
            sleep(1)
        }
        let car = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "مكتبتك")).firstMatch
        if car.waitForExistence(timeout: 4) { car.swipeUp() } else { app.swipeUp() }
        sleep(2)
        shot("ui14-book-page")
        if tap(button("تعديل الكتاب"), "edit book") {
            sleep(1)
            shot("ui15-edit-form")
            tap(button("إغلاق"), "close form")
            sleep(1)
        }
        app.swipeUp()
        shot("ui16-book-page-lower")
        // back: the edge swipe
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        sleep(1)
        shot("ui17-back-to-library")
    }

    /// A reading session: start from the library, let it run, end it and save it.
    func test04Session() {
        let go = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "تابع", "ابدأ")).firstMatch
        guard tap(go, "start reading") else { return }
        sleep(3)
        shot("ui18-session")
        if tap(button("إنهاء"), "end") {
            sleep(1)
            shot("ui19-session-end")
            tap(button("حفظ الجلسة"), "save session")
            sleep(2)
            shot("ui20-session-saved")
        }
    }

    /// The notebook: a new quote typed and saved, then searched.
    func test05NotebookQuote() {
        tab("دفتري")
        tap(button("اقتباس"), "new quote")
        sleep(1)
        let text = app.textViews.firstMatch
        if tap(text, "quote text") {
            text.typeText("نص اقتباس من اختبار الواجهة")
            shot("ui21-quote-form")
            tap(button("حفظ"), "save quote")
            sleep(2)
            shot("ui22-notebook-after")
        }
        tap(buttonStarting("أفكار"), "thoughts list")
        shot("ui23-thoughts")
        tap(buttonStarting("شخصيات"), "characters")
        shot("ui24-characters")
        tap(buttonStarting("معلومات"), "highlights")
        shot("ui25-highlights")
    }

    /// The notebook's floating +: its menu, then a thought from it.
    func test05bNotebookFab() {
        tab("دفتري")
        if tap(button("إضافة للدفتر"), "notebook +") {
            sleep(1)
            shot("ui25b-fab-menu")
            tap(buttonStarting("فكرة"), "thought from the menu")
            sleep(1)
            shot("ui25c-thought-form")
            tap(button("إغلاق"), "close the form")
        }
    }

    /// A book page's card and PDF summary.
    func test05cCardAndPDF() {
        let car = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "مكتبتك")).firstMatch
        if car.waitForExistence(timeout: 4) { car.swipeUp() } else { app.swipeUp() }
        sleep(2)
        for _ in 0..<6 where !button("بطاقة الكتاب").isHittable { app.swipeUp() }
        if tap(buttonStarting("بطاقة الكتاب"), "book card") {
            sleep(2)
            shot("ui25d-book-card")
            app.swipeDown(velocity: .fast)
            sleep(1)
        }
        if tap(buttonStarting("ملخص PDF"), "pdf summary") {
            sleep(3)
            shot("ui25e-pdf")
            app.swipeUp()
            sleep(1)
            shot("ui25f-pdf-preview")
        }
    }

    /// إنجازاتي: goals with the achievements, then stats with the charts.
    func test06Progress() {
        tab("إنجازاتي")
        tap(button("زد"), "daily goal +")
        shot("ui26-goals")
        app.swipeUp(); app.swipeUp()
        shot("ui27-achievements")
        tap(button("أنقص"), "daily goal −", timeout: 2)
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        tap(button("الإحصائيات"), "stats")
        sleep(1)
        shot("ui28-stats")
        tap(button("30 يومًا"), "30 days")
        shot("ui29-stats-30")
        app.swipeUp()
        shot("ui30-stats-lower")
        app.swipeUp(); app.swipeUp()
        shot("ui31-stats-bottom")
    }

    /// Settings: dark, light, an accent, a bigger text size, and back.
    func test07Settings() {
        tab("الإعدادات")
        tap(button("فاتح"), "light")
        sleep(1)
        shot("ui32-settings-light")
        tap(button("نيلي"), "indigo")
        tap(button("كبير"), "large text")
        sleep(1)
        shot("ui33-settings-indigo-large")
        tab("المكتبة")
        shot("ui34-library-light-indigo")
        tab("الإعدادات")
        tap(button("زمردي"), "teal")
        tap(button("متوسط"), "medium text")
        tap(button("حسب الجهاز"), "system")
        app.swipeUp(); app.swipeUp()
        shot("ui35-settings-lower")
        app.swipeUp(); app.swipeUp()
        shot("ui36-settings-data")
    }
}
