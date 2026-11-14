import UIKit

// MARK: - glass pieces

enum Glass {
    /// Liquid Glass where the system has it, the thin dark material before that.
    static func effect(interactive: Bool = true) -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect()
            g.isInteractive = interactive
            return g
        }
        return UIBlurEffect(style: .systemThinMaterialDark)
    }
}

/// The page colour, solid at the very top and gone a few points lower.
final class FadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var color: UIColor = .black { didSet { apply() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        apply()
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    private func apply() {
        guard let g = layer as? CAGradientLayer else { return }
        g.colors = [color.cgColor, color.withAlphaComponent(0.88).cgColor, color.withAlphaComponent(0).cgColor]
        g.locations = [0, 0.62, 1]
    }
}

final class GlassButton: UIVisualEffectView {
    let button = UIButton(type: .system)

    init(symbol: String, size: CGFloat = 17) {
        super.init(effect: Glass.effect())
        clipsToBounds = true
        setSymbol(symbol, size: size)
        button.tintColor = .white
        button.frame = bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(button)
    }

    func setSymbol(_ symbol: String, size: CGFloat = 17) {
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

final class GlassLabel: UIVisualEffectView {
    private let label = UILabel()
    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    init(size: CGFloat = 13) {
        super.init(effect: Glass.effect(interactive: false))
        clipsToBounds = true
        isUserInteractionEnabled = false
        label.font = .systemFont(ofSize: size, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            label.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 13),
            label.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -13)
        ])
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, 18)
    }
}

/// A short message that shows and fades by itself (like «وقفة: تمت الإضافة»).
enum Toast {
    static func show(_ text: String, in view: UIView, top: CGFloat? = nil, bottom: CGFloat? = nil) {
        let l = GlassLabel(size: 14)
        l.text = text.tr
        l.alpha = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        var cs = [l.centerXAnchor.constraint(equalTo: view.centerXAnchor), l.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)]
        if let b = bottom { cs.append(l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -b)) }
        else { cs.append(l.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: top ?? 60)) }
        NSLayoutConstraint.activate(cs)
        UIView.animate(withDuration: 0.2) { l.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 2.2, options: []) { l.alpha = 0 } completion: { _ in l.removeFromSuperview() }
    }
}

// MARK: - the reader's menu (Apple Books' little menu above the button, with the chapter scrubber beside it)

final class ReaderMenuView: UIView {
    private weak var reader: ReaderViewController?
    private let panel = UIStackView()
    private let scrub = UIVisualEffectView(effect: Glass.effect())
    private let knob = UIView()
    private let tip = GlassLabel(size: 14)
    private var scrubIndex = 0
    private static let width: CGFloat = 276
    private static let rowHeight: CGFloat = 50

