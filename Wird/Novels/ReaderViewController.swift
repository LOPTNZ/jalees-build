import UIKit
import WebKit
import SwiftUI
import Combine

/// The page's text view. It adds Jalees's own items to the system selection menu (تظليل، ملاحظة، للدفتر), before the
/// system's own (نسخ، ترجمة، بحث…).
final class ReaderWebView: WKWebView {
    weak var owner: ReaderViewController?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let o = owner else { return }
        builder.insertChild(o.selectionMenu(), atStartOfMenu: .root)
    }
}

/// The reading screen. The chapter text is laid out by WebKit (www/reader), like Apple Books does; every control
/// around it is native. Nothing shows while reading: one tap brings the controls, the next hides them.
final class ReaderViewController: UIViewController, WKScriptMessageHandler, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private(set) var novel: Novel
    private(set) var chapters: [ChapterRow]
    private(set) var index: Int
    private var startPlace: [String: Any]?
    let settings = ReaderSettings.shared

    private(set) var web: ReaderWebView!
    private var pageReady = false
    private var token = 0
    private var bag = Set<AnyCancellable>()
    private var lastPos: [String: Any] = [:]

    private let closeButton = GlassButton(symbol: "xmark")
    private let menuButton = GlassButton(symbol: "line.3.horizontal")
    private let topPill = GlassLabel()
    private let bottomPill = GlassLabel()
    private let topFade = FadeView()
    private let ribbon = UIImageView(image: UIImage(systemName: "bookmark.fill"))
    private(set) var chromeShown = false
    private var pagesLeft = 0
    private var pinchBase: Double = 22
    private var menu: ReaderMenuView?
    /// pulling the page down (with the controls showing) closes the book, as in Apple Books
    private lazy var pullPan: UIPanGestureRecognizer = {
        let p = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))
        p.delegate = self
        return p
    }()
    /// the page as a picture while it is pulled (the web view itself stays put underneath, hidden)
    private var pullShot: UIView?
    private var pullHidden: [UIView] = []
    private var markBar: MarkBar?
    private var guideButton: GlassButton?
    private var autoPill: AutoScrollPill?
    private(set) var guideOn = false
    private var orientationLocked = DB.shared.get("reader.lock") == "1"
    private var marksHere: [[String: Any]] = []
    private(set) var bookmarks: [[String: Any]] = []
    private var lastColor = DB.shared.get("reader.lastColor") ?? "yellow"
    private var loadedInPage: Set<Int> = []
    private var commentPages: [Int: Int] = [:]
    /// The owner's names for the highlight colours, and the book's characters (for a quote's speaker), from the library.
    private(set) var labelNames: [String: String] = [:]
    private(set) var characters: [[String: Any]] = []

    // the reading session: active time only (a locked phone or 3 idle minutes stop the clock)
    private let sessionStart = Date()
    private var activeSeconds: Double = 0
    private var lastTick = Date()
    private var lastActivity = Date()
    private var running = true
    private var readAtStart = 0
    private var clock: Timer?

    var onClose: (() -> Void)?
    /// the library book this novel is (its highlights, notebook entries and sessions go there)
    var bookID: String?

    init(novel: Novel, chapters: [ChapterRow], index: Int, place: (p: Int, o: Double)?) {
        self.novel = novel
        self.chapters = chapters
        self.index = min(max(0, index), max(0, chapters.count - 1))
        if let pl = place, pl.p > 0 || pl.o > 0 { startPlace = ["p": pl.p, "o": pl.o] }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
        readAtStart = chapters.filter(\.read).count
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    override var preferredStatusBarStyle: UIStatusBarStyle { settings.current.isDark ? .lightContent : .darkContent }
    override var prefersHomeIndicatorAutoHidden: Bool { !chromeShown }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationLocked ? .portrait : .allButUpsideDown }

    /// EPUB books have their own reading mode (an endless scroll by default).
    private var mode: String { novel.source == "epub" ? settings.prefs.epubMode : settings.prefs.mode }
    private var paged: Bool { mode == "paged" }
    private var continuous: Bool { mode == "continuous" }

    // MARK: building

    override func loadView() {
        let root = UIView()
        root.backgroundColor = UIColor(hex: settings.current.bg)
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: AppSchemeHandler.scheme)
        cfg.userContentController.add(WeakScriptHandler(self), name: "reader")
        let w = ReaderWebView(frame: .zero, configuration: cfg)
        w.owner = self
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.scrollView.showsVerticalScrollIndicator = false
        w.scrollView.showsHorizontalScrollIndicator = false
        w.scrollView.delegate = self
        w.scrollView.pinchGestureRecognizer?.isEnabled = false
        w.allowsLinkPreview = false
        w.alpha = 0
        w.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(w)
        NSLayoutConstraint.activate([
            w.topAnchor.constraint(equalTo: root.topAnchor), w.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            w.leftAnchor.constraint(equalTo: root.leftAnchor), w.rightAnchor.constraint(equalTo: root.rightAnchor)
        ])
        web = w
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // the reader's own menus and sheets follow the app's language, whatever the phone's is
        if #available(iOS 17.0, *) { traitOverrides.layoutDirection = Lang.english ? .leftToRight : .rightToLeft }
        buildChrome()
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        view.addGestureRecognizer(pullPan)
        for dir in [UISwipeGestureRecognizer.Direction.right, .left] {
            let s = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            s.direction = dir
            s.delegate = self
            web.addGestureRecognizer(s)
        }
        if let u = URL(string: AppSchemeHandler.scheme + "://app/reader/reader.html") { web.load(URLRequest(url: u)) }
        settings.$themes.combineLatest(settings.$currentID, settings.$prefs)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &bag)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(wentAway), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(cameBack), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(rulesChanged), name: .replaceRulesChanged, object: nil)
        nc.addObserver(self, selector: #selector(noteSaved(_:)), name: .noteSaved, object: nil)
        nc.addObserver(self, selector: #selector(lockChanged), name: .readerLockChanged, object: nil)
        // the page follows the library: a highlight changed or deleted anywhere (the notebook, a form over the page, the
        // book's list) is drawn again in the chapters on the page
        marksSeen = marksSignature()
        Library.shared.$state
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.libraryChanged() }
            .store(in: &bag)
        clock = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        loadLabels()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// Where Apple Books puts them in an Arabic layout: close top-left, the menu button bottom-right.
    private func buildChrome() {
        let g = view.safeAreaLayoutGuide
        topFade.color = UIColor(hex: settings.current.bg)
        topFade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topFade)
        NSLayoutConstraint.activate([
            topFade.topAnchor.constraint(equalTo: view.topAnchor), topFade.leftAnchor.constraint(equalTo: view.leftAnchor),
            topFade.rightAnchor.constraint(equalTo: view.rightAnchor), topFade.bottomAnchor.constraint(equalTo: g.topAnchor, constant: 14)
        ])
        ribbon.tintColor = UIColor(red: 0.92, green: 0.27, blue: 0.27, alpha: 1)
        ribbon.contentMode = .scaleAspectFit
        for v in [closeButton, menuButton, topPill, bottomPill, ribbon] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.alpha = 0
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            closeButton.leftAnchor.constraint(equalTo: g.leftAnchor, constant: 14),
            closeButton.topAnchor.constraint(equalTo: g.topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 44), closeButton.heightAnchor.constraint(equalToConstant: 44),
            topPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topPill.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            topPill.leftAnchor.constraint(greaterThanOrEqualTo: closeButton.rightAnchor, constant: 8),
            menuButton.rightAnchor.constraint(equalTo: g.rightAnchor, constant: -14),
            menuButton.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -2),
            menuButton.widthAnchor.constraint(equalToConstant: 44), menuButton.heightAnchor.constraint(equalToConstant: 44),
            bottomPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomPill.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
            ribbon.rightAnchor.constraint(equalTo: menuButton.rightAnchor, constant: -12),
            ribbon.bottomAnchor.constraint(equalTo: menuButton.topAnchor, constant: 2),
            ribbon.widthAnchor.constraint(equalToConstant: 18), ribbon.heightAnchor.constraint(equalToConstant: 22)
        ])
        closeButton.button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.button.accessibilityLabel = "إغلاق".tr
        menuButton.button.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        menuButton.button.accessibilityLabel = "القائمة".tr
        // «690 من 2334»: a tap asks for a chapter's number and goes there (reader 2.4)
        bottomPill.isUserInteractionEnabled = true
        bottomPill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pillTapped)))
    }

    // MARK: talking to the page and to the library

    func call(_ body: String, _ args: [String: Any] = [:], done: ((Any?) -> Void)? = nil) {
        web.jalees(body + "; return 1", args, done: done)
    }

    func ask(_ body: String, _ args: [String: Any] = [:], done: @escaping (Any?) -> Void) {
        web.jalees("return " + body, args, done: done)
    }

    /// Asks the library (where the book's highlights and notebook live), by the names the web library had.
    func library(_ body: String, _ args: [String: Any] = [:], done: ((Any?) -> Void)? = nil) {
        // the call first, then the answer: `done?(NovelLibrary.call(…))` skipped the call itself when nobody waited for
        // an answer (optional chaining does not evaluate the argument), so a highlight, its removal and the reading
        // session were never saved
        let r = NovelLibrary.call(body, args)
        done?(r)
    }

    private func applyTheme() {
        let t = settings.current
        view.backgroundColor = UIColor(hex: t.bg)
        topFade.color = UIColor(hex: t.bg)
        setNeedsStatusBarAppearanceUpdate()
        web.scrollView.isPagingEnabled = paged && settings.prefs.anim == "slide"
        web.scrollView.isScrollEnabled = !(paged && settings.prefs.anim != "slide")
        guard pageReady else { return }
        var p = t.css
        settings.prefs.css.forEach { p[$0] = $1 }
        p["mode"] = mode
        if novel.source != "kolnovel" { p["comments"] = false }
        call("JR.setPrefs(p)", ["p": p])
        call("(function(c){var s=document.getElementById('uf');if(!s){s=document.createElement('style');s.id='uf';document.head.appendChild(s)}s.textContent=c})(c)", ["c": settings.fontCSS])
        let names = "\(settings.prefs.nameStyle)|\(settings.prefs.showNames)"
        if names != sentNames { sendNames() }
        updateRibbon()
    }

    /// the names' style the page has, so they are sent again only when it changes
    private var sentNames = ""

    private func shownTitle(_ ch: ChapterRow, _ t: ChapterText) -> String {
        if !ch.numbered { return "" }
        if !ch.title.isEmpty { return ch.title }
        var s = t.title
        if let r = s.range(of: #"^\s*(الفصل|فصل)\s*[\d٠-٩]+\s*[-–—:：.]?\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    /// Everything the page needs to draw one chapter, with its highlights.
    private func payload(_ i: Int) async throws -> [String: Any] {
        let ch = chapters[i]
        let t = try await Novels.shared.text(ch, source: novel.source)
        chapters[i].saved = true
        let words = t.words
        var o: [String: Any] = ["id": ch.id, "label": ch.label, "title": shownTitle(ch, t), "paras": Replacer.apply(t.paras, novel: novel.id),
                                "words": words, "minutes": max(1, Int((Double(words) / 220).rounded()))]
        if i + 1 < chapters.count { o["next"] = chapters[i + 1].line }
        if i > 0 { o["prev"] = "السابق · " + chapters[i - 1].line }
        if t.removed > 0 { o["removed"] = t.removed == 1 ? "سطر واحد" : (t.removed == 2 ? "سطرين" : "\(t.removed) أسطر") }
        // the page shows the comments button when comments are on, so turning them on works without reopening
        if novel.source == "kolnovel" { o["comments"] = 0 }
        o["marks"] = await marks(for: ch.id).marks
        return o
    }

    private func marks(for chapter: Int) async -> (marks: [[String: Any]], bmarks: [[String: Any]]) {
        guard let b = bookID else { return ([], []) }
        return NovelLibrary.marks(b, chapter: chapter)
    }

    func show(_ i: Int, place given: [String: Any]?, refresh: Bool = false) {
        guard chapters.indices.contains(i) else { return }
        var place = given
        if place == nil, let saved = Novels.shared.place(in: chapters[i].id) { place = ["p": saved.p, "o": saved.o] }
        index = i
        lastPos = [:]
        token += 1
        let mine = token
        let ch = chapters[i]
        pagesLeft = 0
        updatePills(known: false)
        closeOverlays()
        if !ch.saved || refresh {
            call("JR.state('loading', title, '')", ["title": ch.label])
            UIView.animate(withDuration: 0.12) { self.web.alpha = 1 }
        }
        Novels.shared.savePlace(novel: novel.id, chapter: ch.id, p: (place?["p"] as? Int) ?? 0, o: (place?["o"] as? Double) ?? 0)
        Novels.shared.logHistory(novel: novel.id, chapter: ch.id)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                if refresh { _ = try await Novels.shared.text(ch, source: self.novel.source, refresh: true) }
                let o = try await self.payload(i)
                guard mine == self.token else { return }
                self.loadedInPage = [ch.id]
                var args: [String: Any] = ["ch": o, "pos": NSNull()]
                if let place = place { args["pos"] = place }
                self.call("JR.load(ch, pos)", args)
                self.refreshBookmarks()
                Novels.shared.prepare(after: i, in: self.chapters, source: self.novel.source, count: self.settings.prefs.ahead)
            } catch {
                guard mine == self.token else { return }
                self.call("JR.state('error', title, detail)", ["title": "ما انفتح \(ch.label)", "detail": error.localizedDescription])
                UIView.animate(withDuration: 0.2) { self.web.alpha = 1 }
            }
        }
    }

    /// Continuous reading: the page asks for the chapter after (or before) one it holds.
    private func need(_ dir: String, after id: Int) {
        guard let at = chapters.firstIndex(where: { $0.id == id }) else { return }
        let j = dir == "next" ? at + 1 : at - 1
        guard chapters.indices.contains(j), !loadedInPage.contains(chapters[j].id) else { return }
        loadedInPage.insert(chapters[j].id)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let o = try? await self.payload(j) else { self.loadedInPage.remove(self.chapters[j].id); return }
            guard self.loadedInPage.contains(self.chapters[j].id) else { return }   // a new chapter was opened meanwhile
            self.call(dir == "next" ? "JR.append(ch)" : "JR.prepend(ch)", ["ch": o])
            Novels.shared.prepare(after: j, in: self.chapters, source: self.novel.source, count: self.settings.prefs.ahead)
        }
    }

    // MARK: messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let o = message.body as? [String: Any], let t = o["t"] as? String else { return }
        switch t {
        case "ready":
            pageReady = true
            if Lang.english {
                // the page's own words in English (reader.js T())
                var d: [String: Any] = ["__en": true]
                for k in ["ملاحظة", "عدد الكلمات {}", "التعليقات", "الفصل التالي", "وصلت لآخر فصل منشور", "نظّفنا {} من إضافات الموقع",
                          "حاول مرة ثانية", "قارئ", "تعليقات أقدم ({})", "افتحها في الموقع بأسماء أصحابها", "أجيب التعليقات",
                          "ما فيه تعليقات على هالفصل.", "حرّك دليل السطر", "أجيب الأقدم"] { d[k] = k.tr }
                call("JR.lang(d)", ["d": d])
            }
            applyTheme()
            show(index, place: startPlace)
            startPlace = nil
        case "loaded":
            UIView.animate(withDuration: 0.22) { self.web.alpha = 1 }
            sendNames()
        case "pos":
            activity()
            lastPos = o
            let id = NovelBridge.num(o["id"])
            if let i = chapters.firstIndex(where: { $0.id == id }), i != index {
                // continuous reading moved into another chapter: the one before it is read (scrolled through, not
                // swiped past)
                if i > index, Date().timeIntervalSince(jumping ?? .distantPast) > 1.5 { markRead(index) }
                index = i
                refreshBookmarks()
                Novels.shared.logHistory(novel: novel.id, chapter: id)
            }
            guard chapters.indices.contains(index), id == chapters[index].id else { return }
            pagesLeft = NovelBridge.num(o["left"])
            updatePills(known: true)
            Novels.shared.savePlace(novel: novel.id, chapter: chapters[index].id, p: NovelBridge.num(o["p"]), o: (o["o"] as? Double) ?? 0)
            if (o["end"] as? Bool) == true { markRead(index) }
            updateRibbon()
        case "tap":
            activity()
            if markBar != nil || menu != nil { closeOverlays(); return }
            // reading aloud: a tap on a paragraph goes on from it
            if ReadAloud.shared.active, ReadAloud.shared.reader === self, o["pp"] != nil, !(o["pp"] is NSNull) {
                ReadAloud.shared.jump(chapterID: NovelBridge.num(o["pid"]), para: NovelBridge.num(o["pp"]))
                Haptics.play("sel")
                return
            }
            let x = (o["x"] as? Double) ?? 0.5
            if paged && (x < 0.28 || x > 0.72) {
                // the side where the next page is: the left of an Arabic book, the right of an English one
                turnPage((x < 0.28) == bookRTL ? 1 : -1)
            } else {
                setChrome(!chromeShown)
            }
        case "dir":
            // the book's direction, from the page (reader.js bookDir): Arabic books read right to left, English left to right
            bookRTL = (o["rtl"] as? Bool) ?? true
            // the back and forward pills read the way the book does
            jumpRow.semanticContentAttribute = bookRTL ? .forceRightToLeft : .forceLeftToRight
        case "sel":
            selecting = (o["on"] as? Bool) == true
            if selecting { setChrome(false); closeOverlays() }
        case "markTap":
            openMarkBar(id: o["id"] as? String ?? "", chapter: NovelBridge.num(o["ch"]), rect: rect(o["rect"]))
        case "drop":
            // the page let go of a chapter far from the reader (memory): it may be asked for again
            loadedInPage.remove(NovelBridge.num(o["id"]))
        case "need":
            need(o["dir"] as? String ?? "next", after: NovelBridge.num(o["id"]))
        case "nameTap":
            showCharacter(o["id"] as? String ?? "", near: rect(o["rect"]))
        case "img":
            if let s = o["src"] as? String { ImageViewer.show(s, from: self) }
        case "act":
            let a = o["a"] as? String ?? ""
            switch a {
            case "next": turn(1)
            case "prev": turn(-1)
            case "retry": show(index, place: nil, refresh: true)
            case "comments", "moreComments": loadComments(NovelBridge.num(o["id"]), more: a == "moreComments")
            case "commentsSite":
                if let ch = chapters.first(where: { $0.id == NovelBridge.num(o["id"]) }) { NovelBridge.openSite(ch.url + "#comments") }
            default: break
            }
        default:
            break
        }
    }

    func rect(_ v: Any?) -> CGRect {
        guard let d = v as? [String: Any] else { return CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1) }
        func f(_ k: String) -> CGFloat { CGFloat((d[k] as? Double) ?? Double(NovelBridge.num(d[k]))) }
        return CGRect(x: f("x"), y: f("y"), width: f("w"), height: f("h"))
    }

    private func markRead(_ i: Int) {
        guard chapters.indices.contains(i), !chapters[i].read else { return }
        chapters[i].read = true
        Novels.shared.markRead(chapters[i].id)
    }

    func turn(_ step: Int) {
        guard !turning else { return }
        turning = true
        ask("JR.here()") { [weak self] v in
            guard let self = self else { return }
            let here = NovelBridge.num((v as? [String: Any])?["id"])
            let at = self.chapters.firstIndex(where: { $0.id == here }) ?? self.index
            let i = at + step
            guard self.chapters.indices.contains(i) else {
                self.turning = false
                self.toast(step > 0 ? "هذا آخر فصل" : "هذا أول فصل")
                return
            }
            // moving on is not finishing: a chapter is read when its end is reached, not when it is swiped past
            Haptics.play("sel")
            let id = self.chapters[i].id
            // where you stopped in that chapter (its start when you never read in it)
            let saved = Novels.shared.place(in: id)
            let pos: Any = saved.map { ["p": $0.p, "o": $0.o] as [String: Any] } ?? NSNull()
            self.jumping = Date()
            UIView.animate(withDuration: 0.1, animations: { self.web.alpha = 0 }, completion: { _ in
                self.ask("JR.toChapter(id, pos)", ["id": id, "pos": pos]) { done in
                    if NovelBridge.num(done) == 1 {
                        self.index = i
                        self.lastPos = [:]
                        Novels.shared.logHistory(novel: self.novel.id, chapter: id)
                        self.refreshBookmarks()
                        UIView.animate(withDuration: 0.16) { self.web.alpha = 1 }
                    } else {
                        // not on the page: opened at its saved place (show() reads it), else its start
                        self.show(i, place: nil)
                    }
                    self.turning = false
                }
            })
        }
    }

    private var turning = false
    /// the open book reads right to left (Arabic) or left to right (English), whatever the app's language is; the
    /// page tells it when a chapter loads. Page turns, curl, tap zones and swipes go with it.
    var bookRTL = true
    /// a swipe to another chapter just happened: the page moving into it is not reading through the one before
    private var jumping: Date?

    private func turnPage(_ dir: Int) {
        if settings.prefs.anim == "curl" { curl(dir); return }
        ask("JR.turn(d)", ["d": dir]) { [weak self] v in
            if NovelBridge.num(v) == 0 { self?.turn(dir) }
        }
    }

    // MARK: page curl (طي): the page peels over, like a paper book

    private var curling = false

    private func curl(_ dir: Int) {
        guard !curling else { return }
        curling = true
        web.takeSnapshot(with: nil) { [weak self] before, _ in
            guard let self = self, let before = before else { self?.curling = false; return }
            let cover = UIImageView(image: before)
            cover.frame = self.web.frame
            self.view.insertSubview(cover, aboveSubview: self.web)
            self.ask("JR.turn(d, true)", ["d": dir]) { moved in
                guard NovelBridge.num(moved) == 1 else {
                    cover.removeFromSuperview()
                    self.curling = false
                    self.turn(dir)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                    self.web.takeSnapshot(with: nil) { after, _ in
                        guard let after = after else { cover.removeFromSuperview(); self.curling = false; return }
                        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: nil)
                        pvc.view.semanticContentAttribute = self.bookRTL ? .forceRightToLeft : .forceLeftToRight
                        pvc.isDoubleSided = false
                        pvc.view.backgroundColor = .clear
                        pvc.setViewControllers([SnapPage(before)], direction: .forward, animated: false)
                        self.addChild(pvc)
                        pvc.view.frame = self.web.frame
                        self.view.insertSubview(pvc.view, aboveSubview: cover)
                        pvc.didMove(toParent: self)
                        cover.removeFromSuperview()
                        Haptics.play("sel")
                        pvc.setViewControllers([SnapPage(after)], direction: dir > 0 ? .forward : .reverse, animated: true) { _ in
                            pvc.willMove(toParent: nil)
                            pvc.view.removeFromSuperview()
                            pvc.removeFromParent()
                            self.curling = false
                        }
                    }
                }
            }
        }
    }

    // MARK: controls

    private func updatePills(known: Bool) {
        guard chapters.indices.contains(index) else { return }
        let ch = chapters[index]
        if paged, lastPos["pages"] != nil {
            topPill.text = "الصفحة \(NovelBridge.num(lastPos["page"]) + 1) من \(NovelBridge.num(lastPos["pages"]))".tr
        } else {
            topPill.text = (!known ? ch.label : (pagesLeft == 0 ? "الصفحة الأخيرة في الفصل" : "الصفحات المتبقية في الفصل: \(pagesLeft)")).tr
        }
        if ch.numbered, let last = chapters.last(where: { $0.numbered }) {
            bottomPill.text = "\(ch.num) من \(last.num)".tr
        } else {
            bottomPill.text = "\(index + 1) من \(chapters.count)".tr
        }
    }

    func setChrome(_ on: Bool) {
        guard on != chromeShown else { return }
        chromeShown = on
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            for v in [self.closeButton, self.menuButton, self.topPill, self.bottomPill] as [UIView] { v.alpha = on ? 1 : 0 }
            self.jumpRow.alpha = on && self.hasJumps ? 1 : 0
            self.updateRibbon()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        activity()
        setChrome(false)
        closeOverlays()
    }

    /// Slide pages: pulling past the last (or first) page moves to the next (or previous) chapter.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard paged, settings.prefs.anim == "slide" else { return }
        let x = scrollView.contentOffset.x, maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        // pulled past the left edge: after the last page of an Arabic book, before the first of an English one
        if x < -60 { turn(bookRTL ? 1 : -1) } else if x > maxX + 60 { turn(bookRTL ? -1 : 1) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// The pull to close starts only with the controls showing, nothing over the page, the finger going down, and
    /// (scrolling) the text at its top.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pullPan else { return true }
        guard chromeShown, markBar == nil, menu == nil, presentedViewController == nil, pullShot == nil else { return false }
        let v = pullPan.velocity(in: view)
        guard v.y > 0, v.y > abs(v.x) * 1.5 else { return false }
        return paged || web.scrollView.contentOffset.y <= 1
    }

    @objc private func pulled(_ g: UIPanGestureRecognizer) {
        let ty = max(0, g.translation(in: view).y)
        switch g.state {
        case .began:
            guard let shot = view.snapshotView(afterScreenUpdates: false) else { return }
            web.scrollView.isScrollEnabled = false
            shot.frame = view.bounds
            shot.layer.cornerCurve = .continuous
            shot.clipsToBounds = true
            view.addSubview(shot)
            pullShot = shot
            // only what shows now is hidden (and shown again on a cancel)
            pullHidden = view.subviews.filter { $0 !== shot && !$0.isHidden }
            pullHidden.forEach { $0.isHidden = true }
            view.backgroundColor = .black
        case .changed:
            guard let shot = pullShot else { return }
            let k = min(1, ty / view.bounds.height)
            let s = 1 - 0.14 * k
            shot.transform = CGAffineTransform(translationX: 0, y: ty * 0.85).scaledBy(x: s, y: s)
            shot.layer.cornerRadius = min(28, ty / 3)
        default:
            guard let shot = pullShot else { return }
            web.scrollView.isScrollEnabled = true
            let vy = g.velocity(in: view).y
            if g.state == .ended && (ty > 140 || vy > 900) {
                Haptics.play("soft")
                UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseIn) {
                    shot.transform = CGAffineTransform(translationX: 0, y: self.view.bounds.height * 0.6).scaledBy(x: 0.8, y: 0.8)
                    shot.alpha = 0.6
                } completion: { _ in self.closeTapped() }
            } else {
                UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
                    shot.transform = .identity
                    shot.layer.cornerRadius = 0
                } completion: { _ in
                    self.pullHidden.forEach { $0.isHidden = false }
                    self.pullHidden = []
                    self.view.backgroundColor = UIColor(hex: self.settings.current.bg)
                    shot.removeFromSuperview()
                    self.pullShot = nil
                }
            }
        }
    }

    /// In a right-to-left book a swipe to the right goes forward.
    /// text is selected (or being selected): a sideways move is the selection's, never a page or chapter turn
    private var selecting = false

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        guard markBar == nil, !selecting else { return }
        // a swipe to the right goes forward in an Arabic book, back in an English one
        let dir = (g.direction == .right) == bookRTL ? 1 : -1
        if paged {
            // fade and curl pages turn by swiping (slide pages scroll by themselves)
            if settings.prefs.anim != "slide" { turnPage(dir) }
            return
        }
        guard settings.prefs.swipeChapters else { return }
        turn(dir)
    }

    private var rulesWork: DispatchWorkItem?

    /// A replacement rule changed (in the settings over the page, or anywhere): the chapter is shown again where you
    /// are, with the rules as they are now. Once the typing stops, not on every letter.
    @objc private func rulesChanged() {
        rulesWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.chapters.indices.contains(self.index) else { return }
            let here = self.lastPos
            let same = NovelBridge.num(here["id"]) == self.chapters[self.index].id
            self.show(self.index, place: same ? ["p": NovelBridge.num(here["p"]), "o": (here["o"] as? Double) ?? 0] : nil)
        }
        rulesWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    @objc func closeTapped() {
        if ReadAloud.shared.reader === self { ReadAloud.shared.stop() }
        savePlaceNow()
        endSession()
        onClose?()
        dismiss(animated: true)
    }

    @objc private func menuTapped() {
        if menu != nil { closeOverlays(); return }
        openMenu()
    }

    /// The menu, as the owner arranged it (ReaderMenuView, «خصّص القائمة»).
    func openMenu() {
        guard menu == nil, presentedViewController == nil else { return }
        let m = ReaderMenuView(reader: self)
        menu = m
        m.show(in: view, above: menuButton)
        // the menu's chapter bar says it: the pill under it goes meanwhile
        if m.showsChapterBar { UIView.animate(withDuration: 0.16) { self.bottomPill.alpha = 0 } }
        Haptics.play("soft")
    }

    @objc private func pillTapped() { askChapter() }

    func closeOverlays() {
        if let m = menu {
            m.hide()
            menu = nil
            UIView.animate(withDuration: 0.16) { self.bottomPill.alpha = self.chromeShown ? 1 : 0 }
        }
        markBar?.removeFromSuperview(); markBar = nil
    }

    /// Two fingers resize the text, as in Apple Books; the size is kept with the theme.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchBase = settings.current.size
        case .changed: call("JR.setSize(s)", ["s": min(48, max(12, (pinchBase * Double(g.scale)).rounded()))])
        case .ended, .cancelled: settings.edit { $0.size = min(48, max(12, (pinchBase * Double(g.scale)).rounded())) }
        default: break
        }
    }

    // MARK: bookmarks (hidden unless the ribbon is turned on; listed with the highlights)

    func refreshBookmarks() {
        guard chapters.indices.contains(index) else { return }
        let ch = chapters[index].id
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let m = await self.marks(for: ch)
            self.bookmarks = m.bmarks
            self.marksHere = m.marks
            self.updateRibbon()
        }
    }

    var bookmarkedHere: Bool {
        let p = NovelBridge.num(lastPos["p"])
        return bookmarks.contains { abs(NovelBridge.num($0["p"]) - p) <= 1 }
    }

    private func updateRibbon() {
        ribbon.alpha = settings.prefs.showRibbon && bookmarkedHere ? 1 : 0
    }

    func toggleBookmark() {
        guard let b = bookID, chapters.indices.contains(index) else { return }
        let ch = chapters[index]
        let on = !bookmarkedHere
        let bm: [String: Any] = ["ch": ch.id, "chLabel": ch.line, "p": NovelBridge.num(lastPos["p"]), "o": (lastPos["o"] as? Double) ?? 0]
        library("wirdNovelBmark(b, m, on)", ["b": b, "m": bm, "on": on]) { [weak self] _ in self?.refreshBookmarks() }
        toast(on ? "وقفة: تمت الإضافة" : "وقفة: انحذفت")
        Haptics.play("success")
    }

    // MARK: highlights and the notebook, from the selection

    func selectionMenu() -> UIMenu {
        let color = MarkBar.colors.first { $0.id == lastColor } ?? MarkBar.colors[0]
        let hl = UIAction(title: "تظليل".tr, image: UIImage(systemName: "highlighter")?.withTintColor(color.ui, renderingMode: .alwaysOriginal)) { [weak self] _ in self?.fromSelection("highlight") }
        let note = UIAction(title: "ملاحظة".tr, image: UIImage(systemName: "note.text")) { [weak self] _ in self?.fromSelection("note") }
        // the notebook's kinds; then his named colours (معلومة، مضحك، تلميح…), the categories of the notebook's «تظليلات»
        var kept: [UIMenuElement] = NoteKind.allCases.map { k -> UIMenuElement in
            UIAction(title: k.name.tr, image: UIImage(systemName: k.symbol)) { [weak self] _ in self?.fromSelection(k.rawValue) }
        }
        let named = MarkBar.colors.compactMap { c -> UIAction? in
            let n = (labelNames[c.id] ?? "").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            return UIAction(title: n, image: UIImage(systemName: "circle.fill")?.withTintColor(c.ui, renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.fromSelection("color:" + c.id)
            }
        }
        if !named.isEmpty { kept.append(UIMenu(title: "تظليل باسم".tr, options: .displayInline, children: named)) }
        let nb = UIMenu(title: "للدفتر".tr, image: UIImage(systemName: "book.closed"), children: kept)
        let aloud = UIAction(title: "اقرأ من هنا".tr, image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
            self?.ask("JR.selection()") { v in
                guard let self = self, let s = v as? [String: Any], let i = self.chapters.firstIndex(where: { $0.id == NovelBridge.num(s["ch"]) }) else { return }
                self.call("JR.clearSelection()")
                self.startReadAloud(chapter: i, para: NovelBridge.num(s["p"]))
            }
        }
        // a name the translation spells its own way: this novel's rules, with the word's rule started
        let replace = UIAction(title: "استبدال الكلمة".tr, image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
            self?.ask("JR.selection()") { v in
                guard let self = self, let s = v as? [String: Any], let text = s["text"] as? String else { return }
                self.call("JR.clearSelection()")
                self.openRules(seed: String(text.prefix(60)))
            }
        }
        return UIMenu(title: "", options: .displayInline, children: [hl, note, nb, aloud, replace])
    }

    /// «الفصل من مصدر ثاني»: this chapter again from a backup source, kept as its text (س56).
    func chapterFromMirror() {
        ask("JR.here()") { [weak self] v in
            guard let self = self else { return }
            let id = NovelBridge.num((v as? [String: Any])?["id"])
            guard let i = self.chapters.firstIndex(where: { $0.id == id }) else { return }
            self.toast("أجيب الفصل من مصدر ثاني…")
            Task { @MainActor in
                do {
                    _ = try await Novels.shared.textFromMirror(self.chapters[i], novel: self.novel.id)
                    self.show(i, place: ["p": 0, "o": 0])
                    self.toast("الفصل الحين من " + (Novel.siteNames[DB.shared.get("chapter.source.\(id)") ?? ""] ?? "المصدر الثاني"))
                } catch {
                    self.toast(error.localizedDescription)
                }
            }
        }
    }

    // MARK: reading aloud (ReadAloud.swift)

    private var readBar: ReadAloudBar?

    /// From where the reader is now.
    func startReadAloud() {
        ask("JR.where()") { [weak self] v in
            guard let self = self else { return }
            let w = v as? [String: Any]
            let id = NovelBridge.num(w?["id"])
            let i = self.chapters.firstIndex { $0.id == id } ?? self.index
            self.startReadAloud(chapter: i, para: NovelBridge.num(w?["p"]))
        }
    }

    func startReadAloud(chapter i: Int, para: Int) {
        closeOverlays()
        setChrome(false)
        ReadAloud.shared.onChange = { [weak self] in self?.readAloudChanged() }
        ReadAloud.shared.start(self, chapter: i, para: para)
        readAloudChanged()
    }

    /// The player shows while this reader reads aloud.
    func readAloudChanged() {
        let on = ReadAloud.shared.active && ReadAloud.shared.reader === self
        NSLog("jalees read aloud: %@, bar %@", on ? "on" : "off", readBar == nil ? "none" : "shown")
        if on {
            if readBar == nil {
                let b = ReadAloudBar()
                b.translatesAutoresizingMaskIntoConstraints = false
                b.alpha = 0
                view.addSubview(b)
                let g = view.safeAreaLayoutGuide
                NSLayoutConstraint.activate([
                    b.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    b.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -56),
                    b.widthAnchor.constraint(equalToConstant: min(view.bounds.width - 28, 360)),
                    b.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
                ])
                readBar = b
                UIView.animate(withDuration: 0.22) { b.alpha = 1 }
            }
            readBar?.refresh()
        } else if let b = readBar {
            readBar = nil
            UIView.animate(withDuration: 0.18, animations: { b.alpha = 0 }, completion: { _ in b.removeFromSuperview() })
        }
    }

    func markReadForReadAloud(_ i: Int) { markRead(i) }
    func readAloudActivity() { activity() }

    /// Reading aloud went on to the next chapter: the page follows (when it is on screen).
    func followReadAloud(to i: Int) {
        guard chapters.indices.contains(i), viewIfLoaded?.window != nil else { return }
        let id = chapters[i].id
        ask("JR.toChapter(id)", ["id": id]) { [weak self] done in
            guard let self = self else { return }
            if NovelBridge.num(done) == 1 { self.index = i; self.refreshBookmarks() } else { self.show(i, place: ["p": 0, "o": 0]) }
        }
    }

    private func fromSelection(_ what: String) {
        ask("JR.selection()") { [weak self] v in
            guard let self = self, var s = v as? [String: Any], let text = s["text"] as? String, !text.isEmpty else { return }
            let r = self.rect(s["rect"])
            s.removeValue(forKey: "rect")
            let mergeID = s["merge"] as? String
            let drop = (s["drop"] as? [String]) ?? []
            s.removeValue(forKey: "merge")
            s.removeValue(forKey: "drop")
            /// a highlight under the selection that is only a highlight (one that is an entry's place is left as it is)
            func plain(_ id: String?) -> [String: Any]? {
                self.marksHere.first { ($0["id"] as? String) == id && ReaderViewController.isPlain($0) }
            }
            let named = what.hasPrefix("color:") ? String(what.dropFirst(6)) : nil
            if what == "highlight" || what == "note" || named != nil {
                // a highlight under it grows to take the selection in; one that is a quote's (word's) place stays its own
                var m = plain(mergeID) ?? ["id": UUID().uuidString, "color": self.lastColor, "style": "hl", "note": ""]
                for k in ["ch", "chLabel", "p", "s", "pe", "e", "text"] { m[k] = s[k] }
                if let c = named { m["color"] = c }
                for d in drop { if let x = plain(d) { self.deleteMark(x) } }
                self.call("JR.clearSelection()")
                self.saveMark(m)
                if what == "note" {
                    self.editNote(m)
                } else if let c = named {
                    self.toast("في الدفتر: «" + (self.labelNames[c] ?? "") + "»")
                } else {
                    self.openMarkBar(mark: m, rect: r)
                }
                return
            }
            // a quote, thought or word: the notebook's form over the page; once it is saved, the passage is highlighted
            // as its place (the highlight under the selection, if there is one, becomes it). A character is not: its
            // name is marked wherever it appears.
            var link: [String: Any]?
            if what != NoteKind.char.rawValue {
                var m = plain(mergeID) ?? ["id": UUID().uuidString, "color": self.lastColor, "style": what == NoteKind.word.rawValue ? "ul" : "hl", "note": ""]
                for k in ["ch", "chLabel", "p", "s", "pe", "e", "text"] { m[k] = s[k] }
                link = m
            }
            self.ask("JR.sentence()") { sent in
                self.call("JR.clearSelection()")
                self.openNotebook(kind: what, text: text, sentence: (sent as? String) ?? "", at: s, link: link)
            }
        }
    }

    /// A highlight that is only a highlight (not the place of a quote, thought or word).
    static func isPlain(_ m: [String: Any]) -> Bool { ((m["item"] as? String) ?? "").isEmpty }

    func saveMark(_ m: [String: Any]) {
        call("JR.putMark(m)", ["m": m])
        if let b = bookID { library("wirdNovelMark(b, m)", ["b": b, "m": m]) }
        if let c = m["color"] as? String, c != lastColor { lastColor = c; DB.shared.set("reader.lastColor", c) }
        if let i = marksHere.firstIndex(where: { ($0["id"] as? String) == (m["id"] as? String) }) { marksHere[i] = m } else { marksHere.append(m) }
        // the page has it already: the library's change need not draw it again
        marksSeen = marksSignature()
    }

    func deleteMark(_ m: [String: Any]) {
        guard let id = m["id"] as? String else { return }
        call("JR.dropMark(ch, id)", ["ch": NovelBridge.num(m["ch"]), "id": id])
        if let b = bookID { library("wirdNovelMarkDel(b, id)", ["b": b, "id": id]) }
        marksHere.removeAll { ($0["id"] as? String) == id }
        marksSeen = marksSignature()
        closeOverlays()
    }

    /// «إزالة» on a highlight. One that is a quote's (thought's, word's) place asks: only the highlight, or the entry too.
    func removeMark(_ m: [String: Any]) {
        guard let b = bookID, let book = Library.shared.state.book(b), let jm = JSONValue(any: m).object, let e = book.entry(of: jm) else {
            deleteMark(m)
            return
        }
        closeOverlays()
        let a = UIAlertController(title: (e.kind.name + " في الدفتر").tr, message: "هذا التظليل مكانه في النص.".tr, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "إزالة التظليل فقط".tr, style: .default) { [weak self] _ in
            self?.deleteMark(m)
            self?.toast("بقي في الدفتر بدون تظليل")
        })
        a.addAction(UIAlertAction(title: ("حذف " + e.kind.the + " أيضًا").tr, style: .destructive) { [weak self] _ in
            // the entry and its highlight go together (the page follows the library)
            NoteItems.delete(b, e.kind, e.item.id)
            self?.toast("انحذف من الدفتر")
        })
        a.addAction(UIAlertAction(title: "إلغاء".tr, style: .cancel))
        a.popoverPresentationController?.sourceView = view
        a.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(a, animated: true)
    }

    /// «للدفتر ← اقتباس» on a highlight: the entry's form, and the highlight becomes its place once it is saved.
    func markToNotebook(_ m: [String: Any], kind: String) {
        openNotebook(kind: kind, text: (m["text"] as? String) ?? "", sentence: "", at: m, link: kind == NoteKind.char.rawValue ? nil : m)
    }

    /// The entry a highlight is the place of: its form over the page.
    func editEntry(of m: [String: Any]) {
        guard let k = m["kind"] as? String, let id = m["item"] as? String else { return }
        editItem(kind: k, id: id)
    }

    /// A highlight as a picture: the notebook's quote card in the book's colours (a quote's highlight: that quote's
    /// own card, with its speaker), over the page.
    func passageCard(_ m: [String: Any]) {
        closeOverlays()
        guard let b = bookID, Library.shared.state.book(b) != nil else { toast("افتح الرواية من مكتبتك عشان تنحفظ في دفترها"); return }
        var req = CardRequest(kind: .quote, book: b, quote: nil, text: (m["text"] as? String) ?? "")
        if let book = Library.shared.state.book(b), let jm = JSONValue(any: m).object, let e = book.entry(of: jm), e.kind == .quote {
            req = CardRequest(kind: .quote, book: b, quote: e.item.id)
        }
        let look = Appearance.shared.look
        let host = sheetHost(CardSheet(request: req).environment(\.look, look), large: true)
        host.overrideUserInterfaceStyle = look.dark ? .dark : .light
        presentOnTop(host)
    }

    private func openMarkBar(id: String, chapter: Int, rect: CGRect) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !self.marksHere.contains(where: { ($0["id"] as? String) == id }) { self.marksHere = await self.marks(for: chapter).marks }
            guard let m = self.marksHere.first(where: { ($0["id"] as? String) == id }) else { return }
            self.openMarkBar(mark: m, rect: rect)
        }
    }

    private func openMarkBar(mark: [String: Any], rect: CGRect) {
        closeOverlays()
        setChrome(false)
        // a highlight that is a quote's (thought's, word's) place says so, and opens that entry
        var entry: NoteKind?
        if let b = bookID, let book = Library.shared.state.book(b), let jm = JSONValue(any: mark).object { entry = book.entry(of: jm)?.kind }
        let bar = MarkBar(reader: self, mark: mark, labels: labelNames, entry: entry)
        markBar = bar
        bar.show(in: view, near: rect)
        Haptics.play("sel")
    }

    func loadLabels() {
        guard let b = bookID else { return }
        library("wirdNovelBook(b)", ["b": b]) { [weak self] v in
            guard let d = v as? [String: Any] else { return }
            var out: [String: String] = [:]
            for l in (d["labels"] as? [[String: Any]]) ?? [] { if let c = l["c"] as? String { out[c] = (l["name"] as? String) ?? "" } }
            self?.labelNames = out
            self?.characters = (d["chars"] as? [[String: Any]]) ?? []
            self?.sendNames()
        }
    }

    /// Characters of this book, for the page to mark their names.
    func sendNames() {
        let list = characters.map { ["id": $0["id"] ?? "", "name": $0["name"] ?? "", "alias": $0["alias"] ?? ""] }
        let style = settings.prefs.nameStyle
        guard pageReady else { return }   // the page sends «loaded» (and names follow) once it is ready
        sentNames = "\(style)|\(settings.prefs.showNames)"
        call("JR.setNames(l, on, st)", ["l": list, "on": settings.prefs.showNames && style != "off", "st": style])
    }

    /// A character's name tapped in the text: its card over the page (everything about it, and editing), never a
    /// trip out of the reader; closing the card is being back in the chapter where you were.
    private func showCharacter(_ id: String, near r: CGRect) {
        guard characters.contains(where: { ($0["id"] as? String) == id }) else { return }
        openCharacterCard(id)
    }

    /// A character's card over the page (or over the book's list).
    func openCharacterCard(_ id: String) {
        guard let b = bookID else { return }
        closeOverlays()
        let look = Appearance.shared.look
        let card = CharacterCard(bookID: b, charID: id).environment(\.look, look)
        let host = sheetHost(card)
        host.overrideUserInterfaceStyle = look.dark ? .dark : .light
        // an edit in the card (a new name or alias) shows in the page once it closes
        host.presentationController?.delegate = self
        presentOnTop(host)
    }

    /// Over whatever is showing: the page, or a sheet over it (the book's list: its forms open over it, and closing
    /// them is being back in the list).
    func presentOnTop(_ vc: UIViewController) {
        var top: UIViewController = self
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        top.present(vc, animated: true)
    }

    func editNote(_ m: [String: Any]) {
        closeOverlays()
        let sheet = NoteSheet(text: (m["text"] as? String) ?? "", note: (m["note"] as? String) ?? "") { [weak self] note in
            var x = m
            x["note"] = note
            self?.saveMark(x)
        }
        presentOnTop(sheetHost(sheet))
    }

    /// One notes form everywhere: the notebook's own form, over the page, filled from the selection (the text, the
    /// chapter, its place in the novel; a word's sentence and meaning). Its save is the notebook's save. With `link`
    /// (the highlight that is to be its place, new or already there), the entry and its highlight become one thing
    /// once the form is saved: `item.mark` and `mark.kind` + `mark.item`. A highlight's note goes into the entry.
    func openNotebook(kind: String, text: String, sentence: String, at s: [String: Any], link: [String: Any]? = nil) {
        closeOverlays()
        guard let b = bookID, chapters.indices.contains(index) else { toast("افتح الرواية من مكتبتك عشان تنحفظ في دفترها"); return }
        let ch = chapters.first { $0.id == NovelBridge.num(s["ch"]) } ?? chapters[index]
        let loc = Int(ch.num) ?? (ch.idx + 1)
        let nv: [String: Any] = ["ch": ch.id, "p": NovelBridge.num(s["p"]), "s": NovelBridge.num(s["s"]), "label": ch.line]
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var pre: [String: Any] = ["loc": loc, "nv": nv]
        switch kind {
        case "quote": pre["text"] = clean
        case "thought": pre["passage"] = clean
        case "word":
            let w = clean.trimmingCharacters(in: .punctuationCharacters)
            pre["word"] = w
            pre["ex"] = sentence
            pre["lang"] = WordLookup.language(of: w)
        default:
            pre["name"] = clean
            pre["first"] = loc
        }
        if var m = link, kind != NoteKind.char.rawValue, !clean.isEmpty, let markID = m["id"] as? String {
            let itemID = uid()
            pre["id"] = itemID
            pre["mark"] = markID
            m["kind"] = kind
            m["item"] = itemID
            let note = ((m["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty && kind != NoteKind.word.rawValue {
                // the highlight's words move into the entry: a thought's own words, a quote's note
                if kind == NoteKind.thought.rawValue { pre["text"] = note } else { pre["note"] = note }
                m["note"] = ""
            }
            pendingLinks[itemID] = m
        }
        let look = Appearance.shared.look
        let form = ItemForm(ref: ItemRef(book: b, kind: kind, item: nil, prefill: pre, inReader: true)).environment(\.look, look)
        let host = sheetHost(form, large: true)
        host.overrideUserInterfaceStyle = look.dark ? .dark : .light
        presentOnTop(host)
    }

    /// An entry of the book's notebook, edited in its form over the page (or over the book's list).
    func editItem(kind: String, id: String) {
        guard let b = bookID else { return }
        closeOverlays()
        let look = Appearance.shared.look
        let form = ItemForm(ref: ItemRef(book: b, kind: kind, item: id, inReader: true)).environment(\.look, look)
        let host = sheetHost(form, large: true)
        host.overrideUserInterfaceStyle = look.dark ? .dark : .light
        presentOnTop(host)
    }

    /// highlights waiting for their entry's form to be saved (the entry's id → the highlight, already linked to it)
    private var pendingLinks: [String: [String: Any]] = [:]

    /// An entry saved from a form over the page: a quote (thought, word) taken from the text is highlighted there now;
    /// a new character is named in the text at once, and its first appearance looked for.
    @objc private func noteSaved(_ n: Notification) {
        guard let u = n.userInfo, let b = bookID, (u["book"] as? String) == b else { return }
        if let id = u["id"] as? String, let m = pendingLinks.removeValue(forKey: id) {
            saveMark(m)
            toast("في الدفتر، ومظلّل في النص")
        }
        guard (u["kind"] as? String) == "char" else { return }
        loadLabels()
        if (u["new"] as? Bool) == true, let cid = u["id"] as? String, let name = u["name"] as? String {
            let was = (u["first"] as? Double).map { Int($0) } ?? -1
            findFirst(cid, names: [name, (u["alias"] as? String) ?? ""], was: was)
        }
    }

    /// A new character's first appearance becomes the chapter that first names it (unless it was changed meanwhile).
    private func findFirst(_ cid: String, names: [String], was: Int) {
        guard let b = bookID else { return }
        Task { @MainActor [weak self] in
            guard let self = self, let f = await Novels.shared.firstMention(self.novel.id, names: names), f.num != was else { return }
            self.library("wirdNovelCharFirst(b, c, n, w)", ["b": b, "c": cid, "n": f.num, "w": was]) { v in
                guard NovelBridge.num(v) == 1 else { return }
                self.toast("أول ذكر لها: الفصل \(f.num)" + (f.sure ? "" : " (من الفصول المحفوظة)"))
                self.loadLabels()
            }
        }
    }

    func sheetHost<V: View>(_ v: V, large: Bool = false) -> UIViewController {
        let host = UIHostingController(rootView: v.environment(\.layoutDirection, Lang.direction).environment(\.locale, Lang.locale))
        host.overrideUserInterfaceStyle = .dark
        // UIKit's pieces in the sheet (its lists, menus) go the same way as its SwiftUI: when the two disagreed,
        // the lists were drawn mirrored (the owner's iPad)
        if #available(iOS 17.0, *) { host.traitOverrides.layoutDirection = Lang.english ? .leftToRight : .rightToLeft }
        host.modalPresentationStyle = .pageSheet
        if let s = host.sheetPresentationController {
            s.detents = large ? [.large()] : [.medium(), .large()]
            s.prefersGrabberVisible = true
        }
        return host
    }

    // MARK: comments at the end of a chapter

    /// the comments each chapter shows now (saved ones and fresh ones together)
    private var commentShown: [Int: [[String: Any]]] = [:]
    private var commentBusy: Set<Int> = []

    /// Saved comments show at once (also without a connection); the site is asked for new ones, and every comment read is kept.
    private func loadComments(_ chapter: Int, more: Bool) {
        guard let ch = chapters.first(where: { $0.id == chapter }), !commentBusy.contains(chapter) else { return }
        commentBusy.insert(chapter)
        var shown = more ? (commentShown[chapter] ?? []) : []
        if !more {
            if let s = Comments.saved(chapter), !s.items.isEmpty {
                shown = s.items
                call("JR.comments(ch, list, total)", ["ch": chapter, "list": s.items, "total": s.total])
            } else {
                call("JR.comments(ch, null, 0)", ["ch": chapter])
            }
            commentShown[chapter] = shown
        }
        let pageNo = more ? shown.count / 30 + 1 : 1
        let novelID = novel.id
        let before = shown
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.commentBusy.remove(chapter) }
            do {
                let r = try await Comments.load(chapterURL: ch.url, page: pageNo, novel: novelID)
                let known = Set(before.compactMap { $0["id"] as? String })
                let new = r.items.filter { !known.contains(($0["id"] as? String) ?? "") }
                let all = Comments.merge(before, r.items)
                let total = max(r.total, all.count)
                self.commentShown[chapter] = all
                Comments.save(chapter, all, total: total)
                if more {
                    self.call("JR.moreComments(ch, list, total)", ["ch": chapter, "list": new, "total": total])
                } else if before.isEmpty || !new.isEmpty {
                    self.call("JR.comments(ch, list, total)", ["ch": chapter, "list": all, "total": total])
                }
            } catch {
                if more { self.call("JR.moreComments(ch, [], 0)", ["ch": chapter]) }
                else if before.isEmpty { self.call("JR.comments(ch, [], 0)", ["ch": chapter]); self.toast("ما قدرت أجيب التعليقات") }
            }
        }
    }

    // MARK: menu actions (see ReaderMenuView)

    func openContents() {
        closeOverlays()
        setChrome(false)
        let sheet = ContentsSheet(novel: novel, chapters: chapters, current: index, pick: { [weak self] i in
            self?.dismiss(animated: true)
            self?.leaveMark()
            self?.show(i, place: nil)
        }, close: { [weak self] in self?.dismiss(animated: true) })
        present(sheetHost(sheet, large: true), animated: true)
    }

    // MARK: the book's notebook in the reader («دفتر الرواية», reader 2.3)

    var notebookTitle: String { novel.source == "epub" ? "دفتر الكتاب" : "دفتر الرواية" }
    var searchTitle: String { novel.source == "epub" ? "بحث في الكتاب" : "بحث في الرواية" }

    /// Everything kept from this book: highlights (a quote's highlight counts as the quote), quotes, thoughts, words,
    /// characters, bookmarks.
    var notebookCount: Int {
        guard let b = bookID, let book = Library.shared.state.book(b) else { return marksHere.count + bookmarks.count }
        return book.plainMarks.count + book.quotes.count + book.thoughts.count + book.words.count + book.chars.count + book.bmarks.count
    }

    /// The book's list: one list of what is kept from it, filtered by kind, live from the library.
    func openNotebookList(filter: String = "all") {
        closeOverlays()
        setChrome(false)
        guard let b = bookID else { toast("افتح الرواية من مكتبتك عشان تنحفظ في دفترها"); return }
        let sheet = ReaderNotebookSheet(bookID: b, title: novel.title, chapters: chapters, labels: labelNames, bookmarkedHere: bookmarkedHere, filter: filter,
            open: { [weak self] ch, p in
                self?.dismiss(animated: true)
                self?.jump(chapter: ch, paragraph: p)
            }, editNote: { [weak self] m in
                self?.editNote(m)
            }, editItem: { [weak self] k, id in
                self?.editItem(kind: k, id: id)
            }, openCharacter: { [weak self] id in
                self?.openCharacterCard(id)
            }, add: { [weak self] k in
                self?.addFromList(k)
            }, toNotebook: { [weak self] in
                // out of the reader, to the notebook tab at this book
                guard let self = self else { return }
                self.dismiss(animated: true) {
                    self.closeTapped()
                    Router.shared.openNotebook(book: b, kind: nil)
                }
            })
        let host = sheetHost(sheet, large: true)
        // a character's card edited from the list: its name shows in the page once it closes
        host.presentationController?.delegate = self
        present(host, animated: true)
    }

    /// The list's +: a bookmark here, or an entry at this chapter without a selection (a thought about it, a character).
    private func addFromList(_ kind: String) {
        if kind == "bmark" {
            if !bookmarkedHere { toggleBookmark() }
            return
        }
        guard chapters.indices.contains(index) else { return }
        let here: [String: Any] = ["ch": chapters[index].id, "p": NovelBridge.num(lastPos["p"]), "s": 0]
        openNotebook(kind: kind, text: "", sentence: "", at: here)
    }

    // MARK: the menu's items (reader 2.4: ReaderMenuView draws them where the owner put them, ReaderMenuEditor.swift)

    var isEpub: Bool { novel.source == "epub" }

    /// Whether an item has something to do in this book (the chapter's site and link are not an EPUB's; a second
    /// source only when the novel has one; comments only where the site has them).
    func menuOffers(_ i: ReaderMenuItem) -> Bool {
        switch i {
        case .site, .refetch, .share: return !isEpub
        case .mirror: return !isEpub && !Novels.shared.mirrors(novel.id).isEmpty
        case .comments: return novel.source == "kolnovel" && settings.prefs.comments
        case .chapters: return chapters.count > 1
        default: return true
        }
    }

    /// a switch that is on now (lit in the menu)
    func menuIsOn(_ i: ReaderMenuItem) -> Bool {
        switch i {
        case .bookmark: return bookmarkedHere
        case .guide: return guideOn
        case .autoScroll: return autoScrolling
        case .lock: return orientationLocked
        default: return false
        }
    }

    func menuSymbol(_ i: ReaderMenuItem) -> String {
        switch i {
        case .bookmark: return bookmarkedHere ? "bookmark.fill" : "bookmark"
        case .autoScroll: return autoScrolling ? "pause.circle" : "play.circle"
        case .pageStyle: return pageStyle.icon
        default: return i.symbol
        }
    }

    /// the small number beside a row's words: how far into the novel, what the notebook holds, this novel's rules
    func menuDetail(_ i: ReaderMenuItem) -> String? {
        switch i {
        case .contents: return progressText
        case .notebook:
            let n = notebookCount
            return n > 0 ? "\(n)" : nil
        case .rules:
            let n = Replacer.rules(String(novel.id)).filter(\.on).count
            return n > 0 ? "\(n)" : nil
        default: return nil
        }
    }

    /// What an item does. An action or a switch closes the menu first; an adjustment is made in place (its row,
    /// button or submenu does it) and leaves the menu open.
    func menuAction(_ i: ReaderMenuItem) {
        if i.kind != .adjust { closeOverlays() }
        switch i {
        case .contents: openContents()
        case .notebook: openNotebookList()
        case .aloud: startReadAloud()
        case .rules: openRules(seed: "")
        case .themes: openThemes()
        case .chapters: askChapter()
        case .search: openSearch()
        case .bookmark: toggleBookmark()
        case .guide: toggleGuide()
        case .autoScroll: toggleAutoScroll()
        case .lock: toggleLock()
        case .site: openSite()
        case .mirror: chapterFromMirror()
        case .refetch: refetch()
        case .share: share()
        case .comments: openComments()
        case .reading: setChrome(false); openReading()
        case .customize: setChrome(false); openCustomize()
        case .theme, .brightness, .fontSize, .pageStyle: break
        }
    }

    /// The chapter before or after, from the menu's chapter bar.
    func menuTurn(_ step: Int) {
        closeOverlays()
        turn(step)
    }

    func stepFont(_ d: Double) {
        settings.edit { $0.size += d }
        Haptics.play("sel")
    }

    /// The screen's brightness (the themes panel's slider, the menu's row and button).
    var brightness: CGFloat {
        get { (view.window?.windowScene?.screen ?? UIScreen.main).brightness }
        set { (view.window?.windowScene?.screen ?? UIScreen.main).brightness = newValue }
    }

    /// «690 من 2334», as the chapter bar and the pill under the page say it
    var chapterPosition: String {
        guard chapters.indices.contains(index) else { return "" }
        let ch = chapters[index]
        if ch.numbered, let last = chapters.last(where: { $0.numbered }) { return "\(ch.num) من \(last.num)" }
        return "\(index + 1) من \(chapters.count)"
    }

    /// The ways pages can move here: the novels' five, or an EPUB's three.
    var pageStyles: [ReaderPageStyle] {
        let p = settings.prefs
        let s = settings
        if isEpub {
            return [
                ReaderPageStyle(name: "تمرير متصل", icon: "arrow.down.to.line.compact", on: p.epubMode == "continuous") { s.prefs.epubMode = "continuous" },
                ReaderPageStyle(name: "تمرير لكل قسم", icon: "scroll", on: p.epubMode == "chapter") { s.prefs.epubMode = "chapter" },
                ReaderPageStyle(name: "تقليب", icon: "book.pages", on: p.epubMode == "paged") { s.prefs.epubMode = "paged" }
            ]
        }
        return ThemesSheet.modes.map { m in
            ReaderPageStyle(name: m.name, icon: m.icon, on: p.mode == m.id && (m.anim == nil || p.anim == m.anim)) {
                s.prefs.mode = m.id
                if let a = m.anim { s.prefs.anim = a }
            }
        }
    }

    var pageStyle: ReaderPageStyle {
        pageStyles.first(where: \.on) ?? pageStyles[0]
    }

    /// The menu of an adjustment: the theme, the brightness, the font size, how pages move. Picked from a round
    /// button or from «المزيد»; the reader's menu stays open.
    func quickMenu(_ i: ReaderMenuItem) -> UIMenu {
        let title = i.title(epub: isEpub).tr
        let image = UIImage(systemName: menuSymbol(i))
        switch i {
        case .theme:
            return UIMenu(title: title, subtitle: settings.current.name.tr, image: image, options: .singleSelection, children: settings.themes.map { t in
                UIAction(title: t.name.tr, state: t.id == settings.currentID ? .on : .off) { [weak self] _ in
                    self?.settings.select(t.id)
                    Haptics.play("sel")
                }
            })
        case .brightness:
            let now = Double(brightness).isFinite ? Double(brightness) : 1
            let levels: [Double] = [1, 0.75, 0.5, 0.3, 0.15, 0.05]
            let near = levels.min { abs($0 - now) < abs($1 - now) } ?? 1
            return UIMenu(title: title, subtitle: "\(Int((now * 100).rounded()))٪".tr, image: image, options: .singleSelection, children: levels.map { l in
                UIAction(title: "\(Int((l * 100).rounded()))٪".tr, state: l == near ? .on : .off) { [weak self] _ in self?.brightness = CGFloat(l) }
            })
        case .fontSize:
            let now = Int(settings.current.size)
            let sizes = Set(stride(from: 14, through: 36, by: 2)).union([now]).sorted()
            return UIMenu(title: title, subtitle: "\(now)", image: image, options: .singleSelection, children: sizes.map { n in
                UIAction(title: "\(n)", state: n == now ? .on : .off) { [weak self] _ in self?.settings.edit { $0.size = Double(n) } }
            })
        default:
            return UIMenu(title: title, subtitle: pageStyle.name.tr, image: image, options: .singleSelection, children: pageStyles.map { m in
                UIAction(title: m.name.tr, image: UIImage(systemName: m.icon), state: m.on ? .on : .off) { _ in m.pick() }
            })
        }
    }

    /// «المزيد»: what the owner put there, then whatever the menu had no room for (rows on a short screen, round
    /// buttons past six), with a line between kinds; «خصّص القائمة» always last.
    func moreMenu(_ spill: [ReaderMenuItem] = []) -> UIMenu {
        let list = (spill + ReaderMenuLayout.current.more).filter { menuOffers($0) }
        var groups: [UIMenuElement] = []
        var run: [UIMenuElement] = []
        var last: ReaderMenuItem.Group?
        for i in list {
            if let g = last, g != i.group, !run.isEmpty {
                groups.append(UIMenu(title: "", options: .displayInline, children: run))
                run = []
            }
            last = i.group
            run += menuElements(i)
        }
        if !run.isEmpty { groups.append(UIMenu(title: "", options: .displayInline, children: run)) }
        let edit = UIAction(title: "خصّص القائمة".tr, image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.openMenuEditor() }
        groups.append(UIMenu(title: "", options: .displayInline, children: [edit]))
        return UIMenu(title: "", children: groups)
    }

    private func menuElements(_ i: ReaderMenuItem) -> [UIMenuElement] {
        switch i {
        case .chapters:
            return [
                UIAction(title: "الفصل التالي".tr, image: UIImage(systemName: bookRTL ? "chevron.left" : "chevron.right")) { [weak self] _ in self?.menuTurn(1) },
                UIAction(title: "الفصل السابق".tr, image: UIImage(systemName: bookRTL ? "chevron.right" : "chevron.left")) { [weak self] _ in self?.menuTurn(-1) },
                UIAction(title: "اذهب لفصل…".tr, image: UIImage(systemName: "number")) { [weak self] _ in self?.menuAction(.chapters) }
            ]
        case .theme, .brightness, .fontSize, .pageStyle:
            return [quickMenu(i)]
        default:
            return [UIAction(title: i.title(epub: isEpub).tr, image: UIImage(systemName: menuSymbol(i)), state: menuIsOn(i) ? .on : .off) { [weak self] _ in
                self?.menuAction(i)
            }]
        }
    }

    /// «خصّص القائمة», over the page. Closing it shows the menu as it is now, to see the change at once.
    func openMenuEditor() {
        closeOverlays()
        setChrome(false)
        let editor = MenuEditorView(epub: isEpub, bookRTL: bookRTL, close: { [weak self] in
            self?.dismiss(animated: true) {
                self?.setChrome(true)
                self?.openMenu()
            }
        })
        let host = UIHostingController(rootView: editor)
        // its list (UIKit underneath) goes the app's way, whatever the phone's language is
        if #available(iOS 17.0, *) { host.traitOverrides.layoutDirection = Lang.english ? .leftToRight : .rightToLeft }
        presentPanel(host, height: 640, tall: true)
    }

    /// «اذهب لفصل»: a chapter by its number (the chapter bar's number, the pill under the page).
    func askChapter() {
        closeOverlays()
        guard chapters.count > 1 else { return }
        let last = chapters.last(where: { $0.numbered })?.num ?? "\(chapters.count)"
        let first = chapters.first(where: { $0.numbered })?.num ?? "1"
        let a = UIAlertController(title: "اذهب لفصل".tr, message: "رقم الفصل، من \(first) إلى \(last)".tr, preferredStyle: .alert)
        a.addTextField { f in
            f.keyboardType = .numberPad
            f.textAlignment = .center
            f.placeholder = self.chapters.indices.contains(self.index) ? self.chapters[self.index].num : ""
        }
        a.addAction(UIAlertAction(title: "إلغاء".tr, style: .cancel))
        a.addAction(UIAlertAction(title: "اذهب".tr, style: .default) { [weak self, weak a] _ in
            self?.goToChapter(number: a?.textFields?.first?.text ?? "")
        })
        present(a, animated: true)
    }

    /// The chapter with that number (written in any digits), or the n-th one when none is numbered so.
    func goToChapter(number raw: String) {
        let digits: [Character: Character] = ["٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4", "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9",
                                              "۰": "0", "۱": "1", "۲": "2", "۳": "3", "۴": "4", "۵": "5", "۶": "6", "۷": "7", "۸": "8", "۹": "9"]
        let s = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).map { digits[$0] ?? $0 })
        guard !s.isEmpty, s.count <= 9 else { return }
        var at = chapters.firstIndex { $0.numbered && $0.num == s }
        if at == nil, let n = Int(s) {
            at = chapters.firstIndex { Int($0.num) == n } ?? (chapters.indices.contains(n - 1) ? n - 1 : nil)
        }
        guard let i = at else { toast("ما لقيت الفصل \(s)"); return }
        if i != index { goTo(chapterIndex: i) }
    }

    /// «قفل الاتجاه الرأسي» from the menu (the same setting as in إعدادات القراءة).
    private func toggleLock() {
        let on = !orientationLocked
        DB.shared.set("reader.lock", on ? "1" : nil)
        NotificationCenter.default.post(name: .readerLockChanged, object: nil)
        toast(on ? "قفل الاتجاه الرأسي: مشغّل" : "قفل الاتجاه الرأسي: متوقف")
    }

    /// «تعليقات الفصل»: to the end of the chapter, where its comments are, and they come.
    private func openComments() {
        guard chapters.indices.contains(index) else { return }
        let id = chapters[index].id
        call("JR.goTo(pos)", ["pos": ["id": id, "end": true] as [String: Any]])
        loadComments(id, more: false)
    }

    /// This novel's replacement rules over the page; with `seed` (a selected word), its rule already started.
    func openRules(seed: String) {
        closeOverlays()
        setChrome(false)
        let sheet = RulesSheet(novelID: novel.id, seed: seed, close: { [weak self] in self?.dismiss(animated: true) })
        presentPanel(UIHostingController(rootView: sheet), height: 440, tall: true)
    }

    var autoScrolling: Bool { autoPill != nil }

    func jump(chapter: Int, paragraph: Int) {
        guard let i = chapters.firstIndex(where: { $0.id == chapter }) else { return }
        leaveMark()
        if i == index, !continuous { call("JR.goTo(pos)", ["pos": ["id": chapter, "p": paragraph, "o": 0]]); return }
        show(i, place: ["p": paragraph, "o": 0])
    }

    func openSearch() {
        closeOverlays()
        setChrome(false)
        let sheet = SearchSheet(novel: novel, chapters: chapters, title: searchTitle) { [weak self] chapterID, term, nth in
            guard let self = self else { return }
            self.dismiss(animated: true)
            guard let i = self.chapters.firstIndex(where: { $0.id == chapterID }) else { return }
            self.leaveMark()
            if i == self.index && !self.continuous {
                self.call("JR.find(q, n)", ["q": term, "n": nth])
            } else {
                self.show(i, place: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.call("JR.find(q, n)", ["q": term, "n": nth]) }
            }
        }
        present(sheetHost(sheet, large: true), animated: true)
    }

    /// The themes panel covers the lower half and leaves the page visible behind it, so every change shows on the real text.
    func openThemes() {
        closeOverlays()
        setChrome(false)
        // one sheet: the panel, and its pages pushed over it (back to the panel, «تم» closes all of it)
        weak var hostRef: UIViewController?
        let panel = ThemesSheet(settings: settings, novelID: novel.id, close: { [weak self] in self?.dismiss(animated: true) }, expand: {
            guard let s = hostRef?.sheetPresentationController else { return }
            s.animateChanges { s.selectedDetentIdentifier = .large }
        })
        let host = UIHostingController(rootView: panel)
        hostRef = host
        presentPanel(host, height: 480, tall: true)
    }

    func openReading() {
        let panel = ReadingSheet(settings: settings, novelID: novel.id, close: { [weak self] in self?.dismiss(animated: true) })
        presentPanel(UIHostingController(rootView: panel), height: 440, tall: true)
    }

    func openCustomize() {
        let panel = CustomizeSheet(settings: settings, close: { [weak self] in self?.dismiss(animated: true) })
        presentPanel(UIHostingController(rootView: panel), height: 440, tall: true)
    }

    private func presentPanel(_ host: UIViewController, height: CGFloat, tall: Bool) {
        host.overrideUserInterfaceStyle = .dark
        host.modalPresentationStyle = .pageSheet
        if let s = host.sheetPresentationController {
            let id = UISheetPresentationController.Detent.Identifier("jalees.half")
            let half = UISheetPresentationController.Detent.custom(identifier: id) { ctx in min(height, ctx.maximumDetentValue * 0.68) }
            s.detents = tall ? [half, .large()] : [half]
            s.largestUndimmedDetentIdentifier = id
            s.prefersGrabberVisible = tall
            s.prefersScrollingExpandsWhenScrolledToEdge = false
            s.preferredCornerRadius = 30
        }
        present(host, animated: true)
    }

    /// A highlighted passage with the novel's name, to send or save.
    func shareQuote(_ text: String, chapter: String) {
        closeOverlays()
        let body = "«\(text)»\n— \(novel.title)" + (chapter.isEmpty ? "" : "، \(chapter)")
        let av = UIActivityViewController(activityItems: [body], applicationActivities: nil)
        av.popoverPresentationController?.sourceView = view
        present(av, animated: true)
    }

    func share() {
        closeOverlays()
        guard chapters.indices.contains(index), let u = URL(string: chapters[index].url) else { return }
        let av = UIActivityViewController(activityItems: ["\(novel.title) · \(chapters[index].line)", u], applicationActivities: nil)
        av.popoverPresentationController?.sourceView = menuButton
        present(av, animated: true)
    }

    /// «قفل الاتجاه الرأسي» is a reading setting now (it was a button in the menu): the reader follows it at once.
    @objc private func lockChanged() {
        orientationLocked = DB.shared.get("reader.lock") == "1"
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    // MARK: the page follows the library

    /// what the page last drew of this book's highlights and bookmarks (a change elsewhere draws them again)
    private var marksSeen = 0

    private func marksSignature() -> Int {
        guard let b = bookID, let book = Library.shared.state.book(b) else { return 0 }
        var h = Hasher()
        for m in book.marks {
            for k in ["id", "color", "style", "note", "item"] { h.combine(m.str(k)) }
            for k in ["ch", "p", "s", "pe", "e"] { h.combine(m.int(k)) }
        }
        for m in book.bmarks { h.combine(m.str("id")) }
        return h.finalize()
    }

    /// A highlight changed, made or deleted outside the page (the notebook, the book's list, a form over the page):
    /// the chapters on the page are drawn with the library's highlights.
    private func libraryChanged() {
        guard pageReady, let b = bookID else { return }
        let sig = marksSignature()
        guard sig != marksSeen else { return }
        marksSeen = sig
        for ch in loadedInPage {
            call("JR.setMarks(ch, l)", ["ch": ch, "l": NovelLibrary.marks(b, chapter: ch).marks])
        }
        refreshBookmarks()
    }

    func toggleGuide() {
        closeOverlays()
        guideOn.toggle()
        call("JR.lineGuide(o)", ["o": ["on": guideOn, "dim": settings.prefs.guideDim, "lines": settings.prefs.guideLines]])
        toast(guideOn ? "دليل السطر: مشغّل" : "دليل السطر: متوقف")
        if guideOn {
            let b = GlassButton(symbol: "text.line.first.and.arrowtriangle.forward")
            b.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(b)
            NSLayoutConstraint.activate([
                b.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor, constant: 14),
                b.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2),
                b.widthAnchor.constraint(equalToConstant: 44), b.heightAnchor.constraint(equalToConstant: 44)
            ])
            b.button.showsMenuAsPrimaryAction = true
            b.button.menu = guideMenu()
            b.button.accessibilityLabel = "دليل السطر".tr
            guideButton = b
        } else {
            guideButton?.removeFromSuperview()
            guideButton = nil
        }
        jumpLeft?.constant = guideOn ? 66 : 14
    }

    private func guideMenu() -> UIMenu {
        let p = settings.prefs
        let dims: [(String, Double)] = [("مرتفع", 0.82), ("متوسط", 0.62), ("منخفض", 0.4), ("لا شيء", 0)]
        let dim = UIMenu(title: "تعتيم الخلفية".tr, options: .displayInline, children: dims.map { item in
            UIAction(title: item.0, state: abs(p.guideDim - item.1) < 0.05 ? .on : .off) { [weak self] _ in self?.settings.prefs.guideDim = item.1; self?.regGuide() }
        })
        let lines = UIMenu(title: "ارتفاع الشريط".tr, options: .displayInline, children: [1, 2, 3].map { n in
            UIAction(title: n == 1 ? "سطر واحد" : (n == 2 ? "سطرين" : "3 أسطر"), state: p.guideLines == n ? .on : .off) { [weak self] _ in self?.settings.prefs.guideLines = n; self?.regGuide() }
        })
        let off = UIAction(title: "إيقاف دليل السطر".tr, image: UIImage(systemName: "xmark")) { [weak self] _ in self?.toggleGuide() }
        return UIMenu(children: [dim, lines, off])
    }

    private func regGuide() {
        call("JR.lineGuide(o)", ["o": ["on": true, "dim": settings.prefs.guideDim, "lines": settings.prefs.guideLines]])
        guideButton?.button.menu = guideMenu()
    }

    func toggleAutoScroll() {
        closeOverlays()
        if let p = autoPill {
            p.removeFromSuperview()
            autoPill = nil
            call("JR.autoScroll(0)")
            return
        }
        guard !paged else { toast("التمرير التلقائي يشتغل مع طريقة التمرير"); return }
        let p = AutoScrollPill(speed: settings.prefs.autoSpeed, change: { [weak self] speed, playing in
            self?.settings.prefs.autoSpeed = speed
            self?.call("JR.autoScroll(s)", ["s": playing ? speed : 0])
        }, close: { [weak self] in self?.toggleAutoScroll() })
        p.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(p)
        NSLayoutConstraint.activate([
            p.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            p.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -56)
        ])
        autoPill = p
        call("JR.autoScroll(s)", ["s": settings.prefs.autoSpeed])
        setChrome(false)
    }

    func openSite() {
        closeOverlays()
        guard chapters.indices.contains(index) else { return }
        NovelBridge.openSite(chapters[index].url)
    }

    func refetch() {
        closeOverlays()
        show(index, place: nil, refresh: true)
    }

    func goTo(chapterIndex i: Int) { leaveMark(); show(i, place: nil) }

    /// Where you were before jumps, like a browser: back to each place in turn, and forward again after going back.
    /// Two small pills at the bottom corner, each with the chapter's number.
    private var backStack: [(i: Int, p: Int, o: Double)] = []
    private var fwdStack: [(i: Int, p: Int, o: Double)] = []
    private let backPill = GlassButton(symbol: "arrow.uturn.backward", size: 11)
    private let fwdPill = GlassButton(symbol: "arrow.uturn.forward", size: 11)
    private var backWidth: NSLayoutConstraint?
    private var jumpLeft: NSLayoutConstraint?
    private var fwdWidth: NSLayoutConstraint?
    private lazy var jumpRow: UIStackView = {
        let s = UIStackView(arrangedSubviews: [backPill, fwdPill])
        s.axis = .horizontal
        s.spacing = 6
        // back first in the book's direction (right in an Arabic book, left in an English one; the "dir" message updates it)
        s.semanticContentAttribute = self.bookRTL ? .forceRightToLeft : .forceLeftToRight
        s.alpha = 0
        return s
    }()

    private var hasJumps: Bool { !backStack.isEmpty || !fwdStack.isEmpty }
    /// the pills go away two minutes after the last jump
    private var jumpExpiry: DispatchWorkItem?
    private var herePlace: (i: Int, p: Int, o: Double) { (index, NovelBridge.num(lastPos["p"]), (lastPos["o"] as? Double) ?? 0) }

    func leaveMark() {
        guard chapters.indices.contains(index) else { return }
        backStack.append(herePlace)
        if backStack.count > 30 { backStack.removeFirst() }
        fwdStack.removeAll()
        updateJumps()
    }

    private func updateJumps() {
        if jumpRow.superview == nil {
            jumpRow.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(jumpRow)
            backWidth = backPill.widthAnchor.constraint(equalToConstant: 56)
            fwdWidth = fwdPill.widthAnchor.constraint(equalToConstant: 56)
            jumpLeft = jumpRow.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor, constant: 14)
            NSLayoutConstraint.activate([
                jumpLeft!,
                jumpRow.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
                backPill.heightAnchor.constraint(equalToConstant: 30), fwdPill.heightAnchor.constraint(equalToConstant: 30),
                backWidth!, fwdWidth!
            ])
            for (p, sel) in [(backPill, #selector(goBackTo)), (fwdPill, #selector(goForward))] {
                p.button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
                p.button.addTarget(self, action: sel, for: .touchUpInside)
            }
        }
        func num(_ i: Int) -> String { chapters.indices.contains(i) ? (chapters[i].numbered ? chapters[i].num : "\(i + 1)") : "" }
        func set(_ p: GlassButton, _ w: NSLayoutConstraint?, _ place: (i: Int, p: Int, o: Double)?, _ say: String) {
            p.isHidden = place == nil
            guard let x = place else { return }
            p.button.setTitle(" " + num(x.i), for: .normal)
            p.button.accessibilityLabel = say + " " + num(x.i)
            w?.constant = ceil(p.button.intrinsicContentSize.width) + 22
        }
        jumpLeft?.constant = guideOn ? 66 : 14
        jumpExpiry?.cancel()
        if hasJumps {
            let w = DispatchWorkItem { [weak self] in
                self?.backStack.removeAll()
                self?.fwdStack.removeAll()
                self?.updateJumps()
            }
            jumpExpiry = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: w)
        }
        set(backPill, backWidth, backStack.last, "رجوع للفصل")
        set(fwdPill, fwdWidth, fwdStack.last, "تقدّم للفصل")
        UIView.animate(withDuration: 0.2) { self.jumpRow.alpha = self.chromeShown && self.hasJumps ? 1 : 0 }
    }

    @objc private func goBackTo() {
        guard let b = backStack.popLast() else { return }
        fwdStack.append(herePlace)
        updateJumps()
        Haptics.play("sel")
        show(b.i, place: ["p": b.p, "o": b.o])
    }

    @objc private func goForward() {
        guard let f = fwdStack.popLast() else { return }
        backStack.append(herePlace)
        updateJumps()
        Haptics.play("sel")
        show(f.i, place: ["p": f.p, "o": f.o])
    }

    var progressText: String {
        chapters.count > 1 ? "\(Int((Double(index) / Double(chapters.count - 1) * 100).rounded()))٪" : "0٪"
    }

    var markCount: Int { marksHere.count + bookmarks.count }

    // MARK: the session

    private func activity() {
        lastActivity = Date()
        if !running { running = true; lastTick = Date() }
    }

    private func tick() {
        let now = Date()
        if running {
            activeSeconds += now.timeIntervalSince(lastTick)
            if now.timeIntervalSince(lastActivity) > 180 {
                // three still minutes: stop, and keep only the first of them
                running = false
                activeSeconds = max(0, activeSeconds - 120)
            }
        }
        lastTick = now
    }

    /// Asks the page where it is and keeps that (the page reports a place only when it stops, so the last one can be a moment old).
    private func savePlaceNow() {
        let nid = novel.id, ids = Set(chapters.map(\.id))
        ask("JR.where()") { v in
            guard let w = v as? [String: Any] else { return }
            let id = NovelBridge.num(w["id"])
            guard ids.contains(id) else { return }
            Novels.shared.savePlace(novel: nid, chapter: id, p: NovelBridge.num(w["p"]), o: (w["o"] as? Double) ?? 0)
        }
    }

    @objc private func wentAway() {
        if pageReady { savePlaceNow() }
        tick()
        running = false
    }

    @objc private func cameBack() {
        lastTick = Date()
        activity()
    }

    private func endSession() {
        tick()
        clock?.invalidate()
        let minutes = activeSeconds / 60
        let readNow = chapters.filter(\.read).count
        guard let b = bookID, minutes >= 0.5 else { return }
        let o: [String: Any] = ["book": b, "start": sessionStart.timeIntervalSince1970 * 1000, "minutes": minutes,
                                "units": max(0, readNow - readAtStart), "from": readAtStart, "to": readNow]
        library("wirdNovelSession(o)", ["o": o])
        let m = Int(minutes.rounded())
        let ch = max(0, readNow - readAtStart)
        let text = (m < 1 ? "أقل من دقيقة" : (m == 1 ? "دقيقة" : "\(m) دقيقة")) + (ch > 0 ? " · " + (ch == 1 ? "فصل" : "\(ch) فصول") : "")
        Toaster.show("جلسة قراءة: " + text)
    }

    func toast(_ s: String) { Toast.show(s, in: view, top: 64) }

    // MARK: test hooks (launch argument -JaleesRoute)

    func debug(_ what: String) {
        NSLog("jalees debug: %@ (in window: %@)", what, view.window == nil ? "no" : "yes")
        switch what {
        case "chrome": setChrome(true)
        case "menu": setChrome(true); openMenu()
        case "menuedit": openMenuEditor()
        case "menucustom":
            // every kind of item at once, shown and not saved: the quick rows (theme, brightness, size, page style), the
            // chapter bar, five round buttons, the scrubber
            ReaderMenuLayout.preview = ReaderMenuLayout(rows: [.contents, .theme, .brightness, .fontSize, .pageStyle, .chapters],
                                                        buttons: [.aloud, .search, .bookmark, .guide, .autoScroll], more: [], hidden: [], scrubber: true).completed()
            setChrome(true)
            openMenu()
        case "rules": openRules(seed: "سالم")
        case "notes":
            // a highlight with a note made from a selection, then the book's list showing it
            call("(function(){var p=document.querySelector('.body p[data-i=\"2\"]');var r=document.createRange();r.setStart(p.firstChild,3);r.setEnd(p.firstChild,30);getSelection().removeAllRanges();getSelection().addRange(r)})()")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.ask("JR.selection()") { v in
                    guard var s = v as? [String: Any] else { return }
                    for k in ["rect", "merge", "drop"] { s.removeValue(forKey: k) }
                    self.call("JR.clearSelection()")
                    var m: [String: Any] = ["id": UUID().uuidString, "color": "purple", "style": "hl", "note": "ملاحظة تجربة على هذا السطر"]
                    for k in ["ch", "chLabel", "p", "s", "pe", "e", "text"] { m[k] = s[k] }
                    self.saveMark(m)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.openNotebookList() }
                }
            }
        case "themes": openThemes()
        case "custom": openCustomize()
        case "reading": openReading()
        case "contents": openContents()
        case "end": call("JR.goTo({end:true})")
        case "paged":
            settings.prefs.mode = "paged"; settings.prefs.anim = "slide"
        case "curl":
            settings.prefs.mode = "paged"; settings.prefs.anim = "curl"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.curl(1) }
        case "marks": openNotebookList()
        case "search": openSearch()
        case "guide": toggleGuide()
        case "jumps":
            // two jumps, then one step back: both pills show (back to the first place, forward to the last)
            goTo(chapterIndex: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.goTo(chapterIndex: 4) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { self.goBackTo() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { self.setChrome(true) }
        case "first":
            // where «سالم» is first named, among the chapters saved so far
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let f = await Novels.shared.firstMention(self.novel.id, names: ["سالم"])
                let a = UIAlertController(title: f.map { "أول ذكر لسالم: الفصل \($0.num)" + ($0.sure ? " (أكيد)" : " (من المحفوظ)") } ?? "ما لقيت سالم", message: nil, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "تمام".tr, style: .cancel))
                self.present(a, animated: true)
            }
        case "tts":
            // reading aloud from the top of the chapter, with the player
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.startReadAloud(chapter: self.index, para: 0) }
        case "swipe":
            // continuous reading: the next chapter, from its heading
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.turn(1) }
        case "quote":
            call("(function(){var p=document.querySelector('.body p[data-i=\"0\"]');var r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,24);getSelection().removeAllRanges();getSelection().addRange(r)})()")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.fromSelection("quote") }
        case "mark":
            call("(function(){var p=document.querySelector('.body p[data-i=\"2\"]');var r=document.createRange();r.setStart(p.firstChild,3);r.setEnd(p.firstChild,30);getSelection().removeAllRanges();getSelection().addRange(r)})()")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.fromSelection("highlight") }
        default: break
        }
    }
}

/// One still picture of a page, for the curl.
private final class SnapPage: UIViewController {
    private let image: UIImage
    init(_ image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("no storyboard") }
    override func loadView() {
        let v = UIImageView(image: image)
        v.contentMode = .scaleToFill
        view = v
    }
}

/// The page holds its message handler strongly; this keeps the screen itself free to go away.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

extension ReaderViewController: UIAdaptivePresentationControllerDelegate {
    /// A card or sheet over the page was swiped away: what it changed (a character's name) shows in the page.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { loadLabels() }
}
