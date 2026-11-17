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

// MARK: - direction

extension UISemanticContentAttribute {
    /// The reader's own controls read in the app's language (Arabic right to left, English left to right), whatever
    /// the phone's language is. (The book's own direction, `ReaderViewController.bookRTL`, is for what follows the text.)
    static var app: UISemanticContentAttribute { Lang.english ? .forceLeftToRight : .forceRightToLeft }
}

// MARK: - the reader's menu (Apple Books' little menu above the button), arranged by its reader

/// The menu as the owner arranged it (reader 2.4, docs/plan/reader-menu-2.4.md; «خصّص القائمة», ReaderMenuEditor.swift):
/// its rows, then its round buttons with «المزيد» last. The default puts one tap away what a reader of long novels
/// uses every session: the contents, the book's notebook, reading aloud, the replacement rules, the themes, the chapter
/// before and after (its number goes to any chapter), search, and a quick theme and brightness. Whatever does not fit
/// (a phone held sideways, too many buttons) goes into «المزيد», which always ends with «خصّص القائمة».
final class ReaderMenuView: UIView {
    private weak var reader: ReaderViewController?
    private let panel = UIStackView()
    private let scrub = UIVisualEffectView(effect: Glass.effect())
    private let knob = UIView()
    private let tip = GlassLabel(size: 14)
    private var scrubIndex = 0
    /// the tall scrubber beside the menu (off unless chosen in «خصّص القائمة»)
    private var scrubOn = false
    /// the font size in its row, updated as it changes
    private var sizeLabel: UILabel?
    private var swatches: [(id: String, button: UIButton)] = []
    /// the panel has the chapter bar (the reader hides its own «690 من 2334» under the menu meanwhile)
    private(set) var showsChapterBar = false
    private static let width: CGFloat = 276
    private static let rowHeight: CGFloat = 50
    /// a round button whose tool is on (the guide, auto-scroll, a bookmark here)
    static let lit = UIColor(red: 1, green: 0.62, blue: 0.25, alpha: 1)