    init(reader: ReaderViewController) {
        self.reader = reader
        super.init(frame: .zero)
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    /// One row: its words on the right, a small number beside them when there is one, its icon on the left.
    private func row(_ title: String, _ detail: String?, _ symbol: String, _ action: @escaping () -> Void) -> UIView {
        let v = UIVisualEffectView(effect: Glass.effect())
        v.clipsToBounds = true
        v.layer.cornerRadius = ReaderMenuView.rowHeight / 2
        let b = UIButton(type: .system)
        b.addAction(UIAction { [weak self] _ in action(); self?.reader?.closeOverlays() }, for: .touchUpInside)
        b.accessibilityLabel = title.tr
        let name = UILabel()
        name.text = title.tr
        name.font = .systemFont(ofSize: 16, weight: .medium)
        name.textColor = .white
        let extra = UILabel()
        extra.text = detail
        extra.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        extra.textColor = UIColor.white.withAlphaComponent(0.6)
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let spacer = UIView()
        let line = UIStackView(arrangedSubviews: [name, extra, spacer, icon])
        line.axis = .horizontal
        line.spacing = 8
        line.alignment = .center
        line.semanticContentAttribute = .forceRightToLeft
        line.isUserInteractionEnabled = false
        line.translatesAutoresizingMaskIntoConstraints = false
        b.translatesAutoresizingMaskIntoConstraints = false
        v.contentView.addSubview(line)
        v.contentView.addSubview(b)
        NSLayoutConstraint.activate([
            line.leftAnchor.constraint(equalTo: v.contentView.leftAnchor, constant: 16),
            line.rightAnchor.constraint(equalTo: v.contentView.rightAnchor, constant: -18),
            line.centerYAnchor.constraint(equalTo: v.contentView.centerYAnchor),
            b.topAnchor.constraint(equalTo: v.contentView.topAnchor), b.bottomAnchor.constraint(equalTo: v.contentView.bottomAnchor),
            b.leftAnchor.constraint(equalTo: v.contentView.leftAnchor), b.rightAnchor.constraint(equalTo: v.contentView.rightAnchor),
            v.heightAnchor.constraint(equalToConstant: ReaderMenuView.rowHeight),
            v.widthAnchor.constraint(equalToConstant: ReaderMenuView.width)
        ])
        return v
    }

    private func round(_ symbol: String, _ label: String, on: Bool = false, _ action: @escaping () -> Void) -> UIView {
        let g = GlassButton(symbol: symbol, size: 15)
        if on { g.button.tintColor = UIColor(red: 1, green: 0.62, blue: 0.25, alpha: 1) }
        g.button.accessibilityLabel = label.tr
        g.button.addAction(UIAction { [weak self] _ in action(); self?.reader?.closeOverlays() }, for: .touchUpInside)
        g.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([g.widthAnchor.constraint(equalToConstant: 40), g.heightAnchor.constraint(equalToConstant: 40)])
        return g
    }

    func show(in host: UIView, above anchor: UIView) {
        guard let r = reader else { return }
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)

        panel.axis = .vertical
        panel.spacing = 8
        panel.alignment = .trailing
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addArrangedSubview(row("المحتويات", r.progressText, "list.bullet") { [weak r] in r?.openContents() })
        panel.addArrangedSubview(row("الوقفات والتمييزات", r.markCount > 0 ? "\(r.markCount)" : nil, "bookmark") { [weak r] in r?.openMarks() })
        panel.addArrangedSubview(row("بحث في الرواية", nil, "magnifyingglass") { [weak r] in r?.openSearch() })
        panel.addArrangedSubview(row("القراءة الصوتية", nil, "speaker.wave.2") { [weak r] in r?.startReadAloud() })
        if !Novels.shared.mirrors(r.novel.id).isEmpty {
            panel.addArrangedSubview(row("الفصل من مصدر ثاني", nil, "arrow.triangle.2.circlepath") { [weak r] in r?.chapterFromMirror() })
        }
        panel.addArrangedSubview(row("السمات والإعدادات", nil, "textformat.size") { [weak r] in r?.openThemes() })
        // the small actions in one row of round buttons, right to left
        let buttons = UIStackView(arrangedSubviews: [
            round("square.and.arrow.up", "مشاركة") { [weak r] in r?.share() },
            round(r.isLocked ? "lock.rotation" : "lock.open.rotation", "قفل الاتجاه", on: r.isLocked) { [weak r] in r?.toggleLock() },
            round("text.line.first.and.arrowtriangle.forward", "دليل السطر", on: r.guideOn) { [weak r] in r?.toggleGuide() },
            round(r.bookmarkedHere ? "bookmark.fill" : "bookmark", "وقفة", on: r.bookmarkedHere) { [weak r] in r?.toggleBookmark() },
            round("play.circle", "تمرير تلقائي") { [weak r] in r?.toggleAutoScroll() },
            round("safari", "افتح الفصل في الموقع") { [weak r] in r?.openSite() }
        ])
        buttons.spacing = 7
        buttons.distribution = .equalSpacing
        buttons.semanticContentAttribute = .forceRightToLeft
        buttons.widthAnchor.constraint(equalToConstant: ReaderMenuView.width).isActive = true
        panel.addArrangedSubview(buttons)
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.rightAnchor.constraint(equalTo: anchor.rightAnchor),
            panel.bottomAnchor.constraint(equalTo: anchor.topAnchor, constant: -10)
        ])

        // the scrubber: right beside the menu, as tall as it, wide enough for a thumb
        scrub.clipsToBounds = true
        scrub.layer.cornerRadius = 26
        scrub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrub)
        NSLayoutConstraint.activate([
            scrub.rightAnchor.constraint(equalTo: panel.leftAnchor, constant: -10),
            scrub.topAnchor.constraint(equalTo: panel.topAnchor),
            scrub.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            scrub.widthAnchor.constraint(equalToConstant: 52)
        ])
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        knob.layer.cornerRadius = 3
        scrub.contentView.addSubview(knob)
        scrub.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrubbed(_:))))
        let tapScrub = UITapGestureRecognizer(target: self, action: #selector(scrubTapped(_:)))
        scrub.addGestureRecognizer(tapScrub)
        scrub.isAccessibilityElement = true
        scrub.accessibilityLabel = "التنقل بين الفصول".tr
        tip.alpha = 0
        addSubview(tip)

        scrubIndex = r.index
        alpha = 0
        panel.transform = CGAffineTransform(translationX: 0, y: 14).scaledBy(x: 0.96, y: 0.96)
        layoutIfNeeded()
        placeKnob()
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.alpha = 1
            self.panel.transform = .identity
        }
    }

    func hide() {
        UIView.animate(withDuration: 0.16, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }

    @objc private func outside(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if !panel.frame.contains(p) && !scrub.frame.contains(p) { reader?.closeOverlays() }
    }

    private func placeKnob() {
        guard let r = reader, r.chapters.count > 1 else { return }
        let h = scrub.bounds.height - 32
        let y = 16 + h * CGFloat(scrubIndex) / CGFloat(r.chapters.count - 1)
        knob.frame = CGRect(x: 12, y: y - 3, width: 28, height: 6)
    }

    private func index(at y: CGFloat) -> Int {
        guard let r = reader, r.chapters.count > 1 else { return 0 }
        let f = max(0, min(1, (y - 16) / max(1, scrub.bounds.height - 32)))
        return Int((f * CGFloat(r.chapters.count - 1)).rounded())
    }

    private func showTip(_ i: Int) {
        guard let r = reader else { return }
        let ch = r.chapters[i]
        tip.text = ch.numbered && !ch.title.isEmpty ? "\(ch.label)\n\(ch.title)" : ch.label
        let s = tip.systemLayoutSizeFitting(CGSize(width: ReaderMenuView.width - 20, height: 90))
        let w = min(ReaderMenuView.width - 20, s.width)
        tip.frame = CGRect(x: panel.frame.midX - w / 2, y: scrub.frame.minY + knob.frame.midY - s.height / 2, width: w, height: s.height)
        UIView.animate(withDuration: 0.12) { self.tip.alpha = 1; self.panel.alpha = 0.12 }
    }

    @objc private func scrubbed(_ g: UIPanGestureRecognizer) {
        guard let r = reader, r.chapters.count > 1 else { return }
        let i = index(at: g.location(in: scrub).y)
        switch g.state {
        case .began, .changed:
            if i != scrubIndex { Haptics.play("sel") }
            scrubIndex = i
            placeKnob()
            showTip(i)
        case .ended:
            UIView.animate(withDuration: 0.12) { self.tip.alpha = 0 }
            r.closeOverlays()
            if i != r.index { r.goTo(chapterIndex: i) }
        default:
            UIView.animate(withDuration: 0.12) { self.tip.alpha = 0; self.panel.alpha = 1 }
        }
    }

    @objc private func scrubTapped(_ g: UITapGestureRecognizer) {
        guard let r = reader else { return }
        let i = index(at: g.location(in: scrub).y)
        r.closeOverlays()
        if i != r.index { r.goTo(chapterIndex: i) }
    }
}

