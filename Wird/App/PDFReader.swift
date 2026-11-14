import UIKit
import PDFKit
import UniformTypeIdentifiers

/// كتب PDF (answers-round2 س3): a PDF from the Files app is read where it is (no second copy), becomes a book read by
/// pages with its first page as the cover, and opens in a plain, quiet reader: your page kept, a strip of pages to
/// move through, search, go to a page, and a reading session counted like the novel reader does.
@MainActor
enum PDFBooks {
    private static var picker: Picker?

    static func key(_ bookID: String) -> String { "pdf." + bookID }
    static func isPDF(_ b: Book) -> Bool { b.raw.bool("pdfFile") }

    static func pick() {
        guard let h = NovelBridge.host else { return }
        let p = Picker()
        picker = p
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
        vc.delegate = p
        NovelBridge.top(h).present(vc, animated: true)
    }

    private final class Picker: NSObject, UIDocumentPickerDelegate {
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else { return }
            Task { @MainActor in PDFBooks.add(u); PDFBooks.picker = nil }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { Task { @MainActor in PDFBooks.picker = nil } }
    }

    static func add(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), let mark = try? url.bookmarkData() else { Toaster.show("ما قدرت أفتح الملف"); return }
        let attrs = doc.documentAttributes ?? [:]
        var title = (attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
        var o = Library.blankBook()
        o.set("title", title)
        o.set("author", (attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        o.set("format", "ebook")
        o.set("platform", "ملف PDF")
        o.set("structure", "volume")
        o.set("status", "want")
        o.set("pdfFile", true)
        o["volumes"] = .array([.object(["id": .string(uid()), "title": .string(""), "total": .number(Double(doc.pageCount))])])
        let b = Book(Library.fixBook(o))
        Library.shared.change { $0.books.append(b) }
        DB.shared.set(key(b.id), mark.base64EncodedString())
        if let page = doc.page(at: 0) {
            let img = page.thumbnail(of: CGSize(width: 700, height: 1000), for: .mediaBox)
            NovelLibrary.setCover(b.id, img)
        }
        CarouselCenter.shared.id = b.id
        Toaster.show("انضاف «\(title)»: \(doc.pageCount) صفحة")
        open(b.id)
    }

    static func fileURL(_ bookID: String) -> URL? {
        guard let s = DB.shared.get(key(bookID)), let d = Data(base64Encoded: s) else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: d, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? u.bookmarkData() { DB.shared.set(key(bookID), fresh.base64EncodedString()) }
        return u
    }

    static func open(_ bookID: String) {
        guard let h = NovelBridge.host else { return }
        guard let u = fileURL(bookID) else { Toaster.show("ما لقيت الملف في مكانه، ضيفه مرة ثانية"); return }
        let vc = PDFReaderViewController(bookID: bookID, url: u)
        NovelBridge.top(h).present(vc, animated: true)
    }
}

final class PDFReaderViewController: UIViewController, UIGestureRecognizerDelegate {
    let bookID: String
    let url: URL
    private let pdf = PDFView()
    private let strip = PDFThumbnailView()
    private let top = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let pageLabel = UILabel()
    private var scoped = false
    private var chrome = true
    private var startPage = 0
    private var sessionStart = Date()
    private var active: Double = 0
    private var lastTick = Date()
    private var lastActivity = Date()
    private var clock: Timer?
    private var findAt: PDFSelection?

    init(bookID: String, url: URL) {
        self.bookID = bookID
        self.url = url
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { !chrome }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.1, alpha: 1)
        scoped = url.startAccessingSecurityScopedResource()
        pdf.document = PDFDocument(url: url)
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.backgroundColor = UIColor(white: 0.1, alpha: 1)
        pdf.pageShadowsEnabled = true
        pdf.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdf)

        strip.pdfView = pdf
        strip.layoutMode = .horizontal
        strip.thumbnailSize = CGSize(width: 26, height: 36)
        strip.backgroundColor = UIColor(white: 0.08, alpha: 0.92)
        strip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(strip)

        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return b
        }
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        pageLabel.textColor = .white
        pageLabel.textAlignment = .center
        let row = UIStackView(arrangedSubviews: [button("xmark", "إغلاق") { [weak self] in self?.close() }, pageLabel,
                                                 button("magnifyingglass", "بحث في الملف") { [weak self] in self?.search() },
                                                 button("number", "روح لصفحة") { [weak self] in self?.goToPage() }])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.semanticContentAttribute = .forceLeftToRight
        row.translatesAutoresizingMaskIntoConstraints = false
        top.contentView.addSubview(row)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pdf.topAnchor.constraint(equalTo: view.topAnchor), pdf.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdf.leftAnchor.constraint(equalTo: view.leftAnchor), pdf.rightAnchor.constraint(equalTo: view.rightAnchor),
            top.topAnchor.constraint(equalTo: view.topAnchor), top.leftAnchor.constraint(equalTo: view.leftAnchor), top.rightAnchor.constraint(equalTo: view.rightAnchor),
            top.bottomAnchor.constraint(equalTo: g.topAnchor, constant: 50),
            row.leftAnchor.constraint(equalTo: top.contentView.leftAnchor, constant: 8), row.rightAnchor.constraint(equalTo: top.contentView.rightAnchor, constant: -8),
            row.bottomAnchor.constraint(equalTo: top.contentView.bottomAnchor, constant: -3), row.heightAnchor.constraint(equalToConstant: 44),
            strip.leftAnchor.constraint(equalTo: view.leftAnchor), strip.rightAnchor.constraint(equalTo: view.rightAnchor),
            strip.bottomAnchor.constraint(equalTo: view.bottomAnchor), strip.topAnchor.constraint(equalTo: g.bottomAnchor, constant: -50)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        pdf.addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdf)

        // back to your page
        let b = Library.shared.state.book(bookID)
        let page = max(0, Int(b?.pos ?? 0) - 1)
        startPage = page
        if let p = pdf.document?.page(at: page) { pdf.go(to: p) }
        Library.shared.changeBook(bookID) { x in
            x.opened = Millis.now
            if x.status == .want { x.status = .reading }
            if x.start == nil { x.start = Millis.now }
        }
        clock = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        pageChanged()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tapped() {
        lastActivity = Date()
        chrome.toggle()
        UIView.animate(withDuration: 0.2) {
            self.top.alpha = self.chrome ? 1 : 0
            self.strip.alpha = self.chrome ? 1 : 0
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    @objc private func pageChanged() {
        lastActivity = Date()
        guard let d = pdf.document, let p = pdf.currentPage else { return }
        let i = d.index(for: p)
        pageLabel.text = "ص \(i + 1) / \(d.pageCount)"
        Library.shared.changeBook(bookID) { $0.pos = Double(i + 1) }
    }

    /// Active reading time only: three minutes without a page or a touch stop the clock.
    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastActivity) < 180 { active += now.timeIntervalSince(lastTick) }
        lastTick = now
    }

    private func close() {
        tick()
        clock?.invalidate()
        let b = Library.shared.state.book(bookID)
        let end = Int(b?.pos ?? 0)
        let minutes = active / 60
        if minutes >= 0.5, let b = b {
            let s = Session(["id": .string(uid()), "bookId": .string(bookID), "start": .number(Millis.ms(sessionStart)),
                             "minutes": .number((minutes * 10).rounded() / 10), "units": .number(Double(max(0, end - startPage - 1))),
                             "unit": .string("page"), "vi": .number(0), "from": .number(Double(startPage + 1)), "to": .number(Double(end)),
                             "read": .number(Double(b.readNo))])
            Library.shared.change { $0.sessions.append(s) }
            Toaster.show("جلسة قراءة: \(Int(minutes.rounded())) دقيقة · \(max(0, end - startPage - 1)) صفحة")
        }
        if let b = b { ProgressRules.after(bookID, prevVi: b.vi, prevStatus: b.status) }
        if scoped { url.stopAccessingSecurityScopedResource() }
        dismiss(animated: true)
    }

    private func search() {
        let a = UIAlertController(title: "بحث في الملف", message: nil, preferredStyle: .alert)
        a.addTextField { $0.placeholder = "كلمة أو جملة" }
        a.addAction(UIAlertAction(title: "إلغاء", style: .cancel))
        a.addAction(UIAlertAction(title: "ابحث", style: .default) { [weak self] _ in
            guard let self = self, let q = a.textFields?.first?.text, !q.isEmpty, let d = self.pdf.document else { return }
            let found = d.findString(q, fromSelection: self.findAt, withOptions: [.caseInsensitive, .diacriticInsensitive])
                ?? d.findString(q, fromSelection: nil, withOptions: [.caseInsensitive, .diacriticInsensitive])
            if let f = found {
                self.findAt = f
                self.pdf.setCurrentSelection(f, animate: true)
                self.pdf.go(to: f)
            } else {
                Toast.show("ما لقيت «\(q)»", in: self.view, top: 90)
            }
        })
        present(a, animated: true)
    }

    private func goToPage() {
        guard let d = pdf.document else { return }
        let a = UIAlertController(title: "روح لصفحة", message: "من 1 إلى \(d.pageCount)", preferredStyle: .alert)
        a.addTextField { $0.keyboardType = .numberPad }
        a.addAction(UIAlertAction(title: "إلغاء", style: .cancel))
        a.addAction(UIAlertAction(title: "روح", style: .default) { [weak self] _ in
            guard let self = self, let t = a.textFields?.first?.text, let n = Int(t.filter(\.isNumber)), n >= 1, let p = d.page(at: min(n, d.pageCount) - 1) else { return }
            self.pdf.go(to: p)
        })
        present(a, animated: true)
    }
}
