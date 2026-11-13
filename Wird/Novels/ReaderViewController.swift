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

    private var mainWeb: WKWebView? { NovelBridge.host?.webView }
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
        buildChrome()
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
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
        closeButton.button.accessibilityLabel = "إغلاق"
        menuButton.button.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        menuButton.button.accessibilityLabel = "القائمة"
    }

    // MARK: talking to the page and to the library

    func call(_ body: String, _ args: [String: Any] = [:], done: ((Any?) -> Void)? = nil) {
        web.jalees(body + "; return 1", args, done: done)
    }

    func ask(_ body: String, _ args: [String: Any] = [:], done: @escaping (Any?) -> Void) {
        web.jalees("return " + body, args, done: done)
    }

    /// Runs something in the library (the main web app), where the book's highlights and notebook live.
    func library(_ body: String, _ args: [String: Any] = [:], done: ((Any?) -> Void)? = nil) {
        guard let w = mainWeb else { done?(nil); return }
        w.jalees("return " + body, args, done: done)
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
        guard let b = bookID, let w = mainWeb else { return ([], []) }
        return await withCheckedContinuation { c in
            w.jalees("return wirdNovelMarks(b, ch)", ["b": b, "ch": chapter]) { v in
                let d = v as? [String: Any]
                c.resume(returning: ((d?["marks"] as? [[String: Any]]) ?? [], (d?["bmarks"] as? [[String: Any]]) ?? []))
            }
        }
    }

    func show(_ i: Int, place given: [String: Any]?, refresh: Bool = false) {
        guard chapters.indices.contains(i) else { return }
        var place = given
        if place == nil, let saved = Novels.shared.place(in: chapters[i].id) { place = ["p": saved.p, "o": saved.o] }
        index = i
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
            guard let self = self, let o = try? await self.payload(j) else { return }
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
                // continuous reading moved into another chapter: the one before it is read
                if i > index { markRead(index) }
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
            let x = (o["x"] as? Double) ?? 0.5
            if paged && (x < 0.28 || x > 0.72) {
                turnPage(x < 0.28 ? 1 : -1)
            } else {
                setChrome(!chromeShown)
            }
        case "sel":
            if (o["on"] as? Bool) == true { setChrome(false); closeOverlays() }
        case "markTap":
            openMarkBar(id: o["id"] as? String ?? "", chapter: NovelBridge.num(o["ch"]), rect: rect(o["rect"]))
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
            if step > 0 { self.markRead(at) }
            Haptics.play("sel")
            let id = self.chapters[i].id
            UIView.animate(withDuration: 0.1, animations: { self.web.alpha = 0 }, completion: { _ in
                self.ask("JR.toChapter(id)", ["id": id]) { done in
                    if NovelBridge.num(done) == 1 {
                        self.index = i
                        self.refreshBookmarks()
                        UIView.animate(withDuration: 0.16) { self.web.alpha = 1 }
                    } else {
                        self.show(i, place: ["p": 0, "o": 0])
                    }
                    self.turning = false
                }
            })
        }
    }

    private var turning = false

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
                        pvc.view.semanticContentAttribute = .forceRightToLeft
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
            topPill.text = "الصفحة \(NovelBridge.num(lastPos["page"]) + 1) من \(NovelBridge.num(lastPos["pages"]))"
        } else {
            topPill.text = !known ? ch.label : (pagesLeft == 0 ? "الصفحة الأخيرة في الفصل" : "الصفحات المتبقية في الفصل: \(pagesLeft)")
        }
        if ch.numbered, let last = chapters.last(where: { $0.numbered }) {
            bottomPill.text = "\(ch.num) من \(last.num)"
        } else {
            bottomPill.text = "\(index + 1) من \(chapters.count)"
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
        if x < -60 { turn(1) } else if x > maxX + 60 { turn(-1) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// In a right-to-left book a swipe to the right goes forward.
    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        guard markBar == nil else { return }
        let dir = g.direction == .right ? 1 : -1
        if paged {
            // fade and curl pages turn by swiping (slide pages scroll by themselves)
            if settings.prefs.anim != "slide" { turnPage(dir) }
            return
        }
        guard settings.prefs.swipeChapters else { return }
        turn(dir)
    }

    @objc func closeTapped() {
        endSession()
        onClose?()
        dismiss(animated: true)
    }

    @objc private func menuTapped() {
        if menu != nil { closeOverlays(); return }
        let m = ReaderMenuView(reader: self)
        menu = m
        m.show(in: view, above: menuButton)
        Haptics.play("soft")
    }

    func closeOverlays() {
        menu?.hide(); menu = nil
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
        let hl = UIAction(title: "تظليل", image: UIImage(systemName: "highlighter")?.withTintColor(color.ui, renderingMode: .alwaysOriginal)) { [weak self] _ in self?.fromSelection("highlight") }
        let note = UIAction(title: "ملاحظة", image: UIImage(systemName: "note.text")) { [weak self] _ in self?.fromSelection("note") }
        let nb = UIMenu(title: "للدفتر", image: UIImage(systemName: "book.closed"), children: [
            UIAction(title: "اقتباس", image: UIImage(systemName: "text.quote")) { [weak self] _ in self?.fromSelection("quote") },
            UIAction(title: "خاطرة", image: UIImage(systemName: "lightbulb")) { [weak self] _ in self?.fromSelection("thought") },
            UIAction(title: "كلمة", image: UIImage(systemName: "character.book.closed")) { [weak self] _ in self?.fromSelection("word") },
            UIAction(title: "شخصية", image: UIImage(systemName: "person")) { [weak self] _ in self?.fromSelection("char") },
            UIAction(title: "معلومة", image: UIImage(systemName: "info.circle")) { [weak self] _ in self?.fromSelection("info") }
        ])
        return UIMenu(title: "", options: .displayInline, children: [hl, note, nb])
    }

    private func fromSelection(_ what: String) {
        ask("JR.selection()") { [weak self] v in
            guard let self = self, var s = v as? [String: Any], let text = s["text"] as? String, !text.isEmpty else { return }
            let r = self.rect(s["rect"])
            s.removeValue(forKey: "rect")
            switch what {
            case "highlight", "note", "info":
                let mergeID = s["merge"] as? String
                let drop = (s["drop"] as? [String]) ?? []
                s.removeValue(forKey: "merge")
                s.removeValue(forKey: "drop")
                var m = self.marksHere.first { ($0["id"] as? String) == mergeID } ?? ["id": UUID().uuidString, "color": self.lastColor, "style": "hl", "note": ""]
                for k in ["ch", "chLabel", "p", "s", "pe", "e", "text"] { m[k] = s[k] }
                if what == "info" { m["color"] = self.infoColor }
                for d in drop { if let x = self.marksHere.first(where: { ($0["id"] as? String) == d }) { self.deleteMark(x) } }
                self.call("JR.clearSelection()")
                self.saveMark(m)
                if what == "highlight" { self.openMarkBar(mark: m, rect: r) } else { self.editNote(m) }
            default:
                self.ask("JR.sentence()") { sent in
                    self.call("JR.clearSelection()")
                    self.openNotebook(kind: what, text: text, sentence: (sent as? String) ?? "", at: s)
                }
            }
        }
    }

    /// The colour the owner named «معلومة» (purple until renamed).
    var infoColor: String { labelNames.first { $0.value.trimmingCharacters(in: .whitespaces) == "معلومة" }?.key ?? "purple" }

    func saveMark(_ m: [String: Any]) {
        call("JR.putMark(m)", ["m": m])
        if let b = bookID { library("wirdNovelMark(b, m)", ["b": b, "m": m]) }
        if let c = m["color"] as? String, c != lastColor { lastColor = c; DB.shared.set("reader.lastColor", c) }
        if let i = marksHere.firstIndex(where: { ($0["id"] as? String) == (m["id"] as? String) }) { marksHere[i] = m } else { marksHere.append(m) }
    }

    func deleteMark(_ m: [String: Any]) {
        guard let id = m["id"] as? String else { return }
        call("JR.dropMark(ch, id)", ["ch": NovelBridge.num(m["ch"]), "id": id])
        if let b = bookID { library("wirdNovelMarkDel(b, id)", ["b": b, "id": id]) }
        marksHere.removeAll { ($0["id"] as? String) == id }
        closeOverlays()
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
        let bar = MarkBar(reader: self, mark: mark, labels: labelNames)
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
        sentNames = "\(style)|\(settings.prefs.showNames)"
        call("JR.setNames(l, on, st)", ["l": list, "on": settings.prefs.showNames && style != "off", "st": style])
    }

    private func showCharacter(_ id: String, near r: CGRect) {
        guard let c = characters.first(where: { ($0["id"] as? String) == id }) else { return }
        let name = (c["name"] as? String) ?? ""
        var lines = [name]
        if let a = c["alias"] as? String, !a.isEmpty { lines.append(a) }
        let role = ["main": "شخصية رئيسية", "secondary": "شخصية ثانوية"][(c["role"] as? String) ?? ""]
        if let ro = role { lines.append(ro) }
        if let d = c["desc"] as? String, !d.isEmpty { lines.append(d) }
        let a = UIAlertController(title: name, message: lines.dropFirst().joined(separator: "\n"), preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "افتح بطاقتها في دفتري", style: .default) { [weak self] _ in
            guard let self = self, let b = self.bookID else { return }
            self.closeTapped()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NovelBridge.closePage(animated: false)
                NovelTabs.hide()
                NovelBridge.host?.webView.jalees("return wirdNovelChar(b, c)", ["b": b, "c": id])
            }
        })
        a.addAction(UIAlertAction(title: "تمام", style: .cancel))
        a.popoverPresentationController?.sourceView = view
        a.popoverPresentationController?.sourceRect = r
        present(a, animated: true)
    }

    func editNote(_ m: [String: Any]) {
        closeOverlays()
        let sheet = NoteSheet(text: (m["text"] as? String) ?? "", note: (m["note"] as? String) ?? "") { [weak self] note in
            var x = m
            x["note"] = note
            self?.saveMark(x)
        }
        present(sheetHost(sheet), animated: true)
    }

    func openNotebook(kind: String, text: String, sentence: String, at s: [String: Any]) {
        closeOverlays()
        guard let b = bookID, chapters.indices.contains(index) else { toast("افتح الرواية من مكتبتك عشان تنحفظ في دفترها"); return }
        let ch = chapters.first { $0.id == NovelBridge.num(s["ch"]) } ?? chapters[index]
        let loc = Int(ch.num) ?? (ch.idx + 1)
        let nv: [String: Any] = ["ch": ch.id, "p": NovelBridge.num(s["p"]), "s": NovelBridge.num(s["s"]), "label": ch.line]
        let sheet = NotebookSheet(kind: kind, text: text, sentence: sentence, characters: characters) { [weak self] fields in
            var o = fields
            o["loc"] = loc
            o["nv"] = nv
            if kind == "char", o["first"] == nil { o["first"] = loc }
            self?.library("wirdNovelItem(b, k, o)", ["b": b, "k": kind, "o": o]) { v in
                guard v != nil else { self?.toast("ما انحفظ"); return }
                self?.toast(["quote": "انحفظ الاقتباس", "thought": "انحفظت الخاطرة", "word": "انحفظت الكلمة", "char": "انحفظت الشخصية"][kind] ?? "انحفظ")
                if kind == "char" {
                    self?.loadLabels()
                    if let cid = v as? String, let name = o["name"] as? String { self?.findFirst(cid, names: [name, (o["alias"] as? String) ?? ""], was: loc) }
                }
            }
        }
        present(sheetHost(sheet), animated: true)
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
        let host = UIHostingController(rootView: v.environment(\.layoutDirection, .rightToLeft).environment(\.locale, Locale(identifier: "ar@numbers=latn")))
        host.overrideUserInterfaceStyle = .dark
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

    func openMarks() {
        closeOverlays()
        setChrome(false)
        guard let b = bookID else { return }
        library("wirdNovelAllMarks(b)", ["b": b]) { [weak self] v in
            guard let self = self else { return }
            let d = v as? [String: Any] ?? [:]
            let sheet = MarksSheet(title: self.novel.title, marks: (d["marks"] as? [[String: Any]]) ?? [], bookmarks: (d["bmarks"] as? [[String: Any]]) ?? [],
                                   labels: self.labelNames, open: { [weak self] ch, p in
                self?.dismiss(animated: true)
                self?.jump(chapter: ch, paragraph: p)
            }, deleteMark: { [weak self] id in
                guard let self = self else { return }
                if let b = self.bookID { self.library("wirdNovelMarkDel(b, id)", ["b": b, "id": id]) }
                if self.chapters.indices.contains(self.index) { self.call("JR.dropMark(ch, id)", ["ch": self.chapters[self.index].id, "id": id]) }
            }, deleteBookmark: { [weak self] id in
                guard let self = self, let b = self.bookID else { return }
                self.library("wirdNovelBmarkDel(b, id)", ["b": b, "id": id]) { _ in self.refreshBookmarks() }
            })
            self.present(self.sheetHost(sheet, large: true), animated: true)
        }
    }

    func jump(chapter: Int, paragraph: Int) {
        guard let i = chapters.firstIndex(where: { $0.id == chapter }) else { return }
        leaveMark()
        if i == index, !continuous { call("JR.goTo(pos)", ["pos": ["id": chapter, "p": paragraph, "o": 0]]); return }
        show(i, place: ["p": paragraph, "o": 0])
    }

    func openSearch() {
        closeOverlays()
        setChrome(false)
        let sheet = SearchSheet(novel: novel, chapters: chapters) { [weak self] chapterID, term, nth in
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
        let panel = ThemesSheet(settings: settings, close: { [weak self] in self?.dismiss(animated: true) }, customize: { [weak self] in
            self?.dismiss(animated: true) { self?.openCustomize() }
        }, reading: { [weak self] in
            self?.dismiss(animated: true) { self?.openReading() }
        })
        presentPanel(UIHostingController(rootView: panel), height: 480, tall: false)
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

    var isLocked: Bool { orientationLocked }

    func toggleLock() {
        orientationLocked.toggle()
        DB.shared.set("reader.lock", orientationLocked ? "1" : nil)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        toast(orientationLocked ? "قفل الاتجاه الرأسي: مشغّل" : "قفل الاتجاه الرأسي: متوقف")
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
            b.button.accessibilityLabel = "دليل السطر"
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
        let dim = UIMenu(title: "تعتيم الخلفية", options: .displayInline, children: dims.map { item in
            UIAction(title: item.0, state: abs(p.guideDim - item.1) < 0.05 ? .on : .off) { [weak self] _ in self?.settings.prefs.guideDim = item.1; self?.regGuide() }
        })
        let lines = UIMenu(title: "ارتفاع الشريط", options: .displayInline, children: [1, 2, 3].map { n in
            UIAction(title: n == 1 ? "سطر واحد" : (n == 2 ? "سطرين" : "3 أسطر"), state: p.guideLines == n ? .on : .off) { [weak self] _ in self?.settings.prefs.guideLines = n; self?.regGuide() }
        })
        let off = UIAction(title: "إيقاف دليل السطر", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.toggleGuide() }
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
        s.semanticContentAttribute = .forceRightToLeft
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

    @objc private func wentAway() {
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
        if let host = NovelBridge.host { Toast.show("جلسة قراءة: " + text, in: host.view, bottom: 110) }
    }

    func toast(_ s: String) { Toast.show(s, in: view, top: 64) }

    // MARK: test hooks (launch argument -JaleesRoute)

    func debug(_ what: String) {
        switch what {
        case "chrome": setChrome(true)
        case "menu": setChrome(true); menuTapped()
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
        case "marks": openMarks()
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
                a.addAction(UIAlertAction(title: "تمام", style: .cancel))
                self.present(a, animated: true)
            }
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