// MARK: - the bar over a highlight: colours, underline, note, notebook, copy, delete

final class MarkBar: UIVisualEffectView {
    struct Colour { let id: String; let ui: UIColor; let plain: String }
    static let colors: [Colour] = [
        Colour(id: "yellow", ui: UIColor(hex: "#f5c84c"), plain: "أصفر"), Colour(id: "green", ui: UIColor(hex: "#6fcf7c"), plain: "أخضر"),
        Colour(id: "blue", ui: UIColor(hex: "#5aa9f0"), plain: "أزرق"), Colour(id: "pink", ui: UIColor(hex: "#f07fb4"), plain: "وردي"),
        Colour(id: "purple", ui: UIColor(hex: "#a98bf0"), plain: "بنفسجي"), Colour(id: "orange", ui: UIColor(hex: "#f2994a"), plain: "برتقالي"),
        Colour(id: "red", ui: UIColor(hex: "#eb5757"), plain: "أحمر"), Colour(id: "gray", ui: UIColor(hex: "#a7a7a7"), plain: "رمادي")
    ]

    private weak var reader: ReaderViewController?
    private var mark: [String: Any]
    private let labels: [String: String]
    private let dots = UIStackView()
    private let caption = UILabel()

    init(reader: ReaderViewController, mark: [String: Any], labels: [String: String]) {
        self.reader = reader
        self.mark = mark
        self.labels = labels
        super.init(effect: Glass.effect(interactive: false))
        clipsToBounds = true
        layer.cornerRadius = 22
        build()
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    private var current: String { (mark["color"] as? String) ?? "yellow" }
    private var underline: Bool { (mark["style"] as? String) == "ul" }

    private func build() {
        dots.axis = .horizontal
        dots.spacing = 8
        dots.distribution = .equalSpacing
        dots.semanticContentAttribute = .forceRightToLeft
        for c in MarkBar.colors {
            let b = UIButton(type: .custom)
            b.backgroundColor = c.ui
            b.layer.cornerRadius = 15
            b.layer.borderColor = UIColor.white.cgColor
            b.layer.borderWidth = c.id == current ? 3 : 0
            b.accessibilityLabel = (labels[c.id]?.isEmpty == false ? labels[c.id]! : c.plain)
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 30), b.heightAnchor.constraint(equalToConstant: 30)])
            b.addAction(UIAction { [weak self] _ in self?.pick(c.id) }, for: .touchUpInside)
            dots.addArrangedSubview(b)
        }
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = UIColor.white.withAlphaComponent(0.75)
        caption.textAlignment = .center
        updateCaption()

        func tool(_ symbol: String, _ title: String, tint: UIColor = .white, _ action: @escaping () -> Void) -> UIButton {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            cfg.title = title
            cfg.imagePlacement = .top
            cfg.imagePadding = 3
            cfg.baseForegroundColor = tint
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var b = a
                b.font = UIFont.systemFont(ofSize: 11, weight: .medium)
                return b
            }
            return UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        }
        let ul = tool(underline ? "underline" : "underline", underline ? "تظليل" : "خط تحت") { [weak self] in self?.toggleStyle() }
        let note = tool("note.text", (mark["note"] as? String)?.isEmpty == false ? "الملاحظة" : "ملاحظة") { [weak self] in
            guard let self = self else { return }
            self.reader?.editNote(self.mark)
        }
        let book = tool("book.closed", "للدفتر") {}
        book.showsMenuAsPrimaryAction = true
        let kinds: [(String, String, String)] = [("quote", "اقتباس", "text.quote"), ("thought", "خاطرة", "lightbulb"), ("word", "كلمة", "character.book.closed"), ("char", "شخصية", "person")]
        // «معلومة»: the highlight takes the colour named «معلومة», so it shows in the notebook's «معلومات» list
        let info = UIAction(title: "معلومة".tr, image: UIImage(systemName: "info.circle")) { [weak self] _ in
            guard let self = self, let c = self.reader?.infoColor else { return }
            self.pick(c)
            self.reader?.toast("انحفظت في «معلومات» بالدفتر")
        }
        book.menu = UIMenu(children: kinds.map { item in
            UIAction(title: item.1, image: UIImage(systemName: item.2)) { [weak self] _ in
                guard let self = self else { return }
                self.reader?.openNotebook(kind: item.0, text: (self.mark["text"] as? String) ?? "", sentence: "", at: self.mark)
            }
        } + [info])
        let copy = tool("doc.on.doc", "نسخ") { [weak self] in
            UIPasteboard.general.string = (self?.mark["text"] as? String) ?? ""
            self?.reader?.closeOverlays()
            self?.reader?.toast("انتسخ النص")
        }
        let share = tool("square.and.arrow.up", "مشاركة") { [weak self] in
            guard let self = self, let r = self.reader else { return }
            r.shareQuote((self.mark["text"] as? String) ?? "", chapter: (self.mark["chLabel"] as? String) ?? "")
        }
        let del = tool("trash", "إزالة", tint: UIColor(red: 1, green: 0.42, blue: 0.4, alpha: 1)) { [weak self] in
            guard let self = self else { return }
            self.reader?.deleteMark(self.mark)
        }
        let tools = UIStackView(arrangedSubviews: [ul, note, book, share, copy, del])
        tools.axis = .horizontal
        tools.distribution = .fillEqually
        tools.semanticContentAttribute = .forceRightToLeft

        let col = UIStackView(arrangedSubviews: [dots, caption, tools])
        col.axis = .vertical
        col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            col.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            col.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 14),
            col.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -14)
        ])
    }

    private func updateCaption() {
        let name = labels[current] ?? ""
        caption.text = name.isEmpty ? (MarkBar.colors.first { $0.id == current }?.plain ?? "") : name
        for (i, v) in dots.arrangedSubviews.enumerated() { v.layer.borderWidth = MarkBar.colors[i].id == current ? 3 : 0 }
    }

    private func pick(_ c: String) {
        mark["color"] = c
        reader?.saveMark(mark)
        updateCaption()
        Haptics.play("sel")
    }

    private func toggleStyle() {
        mark["style"] = underline ? "hl" : "ul"
        reader?.saveMark(mark)
        reader?.closeOverlays()
    }

    func show(in host: UIView, near r: CGRect) {
        let w = min(host.bounds.width - 24, 372)
        translatesAutoresizingMaskIntoConstraints = true
        let size = systemLayoutSizeFitting(CGSize(width: w, height: 400), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let h = max(118, size.height)
        let above = r.minY - h - 12
        let y = above > host.safeAreaInsets.top + 8 ? above : min(host.bounds.height - h - host.safeAreaInsets.bottom - 8, r.maxY + 12)
        frame = CGRect(x: (host.bounds.width - w) / 2, y: y, width: w, height: h)
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        host.addSubview(self)
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.alpha = 1
            self.transform = .identity
        }
    }
}