    init(reader: ReaderViewController) {
        self.reader = reader
        super.init(frame: .zero)
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    // MARK: pieces

    private func glassRow() -> UIVisualEffectView {
        let v = UIVisualEffectView(effect: Glass.effect())
        v.clipsToBounds = true
        v.layer.cornerRadius = ReaderMenuView.rowHeight / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.heightAnchor.constraint(equalToConstant: ReaderMenuView.rowHeight),
            v.widthAnchor.constraint(equalToConstant: ReaderMenuView.width)
        ])
        return v
    }

    /// what a row holds, across it
    private func fill(_ v: UIVisualEffectView, _ content: UIView, start: CGFloat = 16, end: CGFloat = 18) {
        content.translatesAutoresizingMaskIntoConstraints = false
        v.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leftAnchor.constraint(equalTo: v.contentView.leftAnchor, constant: Lang.english ? start : end),
            content.rightAnchor.constraint(equalTo: v.contentView.rightAnchor, constant: -(Lang.english ? end : start)),
            content.topAnchor.constraint(equalTo: v.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: v.contentView.bottomAnchor)
        ])
    }

    private func label(_ text: String, size: CGFloat = 16) -> UILabel {
        let l = UILabel()
        l.text = text.tr
        l.font = .systemFont(ofSize: size, weight: .medium)
        l.textColor = .white
        return l
    }

    private func icon(_ symbol: String, size: CGFloat = 16, tint: UIColor = .white) -> UIImageView {
        let i = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .medium)))
        i.tintColor = tint
        i.contentMode = .center
        i.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return i
    }

    private func spacer() -> UIView {
        let s = UIView()
        s.setContentHuggingPriority(.defaultLow - 10, for: .horizontal)
        return s
    }

    /// One row: its words at the start, a small number beside them when there is one, its icon at the end. A tap does
    /// its action, or opens its menu.
    private func row(_ title: String, _ detail: String?, _ symbol: String, lit: Bool = false, menu: UIMenu? = nil, _ action: @escaping () -> Void = {}) -> UIView {
        let v = glassRow()
        let b = UIButton(type: .system)
        if let m = menu {
            b.menu = m
            b.showsMenuAsPrimaryAction = true
            b.preferredMenuElementOrder = .fixed
        }
        if menu == nil { b.addAction(UIAction { _ in action() }, for: .touchUpInside) }
        b.accessibilityLabel = title.tr + (detail.map { (Lang.english ? ", " : "، ") + $0.tr } ?? "")
        if lit { b.accessibilityTraits.insert(.selected) }
        let extra = UILabel()
        extra.text = detail?.tr
        extra.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        extra.textColor = UIColor.white.withAlphaComponent(0.6)
        let line = UIStackView(arrangedSubviews: [label(title), extra, spacer(), icon(symbol, tint: lit ? ReaderMenuView.lit : .white)])
        line.axis = .horizontal
        line.spacing = 8
        line.alignment = .center
        line.semanticContentAttribute = .app
        line.isUserInteractionEnabled = false
        fill(v, line)
        b.translatesAutoresizingMaskIntoConstraints = false
        v.contentView.addSubview(b)
        NSLayoutConstraint.activate([
            b.topAnchor.constraint(equalTo: v.contentView.topAnchor), b.bottomAnchor.constraint(equalTo: v.contentView.bottomAnchor),
            b.leftAnchor.constraint(equalTo: v.contentView.leftAnchor), b.rightAnchor.constraint(equalTo: v.contentView.rightAnchor)
        ])
        return v
    }

    private func round(_ symbol: String, _ label: String, on: Bool = false, menu: UIMenu? = nil, _ action: @escaping () -> Void = {}) -> UIView {
        let g = GlassButton(symbol: symbol, size: 15)
        if on {
            g.button.tintColor = ReaderMenuView.lit
            g.button.accessibilityTraits.insert(.selected)
        }
        g.button.accessibilityLabel = label.tr
        if let m = menu {
            g.button.menu = m
            g.button.showsMenuAsPrimaryAction = true
            g.button.preferredMenuElementOrder = .fixed
        }
        if menu == nil { g.button.addAction(UIAction { _ in action() }, for: .touchUpInside) }
        g.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([g.widthAnchor.constraint(equalToConstant: 40), g.heightAnchor.constraint(equalToConstant: 40)])
        return g
    }

    /// Two halves of one capsule among the round buttons: smaller and larger, the chapter before and after.
    private func pair(_ symbols: (String, String), _ labels: (String, String), enabled: (Bool, Bool) = (true, true), direction: UISemanticContentAttribute,
                      _ first: @escaping () -> Void, _ second: @escaping () -> Void) -> UIView {
        let v = UIVisualEffectView(effect: Glass.effect())
        v.clipsToBounds = true
        v.layer.cornerRadius = 20
        func half(_ symbol: String, _ label: String, _ on: Bool, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.accessibilityLabel = label.tr
            b.isEnabled = on
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }
        let a = half(symbols.0, labels.0, enabled.0, first)
        let b = half(symbols.1, labels.1, enabled.1, second)
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        line.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([line.widthAnchor.constraint(equalToConstant: 1), line.heightAnchor.constraint(equalToConstant: 18)])
        let st = UIStackView(arrangedSubviews: [a, line, b])
        st.axis = .horizontal
        st.alignment = .center
        st.semanticContentAttribute = direction
        st.translatesAutoresizingMaskIntoConstraints = false
        v.contentView.addSubview(st)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            a.widthAnchor.constraint(equalTo: b.widthAnchor),
            st.topAnchor.constraint(equalTo: v.contentView.topAnchor), st.bottomAnchor.constraint(equalTo: v.contentView.bottomAnchor),
            st.leftAnchor.constraint(equalTo: v.contentView.leftAnchor, constant: 2), st.rightAnchor.constraint(equalTo: v.contentView.rightAnchor, constant: -2),
            v.widthAnchor.constraint(equalToConstant: 84), v.heightAnchor.constraint(equalToConstant: 40)
        ])
        return v
    }

    /// «المزيد»: a menu straight from the button (each of its actions closes the reader's menu first).
    private func more(_ menu: UIMenu) -> UIView {
        let g = GlassButton(symbol: "ellipsis", size: 15)
        g.button.accessibilityLabel = "المزيد".tr
        g.button.menu = menu
        g.button.showsMenuAsPrimaryAction = true
        g.button.preferredMenuElementOrder = .fixed
        g.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([g.widthAnchor.constraint(equalToConstant: 40), g.heightAnchor.constraint(equalToConstant: 40)])
        return g
    }

    // MARK: the rows that do more than one thing

    /// The chapter before, the chapter's number (a tap asks for any chapter), the chapter after. The arrows go the
    /// book's way: the next chapter is on the left in an Arabic book, on the right in an English one.
    private func chapterBar(_ r: ReaderViewController) -> UIView {
        let v = glassRow()
        let rtl = r.bookRTL
        func arrow(_ symbol: String, _ label: String, _ step: Int, _ on: Bool) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.accessibilityLabel = label.tr
            b.isEnabled = on
            b.addAction(UIAction { [weak r] _ in r?.menuTurn(step) }, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 52).isActive = true
            return b
        }
        let prev = arrow(rtl ? "chevron.right" : "chevron.left", "الفصل السابق", -1, r.index > 0)
        let next = arrow(rtl ? "chevron.left" : "chevron.right", "الفصل التالي", 1, r.index < r.chapters.count - 1)
        let mid = UIButton(type: .system)
        mid.setTitle(r.chapterPosition.tr, for: .normal)
        mid.setTitleColor(.white, for: .normal)
        mid.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        mid.titleLabel?.adjustsFontSizeToFitWidth = true
        mid.titleLabel?.minimumScaleFactor = 0.7
        mid.accessibilityLabel = "اذهب لفصل".tr + (Lang.english ? ", " : "، ") + r.chapterPosition.tr
        mid.addAction(UIAction { [weak r] _ in r?.menuAction(.chapters) }, for: .touchUpInside)
        let st = UIStackView(arrangedSubviews: [prev, mid, next])
        st.axis = .horizontal
        st.alignment = .fill
        st.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        fill(v, st, start: 2, end: 2)
        showsChapterBar = true
        return v
    }

    /// «حجم الخط» with its smaller and larger: the menu stays open, the page grows behind it.
    private func sizeRow(_ r: ReaderViewController) -> UIView {
        let v = glassRow()
        let value = UILabel()
        value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        value.textColor = .white
        value.textAlignment = .center
        value.text = "\(Int(r.settings.current.size))"
        value.widthAnchor.constraint(equalToConstant: 30).isActive = true
        value.accessibilityLabel = "حجم الخط".tr + " \(Int(r.settings.current.size))"
        sizeLabel = value
        func step(_ size: CGFloat, _ label: String, _ d: Double) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle("ع".tr, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: size, weight: .semibold)
            b.tintColor = .white
            b.accessibilityLabel = label.tr
            b.addAction(UIAction { [weak self, weak r] _ in
                guard let r = r else { return }
                r.stepFont(d)
                let now = Int(r.settings.current.size)
                self?.sizeLabel?.text = "\(now)"
                self?.sizeLabel?.accessibilityLabel = "حجم الخط".tr + " \(now)"
            }, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 42).isActive = true
            return b
        }
        let line = UIStackView(arrangedSubviews: [label("حجم الخط"), spacer(), step(14, "تصغير الخط", -1), value, step(22, "تكبير الخط", 1)])
        line.axis = .horizontal
        line.spacing = 2
        line.alignment = .center
        line.semanticContentAttribute = .app
        fill(v, line, start: 16, end: 8)
        return v
    }

    /// The themes as small pages of their colours: a tap puts one on, the menu stays open.
    private func themeRow(_ r: ReaderViewController) -> UIView {
        let v = glassRow()
        let st = UIStackView()
        st.axis = .horizontal
        st.distribution = .equalSpacing
        st.alignment = .center
        st.semanticContentAttribute = .app
        for t in r.settings.themes.prefix(7) {
            let b = UIButton(type: .custom)
            b.backgroundColor = UIColor(hex: t.bg)
            b.setTitle("ع".tr, for: .normal)
            b.setTitleColor(UIColor(hex: t.fg), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
            b.layer.cornerRadius = 16
            b.accessibilityLabel = t.name.tr
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 32), b.heightAnchor.constraint(equalToConstant: 32)])
            let id = t.id
            b.addAction(UIAction { [weak self, weak r] _ in
                r?.settings.select(id)
                self?.markTheme(id)
                Haptics.play("sel")
            }, for: .touchUpInside)
            swatches.append((id, b))
            st.addArrangedSubview(b)
        }
        markTheme(r.settings.currentID)
        fill(v, st, start: 14, end: 14)
        return v
    }

    private func markTheme(_ id: String) {
        for s in swatches {
            let on = s.id == id
            s.button.layer.borderWidth = on ? 2.5 : 1
            s.button.layer.borderColor = (on ? UIColor.white : UIColor.white.withAlphaComponent(0.28)).cgColor
            if on { s.button.accessibilityTraits.insert(.selected) } else { s.button.accessibilityTraits.remove(.selected) }
        }
    }

    /// The screen's brightness, as in the themes panel: the menu stays open.
    private func brightnessRow(_ r: ReaderViewController) -> UIView {
        let v = glassRow()
        let s = UISlider()
        s.minimumValue = 0.02
        s.maximumValue = 1
        s.value = Float(r.brightness)
        s.minimumTrackTintColor = .white
        s.semanticContentAttribute = .app
        s.accessibilityLabel = "السطوع".tr
        s.addAction(UIAction { [weak r, weak s] _ in
            guard let s = s else { return }
            r?.brightness = CGFloat(s.value)
        }, for: .valueChanged)
        let line = UIStackView(arrangedSubviews: [icon("sun.min.fill", size: 13, tint: UIColor.white.withAlphaComponent(0.8)), s,
                                                  icon("sun.max.fill", size: 17, tint: UIColor.white.withAlphaComponent(0.8))])
        line.axis = .horizontal
        line.spacing = 6
        line.alignment = .center
        line.semanticContentAttribute = .app
        fill(v, line, start: 10, end: 10)
        return v
    }

    // MARK: an item in its place

    private func rowView(_ i: ReaderMenuItem, _ r: ReaderViewController) -> UIView {
        switch i {
        case .chapters: return chapterBar(r)
        case .fontSize: return sizeRow(r)
        case .theme: return themeRow(r)
        case .brightness: return brightnessRow(r)
        case .pageStyle: return row(i.title(epub: r.isEpub), r.pageStyle.name, r.pageStyle.icon, menu: r.quickMenu(i))
        default:
            return row(i.title(epub: r.isEpub), r.menuDetail(i), r.menuSymbol(i), lit: r.menuIsOn(i)) { [weak r] in r?.menuAction(i) }
        }
    }

    private func buttonView(_ i: ReaderMenuItem, _ r: ReaderViewController) -> UIView {
        let title = i.title(epub: r.isEpub)
        switch i {
        case .chapters:
            let rtl = r.bookRTL
            return pair((rtl ? "chevron.right" : "chevron.left", rtl ? "chevron.left" : "chevron.right"), ("الفصل السابق", "الفصل التالي"),
                        enabled: (r.index > 0, r.index < r.chapters.count - 1), direction: rtl ? .forceRightToLeft : .forceLeftToRight,
                        { [weak r] in r?.menuTurn(-1) }, { [weak r] in r?.menuTurn(1) })
        case .fontSize:
            return pair(("textformat.size.smaller", "textformat.size.larger"), ("تصغير الخط", "تكبير الخط"), direction: .app,
                        { [weak r] in r?.stepFont(-1) }, { [weak r] in r?.stepFont(1) })
        case .theme, .brightness, .pageStyle:
            return round(r.menuSymbol(i), title, menu: r.quickMenu(i))
        default:
            return round(r.menuSymbol(i), title, on: r.menuIsOn(i)) { [weak r] in r?.menuAction(i) }
        }
    }

    private func hstack(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let h = UIStackView(arrangedSubviews: views)
        h.axis = .horizontal
        h.spacing = spacing
        h.distribution = .equalSpacing
        h.alignment = .center
        h.semanticContentAttribute = .app
        return h
    }

    func show(in host: UIView, above anchor: UIView) {
        guard let r = reader else { return }
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)

        panel.axis = .vertical
        panel.spacing = 8
        // right above the menu button, in both languages
        panel.alignment = .trailing
        panel.semanticContentAttribute = .forceLeftToRight
        panel.translatesAutoresizingMaskIntoConstraints = false
        scrub.clipsToBounds = true
        scrub.translatesAutoresizingMaskIntoConstraints = false

        let layout = ReaderMenuLayout.current
        var rows = layout.rows.filter { r.menuOffers($0) }
        var spill: [ReaderMenuItem] = []
        // as many rows as fit between the close button and the menu button (fewer on a phone held sideways); the
        // rest go to the top of «المزيد»
        let room = anchor.frame.minY - 10 - (host.safeAreaInsets.top + 60) - 48
        let fit = min(ReaderMenuLayout.maxRows, max(1, Int(floor(room / (ReaderMenuView.rowHeight + 8)))))
        if rows.count > fit {
            spill += rows[fit...]
            rows = Array(rows.prefix(fit))
        }
        let (buttons, extra) = ReaderMenuLayout.fit(layout.buttons.filter { r.menuOffers($0) })
        spill += extra

        for i in rows { panel.addArrangedSubview(rowView(i, r)) }
        let line = hstack(buttons.map { buttonView($0, r) } + [more(r.moreMenu(spill))], spacing: 7)
        // four round buttons or more spread across the menu's width (as Apple's); fewer stay together by the button
        if buttons.reduce(1, { $0 + $1.width }) >= 4 { line.widthAnchor.constraint(equalToConstant: ReaderMenuView.width).isActive = true }
        panel.addArrangedSubview(line)
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.rightAnchor.constraint(equalTo: anchor.rightAnchor),
            panel.bottomAnchor.constraint(equalTo: anchor.topAnchor, constant: -10)
        ])
        // the scrubber (when chosen): right beside the menu, as tall as it, wide enough for a thumb. Up and down (the
        // first chapter at the top), so it reads the same in an Arabic book and an English one
        scrubOn = layout.scrubber && r.chapters.count > 1 && anchor.frame.maxX - ReaderMenuView.width - 62 >= 8
        if scrubOn {
            scrub.layer.cornerRadius = 26
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
            scrub.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrubTapped(_:))))
            scrub.isAccessibilityElement = true
            scrub.accessibilityLabel = "التنقل بين الفصول".tr
            tip.alpha = 0
            addSubview(tip)
        }

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
        if !panel.frame.contains(p) && !(scrubOn && scrub.frame.contains(p)) { reader?.closeOverlays() }
    }

    // MARK: the scrubber

    private func placeKnob() {
        guard scrubOn, let r = reader, r.chapters.count > 1 else { return }
        let f = CGFloat(scrubIndex) / CGFloat(r.chapters.count - 1)
        let h = scrub.bounds.height - 32
        knob.frame = CGRect(x: 12, y: 16 + h * f - 3, width: 28, height: 6)
    }

    private func index(at p: CGPoint) -> Int {
        guard let r = reader, r.chapters.count > 1 else { return 0 }
        let f = max(0, min(1, (p.y - 16) / max(1, scrub.bounds.height - 32)))
        return Int((f * CGFloat(r.chapters.count - 1)).rounded())
    }

    private func showTip(_ i: Int) {
        guard let r = reader, r.chapters.indices.contains(i) else { return }
        let ch = r.chapters[i]
        tip.text = ch.numbered && !ch.title.isEmpty ? "\(ch.label)\n\(ch.title)" : ch.label
        let s = tip.systemLayoutSizeFitting(CGSize(width: ReaderMenuView.width - 20, height: 90))
        let w = min(ReaderMenuView.width - 20, s.width)
        tip.frame = CGRect(x: panel.frame.midX - w / 2, y: scrub.frame.minY + knob.frame.midY - s.height / 2, width: w, height: s.height)
        UIView.animate(withDuration: 0.12) { self.tip.alpha = 1; self.panel.alpha = 0.12 }
    }

    @objc private func scrubbed(_ g: UIPanGestureRecognizer) {
        guard let r = reader, r.chapters.count > 1 else { return }
        let i = index(at: g.location(in: scrub))
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
        let i = index(at: g.location(in: scrub))
        r.closeOverlays()
        if i != r.index { r.goTo(chapterIndex: i) }
    }
}

