import UIKit
import UniformTypeIdentifiers

/// «جليس» in Safari's share sheet (answers-round2 س17، س67): the page's link (a novel or one of its chapters) goes to
/// Jalees, which adds the novel and opens it. The link waits in the shared group, so it is added even if Jalees can't
/// be opened from here.
final class ShareViewController: UIViewController {
    private var link: String?
    private let card = UIView()
    private let titleLabel = UILabel()
    private let linkLabel = UILabel()
    private let add = UIButton(type: .system)
    private let cancel = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        view.semanticContentAttribute = .forceRightToLeft
        card.backgroundColor = UIColor(red: 0.09, green: 0.13, blue: 0.12, alpha: 1)
        card.layer.cornerRadius = 22
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        titleLabel.text = "أضف لجليس"
        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .right
        linkLabel.text = "أدوّر على الرابط…"
        linkLabel.font = .systemFont(ofSize: 13)
        linkLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        linkLabel.numberOfLines = 3
        linkLabel.textAlignment = .right
        add.setTitle("أضف الرواية", for: .normal)
        add.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        add.backgroundColor = UIColor(red: 0.36, green: 0.76, blue: 0.68, alpha: 1)
        add.setTitleColor(UIColor(red: 0.03, green: 0.13, blue: 0.11, alpha: 1), for: .normal)
        add.layer.cornerRadius = 14
        add.isEnabled = false
        add.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        cancel.setTitle("إلغاء", for: .normal)
        cancel.tintColor = .white
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, linkLabel, add, cancel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 14), card.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -14),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leftAnchor.constraint(equalTo: card.leftAnchor, constant: 18), stack.rightAnchor.constraint(equalTo: card.rightAnchor, constant: -18),
            add.heightAnchor.constraint(equalToConstant: 50)
        ])
        findLink()
    }

    /// The page's address (Safari shares a URL; some apps share text with a link in it).
    private func findLink() {
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? []).flatMap { $0.attachments ?? [] }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            p.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                let s = (item as? URL)?.absoluteString ?? (item as? String)
                DispatchQueue.main.async { self.found(s) }
            }
        } else if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            p.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                let text = (item as? String) ?? ""
                let s = text.range(of: #"https?://\S+"#, options: .regularExpression).map { String(text[$0]) }
                DispatchQueue.main.async { self.found(s) }
            }
        } else {
            found(nil)
        }
    }

    private func found(_ s: String?) {
        guard let s = s, s.hasPrefix("http") else {
            linkLabel.text = "ما لقيت رابط في اللي شاركته"
            return
        }
        link = s
        linkLabel.text = s.removingPercentEncoding ?? s
        add.isEnabled = true
    }

    @objc private func addTapped() {
        guard let l = link else { return }
        SharedLinks.push(l)
        var c = URLComponents()
        c.scheme = "wird"
        c.host = "add"
        c.queryItems = [URLQueryItem(name: "url", value: l)]
        if let u = c.url { openApp(u) }
        titleLabel.text = "تم"
        linkLabel.text = "افتح جليس وتلقى الرواية انضافت."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.extensionContext?.completeRequest(returningItems: nil) }
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: NSError(domain: "jalees", code: 0))
    }

    /// Opens Jalees through the responder chain (an extension can't call the app directly); the link waits anyway.
    private func openApp(_ url: URL) {
        var r: UIResponder? = self
        let sel = NSSelectorFromString("openURL:")
        while let x = r {
            if x.responds(to: sel), x !== self { _ = x.perform(sel, with: url); return }
            r = x.next
        }
    }
}