// MARK: - auto scroll control

final class AutoScrollPill: UIVisualEffectView {
    private var speed: Double
    private var playing = true
    private let change: (Double, Bool) -> Void
    private let close: () -> Void
    private let label = UILabel()
    private var playButton: UIButton!

    init(speed: Double, change: @escaping (Double, Bool) -> Void, close: @escaping () -> Void) {
        self.speed = speed
        self.change = change
        self.close = close
        super.init(effect: Glass.effect())
        clipsToBounds = true
        layer.cornerRadius = 24
        func b(_ s: String, _ a: @escaping () -> Void) -> UIButton {
            let x = UIButton(type: .system)
            x.setImage(UIImage(systemName: s, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
            x.tintColor = .white
            x.addAction(UIAction { _ in a() }, for: .touchUpInside)
            x.widthAnchor.constraint(equalToConstant: 40).isActive = true
            return x
        }
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        playButton = b("pause.fill") { [weak self] in self?.togglePlay() }
        let st = UIStackView(arrangedSubviews: [b("minus") { [weak self] in self?.step(-8) }, playButton, label, b("plus") { [weak self] in self?.step(8) }, b("xmark") { [weak self] in self?.close() }])
        st.spacing = 4
        st.alignment = .center
        st.semanticContentAttribute = .forceRightToLeft
        st.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(st)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: contentView.topAnchor), st.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            st.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 8), st.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: 48)
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    private func update() { label.text = "السرعة \(Int(speed))".tr }

