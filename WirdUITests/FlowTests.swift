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
        // the app writes down its own late frames next to the marks (StallWatch)
        if let d = Self.dir { app.launchEnvironment["JALEES_STALLS"] = d.appendingPathComponent("stalls.txt").path }
        app.launch()
        _ = app.buttons["المكتبة"].waitForExistence(timeout: 15)
        sleep(3) // the splash
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

    /// A moment the build machine's recording is cut at (tools/sim/frames.swift): the name and the time now.
    private func mark(_ name: String) {
        guard let d = Self.dir else { return }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("marks.txt")
        let line = "\(name) \(Date().timeIntervalSince1970)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    /// The page's own back button (the tab bar has a button with the same name, lower down).
    private func pageBack() {
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "المكتبة")).allElementsBoundByIndex.filter { $0.isHittable }
        if let top = all.min(by: { $0.frame.minY < $1.frame.minY }), top.frame.minY < 300 { top.tap() } else { XCTFail("no back button") }
    }

    private func tab(_ name: String) { tap(button(name), "tab " + name); sleep(1) }

    /// A chip in a row that scrolls sideways (the notebook's lists): the row is dragged until the chip is on screen.
    private func chip(_ label: String) -> XCUIElement {
        let e = buttonStarting(label)
        guard e.waitForExistence(timeout: 4) else { return e }
        var n = 0
        while !e.isHittable && n < 6 {
            let y = max(0.05, min(0.95, e.frame.midY / app.frame.height))
            // off the left edge: drag the row to the right; off the right edge: to the left
            let left = e.frame.midX < app.frame.midX
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.3 : 0.7, dy: y))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.8 : 0.2, dy: y)))
            sleep(1)
            n += 1
        }
        return e
    }

    /// Scrolls until the element sits clear of the tab bar (a tap under it would land on a tab).
    private func reveal(_ e: XCUIElement) {
        var n = 0
        while n < 10 && (!e.exists || e.frame.maxY > app.frame.maxY - 170) { app.swipeUp(velocity: .slow); n += 1 }
    }

    // MARK: flows

    /// Every tab of both groups opens, and coming back to the library keeps it as it was.
    func test01Tabs() {
        shot("ui01-library")
        for (t, n) in [("دفتري", "ui02-notebook"), ("إنجازاتي", "ui03-progress"), ("الإعدادات", "ui04-settings")] { tab(t); shot(n) }
        tab("تصفّح"); shot("ui05-browse")
        for (t, n) in [("التحديثات", "ui06-updates"), ("التحميلات", "ui07-downloads"), ("السجل", "ui08-history")] { tab(t); shot(n) }
        // the main group is now a round button showing the tab it was left at
        tab("الإعدادات"); tab("المكتبة"); shot("ui09-library-again")
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
            // the page count is required for a book read by pages; ✓ right after typing must keep it
            let pages = app.textFields["صفحات"].firstMatch
            if tap(pages, "pages field") { pages.typeText("240") }
            shot("ui11-form-typed")
            tap(app.buttons["form.save"].firstMatch, "save")
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
            tap(button("إغلاق"), "close quick progress")
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
        // the session card swipes down to its chip (as Apple Music's player), and the chip brings it back
        mark("session-swipe-down")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        sleep(2)
        shot("ui18b-session-minimised")
        if tap(button("العودة للجلسة"), "back to the session") { sleep(2) }
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
        // adding is the floating + (its menu), the one way in the notebook
        if tap(button("إضافة للدفتر"), "notebook +") { sleep(1) }
        tap(button("اقتباس"), "new quote")
        sleep(1)
        // from the notebook the form asks which book (it no longer guesses the last one read)
        // SwiftUI's Menu is not always a «button» to the test: found by its words among everything on screen
        let pick = app.descendants(matching: .any)["pickBook"].firstMatch
        if tap(pick, "choose the book") {
            sleep(1)
            tap(button("لكنود"), "the book لكنود")
            sleep(1)
        }
        let text = app.textViews.firstMatch
        if tap(text, "quote text") {
            text.typeText("نص اقتباس من اختبار الواجهة")
            shot("ui21-quote-form")
            tap(button("حفظ"), "save quote")
            sleep(2)
            shot("ui22-notebook-after")
            // the saved quote, first in the quotes of every book (a card: a button or its text): its form, then its card
            tap(chip("اقتباسات"), "quotes list")
            sleep(1)
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "نص اقتباس من اختبار")).firstMatch
            if tap(row, "the saved quote") {
                sleep(1)
                reveal(buttonStarting("بطاقة الاقتباس"))
                if tap(buttonStarting("بطاقة الاقتباس"), "quote card") {
                    sleep(2)
                    shot("ui22b-quote-card")
                    // its close button (on an iPad the card is a sheet in the middle: a swipe there moves the picture)
                    if button("إغلاق").exists { button("إغلاق").tap() } else { app.swipeDown(velocity: .fast) }
                    sleep(1)
                }
            }
        }
        tap(chip("أفكار"), "thoughts list")
        shot("ui23-thoughts")
        tap(chip("شخصيات"), "characters")
        shot("ui24-characters")
        tap(chip("تظليلات"), "highlights")
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
        // a long press on + adds to the list you are on (quotes here)
        let plus = button("إضافة للدفتر")
        if plus.waitForExistence(timeout: 4) {
            plus.press(forDuration: 0.9)
            sleep(1)
            shot("ui25c2-fab-hold")
            XCTAssertTrue(app.staticTexts["إضافة اقتباس"].waitForExistence(timeout: 3) || app.navigationBars["إضافة اقتباس"].exists, "hold opens a new quote")
            tap(button("إغلاق"), "close the held form")
        }
    }

    /// A book page's card and PDF summary.
    func test05cCardAndPDF() {
        let car = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "مكتبتك")).firstMatch
        if car.waitForExistence(timeout: 4) { car.swipeUp() } else { app.swipeUp() }
        sleep(2)
        reveal(buttonStarting("بطاقة الكتاب"))
        if tap(buttonStarting("بطاقة الكتاب"), "book card") {
            sleep(2)
            shot("ui25d-book-card")
            app.swipeDown(velocity: .fast)
            sleep(1)
        }
        reveal(buttonStarting("ملخص PDF"))
        if tap(buttonStarting("ملخص PDF"), "pdf summary") {
            sleep(3)
            shot("ui25e-pdf")
            app.swipeUp()
            sleep(1)
            shot("ui25f-pdf-preview")
        }
    }

    /// A novel in the reader: the menu, reading aloud from it, the next paragraph, stopping, closing.
    /// The novel page's main button opens the reader.
    func test08aPageOpensReader() {
        app.terminate()
        app.launchArguments += ["-JaleesRoute", "page"]
        app.launch()
        sleep(5)
        // the visible one: the library tab underneath has the same book's button
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "ابدأ القراءة", "تابع القراءة"))
        _ = all.firstMatch.waitForExistence(timeout: 10)
        guard let go = all.allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("no visible read button"); shot("ui40-no-reader"); return }
        go.tap()
        sleep(4)
        shot("ui40-reader-open")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 6), "the reader's page is not there")
        // with its buttons showing, the page pulled down closes the reader (as Apple Books), back on the novel's page
        if !button("القائمة").waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            sleep(1)
        }
        mark("reader-pull-close")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        sleep(2)
        shot("ui40b-reader-pulled-closed")
        XCTAssertFalse(button("القائمة").exists, "the reader did not close when pulled down")
    }

    func test08ReaderAloud() {
        app.terminate()
        app.launchArguments += ["-JaleesRoute", "reader", "-JaleesSilent"]
        app.launch()
        sleep(6)
        // the reader's buttons show with a tap on the text (they may be showing already)
        if !button("القائمة").waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            sleep(1)
        }
        if tap(button("القائمة"), "reader menu") {
            sleep(1)
            shot("ui41-reader-menu")
            tap(buttonStarting("القراءة الصوتية"), "read aloud")
            sleep(4)
            shot("ui42-read-aloud")
            tap(button("الفقرة التالية"), "next paragraph")
            sleep(3)
            shot("ui43-read-aloud-next")
            tap(button("خيارات القراءة الصوتية"), "read aloud options")
            sleep(1)
            shot("ui44-read-aloud-options")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            sleep(1)
            tap(button("إيقاف القراءة الصوتية"), "stop reading aloud")
            sleep(1)
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        tap(button("إغلاق"), "close the reader")
        sleep(2)
        shot("ui45-after-reader")
    }

    /// The animations: opening and closing books from the carousel, the tabs, the notebook's + held down. The build
    /// machine records the screen and cuts each marked moment into a sheet of frames.
    func test09Transitions() {
        tab("المكتبة")
        sleep(2)
        mark("open-book")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)).tap()
        sleep(2)
        shot("ui50-book-open")
        mark("close-book")
        pageBack()
        sleep(2)
        shot("ui51-back")
        mark("carousel-swipe")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.40)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40)))
        sleep(2)
        // a finger put down and moved slowly, held, as the owner does: the first move must glide, not jump a book
        mark("carousel-slow")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.40)).press(forDuration: 0.15, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.40)),
                                                                              withVelocity: XCUIGestureVelocity(rawValue: 260), thenHoldForDuration: 0.4)
        sleep(2)
        mark("open-second")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)).tap()
        sleep(2)
        shot("ui52-second-open")
        mark("close-second")
        pageBack()
        sleep(2)
        shot("ui53-second-back")
        mark("tab-notebook")
        tab("دفتري")
        mark("tab-progress")
        tab("إنجازاتي")
        mark("tab-library")
        tab("المكتبة")
        sleep(1)
        // Bookly's way: swipe the cover up to open the book in place, pull its page down to close it
        mark("swipe-up-open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        sleep(2)
        shot("ui55-swipe-opened")
        mark("pull-down-close")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        sleep(2)
        shot("ui56-pulled-closed")
        // a short swipe up is not enough: back to the library
        mark("swipe-up-cancel")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 0.3, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)), withVelocity: .slow, thenHoldForDuration: 0.2)
        sleep(2)
        shot("ui57-short-swipe")
        tab("دفتري")
        sleep(1)
        mark("fab-hold")
        let plus = app.buttons["إضافة للدفتر"].firstMatch
        if plus.waitForExistence(timeout: 4) { plus.press(forDuration: 0.6) } else { XCTFail("no + in the notebook") }
        sleep(2)
        shot("ui54-fab-hold-form")
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
        shot("ui31b-settings-root")
        // settings are pages now: the look's controls are one row down
        tap(buttonStarting("المظهر"), "look page")
        sleep(1)
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
        // the tab keeps its page; if it came back at its root, the look page again
        if !button("زمردي").waitForExistence(timeout: 2) { tap(buttonStarting("المظهر"), "look page again"); sleep(1) }
        tap(button("زمردي"), "teal")
        tap(button("متوسط"), "medium text")
        tap(button("حسب الجهاز"), "system")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        tap(buttonStarting("الجلسة والتذكير"), "session page")
        sleep(1)
        shot("ui35-settings-lower")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        tap(buttonStarting("البيانات"), "data page")
        sleep(1)
        shot("ui36-settings-data")
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: the owner's notes after 2.1.3, one walk each (2.2)

    /// The reader opened on the sample novel, its buttons hidden.
    private func openReader() -> XCUIElement {
        app.terminate()
        app.launchArguments += ["-JaleesRoute", "reader", "-JaleesSilent"]
        app.launch()
        sleep(6)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10), "the reader's page is not there")
        return web
    }

    /// The chapter the reader says it is in: its bottom pill «4 من 40», shown with its buttons.
    private func readerChapter() -> Int? {
        let pill = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ من [0-9]+$")).firstMatch
        // the buttons show with a tap; a tap that only ends a selection needs one more (the menu button tells)
        // tapped low on the page: a selection (and its menu) sits where the walks hold the text, mid-screen
        for _ in 0..<4 where !button("القائمة").exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74)).tap()
            sleep(2)
        }
        guard pill.waitForExistence(timeout: 3) else { return nil }
        let n = Int(pill.label.split(separator: " ").first ?? "")
        // the buttons go again, so the next swipe reaches the page
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74)).tap()
        sleep(1)
        return n
    }

    /// One swipe is one chapter each way (it took two forward, and back skipped one), and the reader knows where it is.
    func test10ReaderChapters() {
        let web = openReader()
        guard let start = readerChapter() else { XCTFail("no chapter pill"); shot("ui60-no-pill"); return }
        mark("chapter-forward")
        web.swipeRight()
        sleep(3)
        shot("ui60-chapter-forward")
        XCTAssertEqual(readerChapter(), start + 1, "one swipe forward is one chapter")
        web.swipeRight()
        sleep(3)
        XCTAssertEqual(readerChapter(), start + 2, "a second swipe forward is one more")
        mark("chapter-back")
        web.swipeLeft()
        sleep(3)
        shot("ui61-chapter-back")
        XCTAssertEqual(readerChapter(), start + 1, "one swipe back is one chapter, not two")
        web.swipeLeft()
        sleep(3)
        XCTAssertEqual(readerChapter(), start, "back where it started")
    }

    /// Text held and dragged sideways is a selection: the chapter stays.
    func test11SelectionKeepsChapter() {
        let web = openReader()
        guard let start = readerChapter() else { XCTFail("no chapter pill"); return }
        let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.42))
        from.press(forDuration: 1.3, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.44)))
        sleep(2)
        shot("ui62-selection-drag")
        XCTAssertEqual(readerChapter(), start, "a selection dragged sideways changed the chapter")
    }

    /// A rule written without hamza («اخر») catches «آخر» and «آخرها», and shows in the open chapter at once,
    /// reached through the reader's settings (pages with back and «تم»).
    func test12ReplaceRuleLive() {
        let web = openReader()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "آخر")).firstMatch.waitForExistence(timeout: 4), "the sample has «آخر»")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        guard tap(button("القائمة"), "reader menu") else { return }
        sleep(1)
        tap(buttonStarting("السمات والإعدادات"), "themes and settings")
        sleep(1)
        tap(buttonStarting("إعدادات القراءة"), "reading settings")
        sleep(1)
        shot("ui63-reading-settings")
        let rules = buttonStarting("قواعد الاستبدال لهذه الرواية")
        var n = 0
        while n < 6 && !(rules.exists && rules.isHittable) { app.swipeUp(velocity: .slow); n += 1 }
        guard tap(rules, "this novel's rules") else { return }
        sleep(1)
        tap(buttonStarting("قاعدة جديدة"), "new rule")
        sleep(1)
        let word = app.textFields["الكلمة"].firstMatch
        if tap(word, "the word") { word.typeText("اخر") }
        let to = app.textFields["تصير"].firstMatch
        if tap(to, "what it becomes") { to.typeText("زمرد") }
        shot("ui64-rule-typed")
        tap(button("تم"), "done")
        sleep(3)
        shot("ui65-rule-on-page")
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "زمرد")).firstMatch.waitForExistence(timeout: 6),
                      "the rule did not show in the open chapter")
        XCTAssertFalse(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "آخر")).firstMatch.exists, "«آخر» is still there")
        // the rule goes again (the next walks read the sample as it was), this time from the menu's own row (reader
        // 2.4: the replacement rules are one tap from the menu, with how many this novel has)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        if tap(button("القائمة"), "reader menu again") {
            sleep(1)
            if tap(buttonStarting("قواعد الاستبدال"), "the rules' row") {
                sleep(1)
                tap(buttonStarting("حذف القاعدة"), "delete the rule")
                sleep(1)
                tap(button("تم"), "done")
            }
        }
    }

    /// A character's first appearance: each digit shows as it is typed (it showed nothing, then all of them).
    func test13NumberFieldShowsDigits() {
        tab("دفتري")
        guard tap(button("إضافة للدفتر"), "notebook +") else { return }
        sleep(1)
        tap(buttonStarting("شخصية"), "a character")
        sleep(1)
        let pick = app.descendants(matching: .any)["pickBook"].firstMatch
        if tap(pick, "choose the book") { sleep(1); tap(button("لكنود"), "the book لكنود"); sleep(1) }
        let first = app.textFields["num-first"].firstMatch
        var n = 0
        while n < 6 && !(first.exists && first.isHittable) { app.swipeUp(velocity: .slow); n += 1 }
        guard tap(first, "first appearance") else { shot("ui66-no-number-field"); return }
        first.typeText("12")
        shot("ui66-number-typed")
        XCTAssertEqual(first.value as? String, "12", "the typed digits do not show")
        first.typeText("٣")
        XCTAssertEqual(first.value as? String, "123", "an Arabic digit counts")
        tap(button("إغلاق"), "close the form")
        sleep(1)
        // leaving with something typed asks first
        if app.buttons["تجاهل"].waitForExistence(timeout: 2) { app.buttons["تجاهل"].tap() }
        else if app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "بدون حفظ")).firstMatch.exists {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "بدون حفظ")).firstMatch.tap()
        }
    }

    /// تصفّح: the sites as cards, and WTR-LAB's own search finds «Deep Sea Embers» (the owner's novel).
    func test14BrowseSites() {
        tab("تصفّح")
        sleep(3)
        shot("ui67-browse")
        let kol = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ملوك الروايات")).firstMatch
        XCTAssertTrue(kol.waitForExistence(timeout: 10), "the sites are not listed")
        let wtr = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "WTR-LAB")).firstMatch
        reveal(wtr)
        shot("ui68-browse-lower")
        guard tap(wtr, "WTR-LAB") else { return }
        sleep(4)
        shot("ui69-wtrlab")
        // a short page (ten novels) once froze the list: it must answer, and ask for no more than fills the screen
        let list = app.otherElements["browse-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "WTR-LAB's list does not answer")
        let n0 = Int((list.value as? String) ?? "") ?? 0
        sleep(10)
        let n1 = Int((list.value as? String) ?? "") ?? 0
        XCTAssertLessThanOrEqual(n1, max(n0, 10) + 30, "WTR-LAB's list kept loading by itself: \(n0) → \(n1)")
        let field = app.textFields["ابحث في WTR-LAB"].firstMatch
        // the field reads as not hittable inside its row: tapped where it is
        if field.waitForExistence(timeout: 6) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(1)
            // two words only: the site's finder (most read first) and the ranking bring the novel to the top
            field.typeText("deep sea\n")
            sleep(8)
            shot("ui70-wtrlab-search")
            // the site may refuse the build machine: then this is noted, not a failure of the app
            XCTExpectFailure("the site may block the build machine's address", strict: false) {
                let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Deep Sea Embers")).firstMatch
                XCTAssertTrue(hit.waitForExistence(timeout: 15), "Deep Sea Embers is not among the results")
                let first = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "deep")).firstMatch
                XCTAssertTrue(first.label.localizedCaseInsensitiveContains("Deep Sea Embers"), "the closest name is not first: \(first.label)")
            }
        }
        XCTAssertEqual(app.alerts.count, 0, "an alert came up while browsing")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
    }

    /// A site's list loads one page and waits: nothing more comes until the end of the list is reached, and a page
    /// that fails never turns into alerts (it once loaded every page by itself, then an alert every second).
    func test14bSourceStaysPut() {
        tab("تصفّح")
        sleep(2)
        let kol = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ملوك الروايات")).firstMatch
        guard tap(kol, "ملوك الروايات") else { return }
        let list = app.otherElements["browse-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the site's list is missing")
        sleep(8)
        let first = Int((list.value as? String) ?? "") ?? 0
        sleep(15)
        let later = Int((list.value as? String) ?? "") ?? 0
        shot("ui73-kol-still")
        XCTAssertLessThanOrEqual(later, first + 25, "the list kept loading by itself: \(first) → \(later)")
        XCTAssertEqual(app.alerts.count, 0, "an alert came up on the site's list")
        // the end of the list brings the next page
        if first > 0 {
            for _ in 0..<8 { app.swipeUp(velocity: .fast) }
            sleep(8)
            let more = Int((list.value as? String) ?? "") ?? 0
            shot("ui74-kol-more")
            XCTExpectFailure("the site may block the build machine's address", strict: false) {
                XCTAssertGreaterThan(more, first, "the end of the list brought nothing")
            }
        }
        // another tab: no alert follows there either
        tab("التحديثات")
        sleep(5)
        XCTAssertEqual(app.alerts.count, 0, "an alert from the site's list came up in another tab")
        tab("تصفّح")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
    }

    /// One search over everything: a book by its title, opened from the result.
    func test15GlobalSearch() {
        tab("المكتبة")
        guard tap(button("بحث"), "search") else { return }
        sleep(1)
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 3) { field.tap(); field.typeText("لكنود") }
        sleep(2)
        shot("ui71-global-search")
        let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "لكنود")).firstMatch
        if tap(hit, "a result") {
            sleep(3)
            shot("ui72-search-opened")
            pageBack()
        }
    }

    /// The header's choices as menus: the view style changes from its menu and comes back.
    func test16HeaderMenus() {
        tab("المكتبة")
        guard tap(button("طريقة العرض"), "view menu") else { return }
        sleep(1)
        shot("ui73-view-menu")
        tap(button("شبكة"), "grid")
        sleep(2)
        shot("ui74-grid")
        tap(button("طريقة العرض"), "view menu again")
        sleep(1)
        tap(button("دائري"), "carousel")
        sleep(2)
        shot("ui75-carousel-again")
        if tap(button("خيارات المكتبة"), "library options") { sleep(1); shot("ui76-options-menu"); app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
    }

    /// The word review: its start (ways to review), a card, and back out.
    func test17WordReview() {
        tab("دفتري")
        tap(chip("كلمات"), "words")
        sleep(1)
        // the words' review panel (دفتري 2.4): «مراجعة المستحقة», or «مراجعة» when none is due
        guard tap(buttonStarting("مراجعة"), "review") else { return }
        sleep(1)
        shot("ui77-review-start")
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", "ابدأ", "راجع الكل", "ابدأ المستحقة")).firstMatch
        if tap(start, "start") {
            sleep(1)
            shot("ui78-review-card")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            sleep(1)
            shot("ui79-review-flipped")
        }
        app.swipeDown(velocity: .fast)
        sleep(1)
    }

    /// A note's place in the novel from its form: the reader opens and stays (it closed with the form).
    func test18OpenPlaceFromNote() {
        // a word saved from the reader carries its place
        let web = openReader()
        let at = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        at.press(forDuration: 1.3)
        sleep(2)
        let toNotebook = app.menuItems["للدفتر"].firstMatch
        if !toNotebook.waitForExistence(timeout: 4) {
            web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
            sleep(2)
            at.press(forDuration: 1.5)
            sleep(2)
        }
        shot("ui80-word-selected")
        if toNotebook.waitForExistence(timeout: 5) {
            toNotebook.tap()
            sleep(1)
            let word = app.buttons["كلمة"].firstMatch.exists ? app.buttons["كلمة"].firstMatch : app.menuItems["كلمة"].firstMatch
            if tap(word, "as a word") {
                sleep(2)
                shot("ui81-word-form-from-reader")
                tap(button("حفظ"), "save the word")
                sleep(2)
            }
        } else {
            // the system's menu may show the app's items behind «›»
            XCTExpectFailure("the selection menu's items were not found", strict: false) { XCTFail("no «للدفتر» in the selection menu") }
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        tap(button("إغلاق"), "close the reader")
        sleep(2)
        tab("دفتري")
        tap(chip("كلمات"), "words")
        sleep(1)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "حارس المكتبة")).firstMatch
        guard tap(row, "the word from the sample novel") else { return }
        sleep(1)
        let place = buttonStarting("افتح مكانه في القارئ")
        reveal(place)
        guard tap(place, "its place in the reader") else { return }
        sleep(4)
        shot("ui82-place-in-reader")
        XCTAssertTrue(app.webViews.firstMatch.exists, "the reader closed with the form")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        tap(button("إغلاق"), "close the reader")
    }

    /// Reader 2.3: the one menu, the book's notebook in the reader, and a highlight with a note made from a selection
    /// that shows in the reader's list and in دفتري ← تظليلات ← ملاحظات (one thing in both places).
    func test19ReaderNotebook() {
        let web = openReader()
        func showButtons() {
            for _ in 0..<4 where !button("القائمة").exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74)).tap()
                sleep(2)
            }
        }
        showButtons()
        guard tap(button("القائمة"), "reader menu") else { return }
        sleep(1)
        shot("ui83-reader-menu")
        XCTAssertTrue(buttonStarting("المحتويات").exists, "the contents row")
        XCTAssertTrue(button("المزيد").exists, "the «more» button")
        XCTAssertFalse(buttonStarting("الوقفات والتمييزات").exists, "the old list's row is gone")
        // reader 2.4's default: the rules and the chapter bar one tap away, the line guide in «المزيد»
        XCTAssertTrue(buttonStarting("قواعد الاستبدال").exists, "the rules' row")
        XCTAssertTrue(buttonStarting("اذهب لفصل").exists, "the chapter bar (its number goes to any chapter)")
        XCTAssertFalse(button("دليل السطر").exists, "the line guide is in «المزيد» by default")
        guard tap(buttonStarting("دفتر الرواية"), "the book's notebook") else { return }
        sleep(1)
        shot("ui84-reader-notebook")
        tap(button("تم"), "close the list")
        sleep(1)

        // a highlight with a note, from a selection
        let note = "ملاحظة من الاختبار"
        let at = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        at.press(forDuration: 1.3)
        sleep(2)
        let noteItem = app.menuItems["ملاحظة"].firstMatch
        if !noteItem.waitForExistence(timeout: 4) {
            web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
            sleep(2)
            at.press(forDuration: 1.5)
            sleep(2)
        }
        guard noteItem.waitForExistence(timeout: 5) else {
            XCTExpectFailure("the selection menu's items were not found", strict: false) { XCTFail("no «ملاحظة» in the selection menu") }
            return
        }
        noteItem.tap()
        sleep(2)
        app.typeText(note)
        shot("ui85-note-typed")
        tap(button("حفظ"), "save the note")
        sleep(2)

        // in the reader's list, under «ملاحظات»
        showButtons()
        guard tap(button("القائمة"), "reader menu again") else { return }
        sleep(1)
        guard tap(buttonStarting("دفتر الرواية"), "the book's notebook again") else { return }
        sleep(1)
        tap(button("ملاحظات"), "the notes filter")
        sleep(1)
        shot("ui86-reader-notebook-notes")
        let inList = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
        XCTAssertTrue(inList.waitForExistence(timeout: 4), "the note is not in the reader's list")
        tap(button("تم"), "close the list")
        sleep(1)
        showButtons()
        tap(button("إغلاق"), "close the reader")
        sleep(2)

        // and in the notebook, the same highlight with its note
        tab("دفتري")
        tap(chip("تظليلات"), "highlights")
        sleep(1)
        tap(chip("ملاحظات"), "notes")
        sleep(1)
        shot("ui87-notebook-notes")
        let inNotebook = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
        XCTAssertTrue(inNotebook.waitForExistence(timeout: 4), "the note is not in دفتري")
    }

    /// A phone or iPad in English with Jalees in Arabic (the owner's iPad showed some sheets and menus mirrored):
    /// the reader's sheets, the line guide's menu, and the two pages sideways, kept as pictures to look at.
    func test20EnglishDevice() {
        app.terminate()
        func open(_ route: String) -> XCUIApplication {
            let a = XCUIApplication()
            a.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-JaleesRoute", route]
            a.launch()
            sleep(9)
            return a
        }
        var a = open("reader-reading")
        shot("ui90-enphone-reading")
        a.terminate()
        // as on the owner's iPad: the device in English and no language given to the app (it runs in its own Arabic)
        let plain = XCUIApplication()
        plain.launchArguments = ["-JaleesRoute", "reader-reading"]
        plain.launch()
        sleep(9)
        shot("ui90b-plain-reading")
        plain.terminate()
        let plainGuide = XCUIApplication()
        plainGuide.launchArguments = ["-JaleesRoute", "reader-guide"]
        plainGuide.launch()
        sleep(9)
        let pg = plainGuide.buttons["دليل السطر"].firstMatch
        if pg.waitForExistence(timeout: 4) { pg.tap(); sleep(1); shot("ui90c-plain-guide-menu") }
        plainGuide.terminate()
        a = open("reader-themes")
        shot("ui91-enphone-themes")
        // the page-turn style menu in the sheet (a system menu)
        let style = a.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "تمرير", "قلب")).firstMatch
        if style.waitForExistence(timeout: 3) { style.tap(); sleep(1); shot("ui92-enphone-style-menu") }
        a.terminate()
        a = open("reader-guide")
        let guide = a.buttons["دليل السطر"].firstMatch
        if guide.waitForExistence(timeout: 4) { guide.tap(); sleep(1); shot("ui93-enphone-guide-menu") }
        a.terminate()
        // two pages: sideways, an English book and an Arabic one with the guide on
        XCUIDevice.shared.orientation = .landscapeLeft
        a = open("readeren-guide")
        shot("ui94-land-readeren-guide")
        a.terminate()
        a = open("reader-guide")
        shot("ui95-land-reader-guide")
        a.terminate()
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.launch()
    }

    /// Reader 2.4: the menu is his. «المزيد» → «خصّص القائمة»: the line guide moved from «المزيد» to the rows is a row
    /// of the menu when it opens again; «رجّع الافتراضي» puts it back.
    func test21ReaderMenuEditor() {
        _ = openReader()
        func showButtons() {
            for _ in 0..<4 where !button("القائمة").exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74)).tap()
                sleep(2)
            }
        }
        /// an item of a button's menu, or a dialog's (shown as buttons or menu items, depending on the system)
        func named(_ label: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        /// the menu, open (closing the editor opens it again by itself)
        func menuOpen() -> Bool {
            if buttonStarting("المحتويات").waitForExistence(timeout: 3) { return true }
            showButtons()
            guard tap(button("القائمة"), "reader menu") else { return false }
            sleep(1)
            return true
        }
        func openEditor() -> Bool {
            guard tap(button("المزيد"), "«more»") else { return false }
            sleep(1)
            guard tap(named("خصّص القائمة"), "customize the menu") else { return false }
            sleep(2)
            return true
        }
        /// an editor row's move button, scrolled into view
        func moveButton(_ title: String) -> XCUIElement {
            let b = button("انقل «" + title + "»")
            var n = 0
            while n < 8 && !(b.exists && b.isHittable) { app.swipeUp(velocity: .slow); sleep(1); n += 1 }
            return b
        }

        showButtons()
        guard tap(button("القائمة"), "reader menu") else { return }
        sleep(1)
        shot("ui96-reader-menu")
        XCTAssertFalse(button("دليل السطر").exists, "the line guide starts in «المزيد»")
        guard openEditor() else { return }
        shot("ui97-menu-editor")
        guard tap(moveButton("دليل السطر"), "move the line guide") else { return }
        sleep(1)
        guard tap(named("إلى الصفوف"), "to the rows") else { return }
        sleep(1)
        shot("ui98-menu-editor-moved")
        tap(button("تم"), "close the editor")
        sleep(2)
        guard menuOpen() else { return }
        shot("ui99-menu-with-guide")
        let guide = button("دليل السطر")
        XCTAssertTrue(guide.waitForExistence(timeout: 3), "the line guide is not in the menu after moving it to the rows")
        if guide.exists { XCTAssertGreaterThan(guide.frame.width, 200, "the line guide is a row, not a round button") }

        // back to the default
        guard openEditor() else { return }
        let reset = button("رجّع الافتراضي")
        var n = 0
        while n < 10 && !(reset.exists && reset.isHittable) { app.swipeUp(velocity: .slow); n += 1 }
        guard tap(reset, "restore the default") else { return }
        sleep(1)
        // the dialog's own «رجّع الافتراضي» (the list's is under it)
        let sure = app.sheets.buttons["رجّع الافتراضي"].firstMatch
        if sure.waitForExistence(timeout: 2) { sure.tap() } else {
            let all = app.buttons.matching(NSPredicate(format: "label == %@", "رجّع الافتراضي")).allElementsBoundByIndex.filter { $0.isHittable }
            if let last = all.last { last.tap() } else { XCTFail("no confirmation for the default") }
        }
        sleep(1)
        tap(button("تم"), "close the editor")
        sleep(2)
        if menuOpen() {
            XCTAssertFalse(button("دليل السطر").exists, "the default puts the line guide back in «المزيد»")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).tap()
            sleep(1)
        }
        showButtons()
        tap(button("إغلاق"), "close the reader")
    }

    /// دفتري 2.4: the home (today's passages, the words' review, the shelf of books' notebooks, the newest kept), a book's
    /// notebook page (its passages by chapter, its characters' gallery and map, its timeline), a character's card from
    /// the map, and picking several quotes.
    func test22NotebookHome() {
        tab("دفتري")
        sleep(1)
        shot("ui100-notebook-home")
        XCTAssertTrue(buttonStarting("الرئيسية").exists, "the home's chip")
        // the shelf: its row is dragged sideways until «لورد الغوامض» (its characters are related) is on screen
        let anyCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nb-book-")).firstMatch
        guard anyCard.waitForExistence(timeout: 5) else { XCTFail("no shelf of notebooks on the home"); return }
        reveal(anyCard)
        shot("ui101-notebook-shelf")
        let lotm = app.buttons.matching(NSPredicate(format: "identifier == %@", "nb-book-cc9bfeteov4")).firstMatch
        var n = 0
        while !(lotm.exists && lotm.isHittable) && n < 8 && anyCard.exists {
            let y = max(0.05, min(0.95, anyCard.frame.midY / app.frame.height))
            let toRight = n < 4
            app.coordinate(withNormalizedOffset: CGVector(dx: toRight ? 0.2 : 0.8, dy: y))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: toRight ? 0.8 : 0.2, dy: y)))
            sleep(1)
            n += 1
        }
        guard tap(lotm, "a book's notebook from the shelf") else { return }
        sleep(2)
        shot("ui102-notebook-book")
        XCTAssertTrue(button("رجوع").exists, "the page's way back to دفتري")
        if tap(chip("الشخصيات"), "the characters") {
            sleep(1)
            shot("ui103-notebook-chars")
            // the map's faces are buttons named by the character alone (the gallery's say more)
            let face = button("كلاين موريتي")
            XCTAssertTrue(face.waitForExistence(timeout: 3), "the relations' map")
            reveal(face)
            shot("ui104-notebook-map")
            if tap(face, "a face on the map") {
                sleep(2)
                shot("ui105-notebook-char-card")
                if button("إغلاق").exists { button("إغلاق").tap() } else { app.swipeDown(velocity: .fast) }
                sleep(1)
            }
        }
        app.swipeDown(velocity: .fast)
        sleep(1)
        if tap(chip("الخط الزمني"), "the timeline") {
            sleep(1)
            shot("ui106-notebook-timeline")
        }
        tap(button("رجوع"), "back to دفتري")
        sleep(1)
        // several quotes picked at once: copy, share, delete
        tap(chip("اقتباسات"), "quotes")
        sleep(1)
        if tap(button("تحديد"), "pick several") {
            sleep(1)
            let q = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "نص اقتباس من اختبار")).firstMatch
            if q.waitForExistence(timeout: 3) { q.tap(); sleep(1) }
            shot("ui107-notebook-picking")
            tap(button("إلغاء"), "stop picking")
        }
    }

    /// Last (it leaves the app in English): the English interface reads left to right and its tabs say so.
    func test99English() {
        app.terminate()
        app.launchArguments += ["-JaleesLang", "en"]
        app.launch()
        sleep(5)
        shot("ui90-en-library")
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 6), "the English tab bar")
        for (t, n) in [("My notebook", "ui91-en-notebook"), ("My achievements", "ui92-en-progress"), ("Settings", "ui93-en-settings")] {
            if app.buttons[t].exists { app.buttons[t].tap(); sleep(2); shot(n) }
        }
    }
}