// MARK: - the bar over a highlight: colours, underline, note or its entry, notebook, share, copy, remove

/// A tapped highlight. Its colours carry the names the owner gave them (معلومة، مضحك، تلميح…: the notebook's
/// categories). A highlight that is a quote's, thought's or word's place says so, and opens that entry instead of a
/// note; removing it asks whether the entry goes too.
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
    /// the notebook entry this highlight is the place of, if any
    private let entry: NoteKind?
    private let dots = UIStackView()
    private var dotButtons: [UIButton] = []
    private let caption = UILabel()

    init(reader: ReaderViewController, mark: [String: Any], labels: [String: String], entry: NoteKind? = nil) {
        self.reader = reader
        self.mark = mark
        self.labels = labels
        self.entry = entry
        super.init(effect: Glass.effect(interactive: false))
        clipsToBounds = true
        layer.cornerRadius = 22
        build()
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    private var current: String { (mark["color"] as? String) ?? "yellow" }
    private var underline: Bool { (mark["style"] as? String) == "ul" }

    private func name(_ c: Colour) -> String {
        let n = (labels[c.id] ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? c.plain.tr : n
    }

    private func build() {
        dots.axis = .horizontal
        dots.distribution = .equalSpacing
        dots.alignment = .top
        dots.semanticContentAttribute = .app
        // the colours he named are his categories: each name shows under its dot
        let named = MarkBar.colors.contains { !(labels[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        for c in MarkBar.colors {
            let b = UIButton(type: .custom)
            b.backgroundColor = c.ui
            b.layer.cornerRadius = 15
            b.layer.borderColor = UIColor.white.cgColor
            b.layer.borderWidth = c.id == current ? 3 : 0
            b.accessibilityLabel = name(c)
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 30), b.heightAnchor.constraint(equalToConstant: 30)])
            b.addAction(UIAction { [weak self] _ in self?.pick(c.id) }, for: .touchUpInside)
            dotButtons.append(b)
            if named {
                let l = UILabel()
                l.text = (labels[c.id] ?? "").trimmingCharacters(in: .whitespaces)
                l.font = .systemFont(ofSize: 9.5, weight: .medium)
                l.textColor = UIColor.white.withAlphaComponent(0.75)
                l.textAlignment = .center
                l.adjustsFontSizeToFitWidth = true
                l.minimumScaleFactor = 0.7
                l.isAccessibilityElement = false
                l.widthAnchor.constraint(equalToConstant: 38).isActive = true
                let col = UIStackView(arrangedSubviews: [b, l])
                col.axis = .vertical
                col.alignment = .center
                col.spacing = 3
                dots.addArrangedSubview(col)
            } else {
                dots.addArrangedSubview(b)
            }
        }
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = UIColor.white.withAlphaComponent(0.75)
        caption.textAlignment = .center
        updateCaption()

        func tool(_ symbol: String, _ title: String, tint: UIColor = .white, _ action: @escaping () -> Void) -> UIButton {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            cfg.title = title.tr
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
        var list: [UIView] = [tool("underline", underline ? "تظليل" : "خط تحت") { [weak self] in self?.toggleStyle() }]
        if let k = entry {
            // the quote (thought, word) this highlight is: its form, over the page
            list.append(tool(k.symbol, k.name) { [weak self] in
                guard let self = self else { return }
                self.reader?.editEntry(of: self.mark)
            })
        } else {
            list.append(tool("note.text", (mark["note"] as? String)?.isEmpty == false ? "الملاحظة" : "ملاحظة") { [weak self] in
                guard let self = self else { return }
                self.reader?.editNote(self.mark)
            })
            let book = tool("book.closed", "للدفتر") {}
            book.showsMenuAsPrimaryAction = true
            // the highlight becomes the entry's place (a character is named in the text anyway)
            book.menu = UIMenu(children: NoteKind.allCases.map { k in
                UIAction(title: k.name.tr, image: UIImage(systemName: k.symbol)) { [weak self] _ in
                    guard let self = self else { return }
                    self.reader?.markToNotebook(self.mark, kind: k.rawValue)
                }
            })
            list.append(book)
        }
        // the words, or the passage as a picture in the book's colours (دفتري 2.4: the same card as the notebook's)
        let share = tool("square.and.arrow.up", "مشاركة") {}
        share.showsMenuAsPrimaryAction = true
        share.menu = UIMenu(children: [
            UIAction(title: "مشاركة النص".tr, image: UIImage(systemName: "text.quote")) { [weak self] _ in
                guard let self = self, let r = self.reader else { return }
                r.shareQuote((self.mark["text"] as? String) ?? "", chapter: (self.mark["chLabel"] as? String) ?? "")
            },
            UIAction(title: "بطاقة صورة".tr, image: UIImage(systemName: "photo")) { [weak self] _ in
                guard let self = self else { return }
                self.reader?.passageCard(self.mark)
            }
        ])
        list.append(share)
        list.append(tool("doc.on.doc", "نسخ") { [weak self] in
            UIPasteboard.general.string = (self?.mark["text"] as? String) ?? ""
            self?.reader?.closeOverlays()
            self?.reader?.toast("انتسخ النص")
        })
        list.append(tool("trash", "إزالة", tint: UIColor(red: 1, green: 0.42, blue: 0.4, alpha: 1)) { [weak self] in
            guard let self = self else { return }
            self.reader?.removeMark(self.mark)
        })
        let tools = UIStackView(arrangedSubviews: list)
        tools.axis = .horizontal
        tools.distribution = .fillEqually
        tools.semanticContentAttribute = .app

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
        let c = MarkBar.colors.first { $0.id == current }
        let colour = c.map { name($0) } ?? ""
        // «اقتباس في الدفتر · معلومة»: what this highlight is, and its colour's name
        caption.text = entry.map { ($0.name + " في الدفتر").tr + " · " + colour } ?? colour
        for (i, b) in dotButtons.enumerated() { b.layer.borderWidth = MarkBar.colors[i].id == current ? 3 : 0 }
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
        st.semanticContentAttribute = .app
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