    private func step(_ d: Double) {
        speed = max(8, min(240, speed + d))
        update()
        change(speed, playing)
    }

    private func togglePlay() {
        playing.toggle()
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        change(speed, playing)
    }
}

// MARK: - a picture from a book, full screen, pinch or double-tap to zoom

final class ImageViewer: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let scroll = UIScrollView()
    private let imageView = UIImageView()

    static func show(_ src: String, from vc: UIViewController) {
        guard let u = URL(string: src), u.path.hasPrefix("/epub/") else { return }
        let rest = String(u.path.dropFirst(6))
        guard let slash = rest.firstIndex(of: "/"),
              let d = EpubStore.resource(String(rest[..<slash]), String(rest[rest.index(after: slash)...])), let img = UIImage(data: d) else { return }
        let v = ImageViewer(image: img)
        v.modalPresentationStyle = .overFullScreen
        v.modalTransitionStyle = .crossDissolve
        vc.present(v, animated: true)
    }

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        view.addSubview(scroll)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(dbl)
        let close = GlassButton(symbol: "xmark")
        close.translatesAutoresizingMaskIntoConstraints = false
        close.button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.button.accessibilityLabel = "إغلاق".tr
        view.addSubview(close)
        NSLayoutConstraint.activate([
            close.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor, constant: 14),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) } else {
            let p = g.location(in: imageView)
            scroll.zoom(to: CGRect(x: p.x - 80, y: p.y - 80, width: 160, height: 160), animated: true)
        }
    }

    @objc private func closeTapped() { dismiss(animated: true) }
}
