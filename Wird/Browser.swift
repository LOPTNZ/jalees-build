import UIKit
import WebKit

/// A small browser on the big book sites. You find your edition, tap «استيراد هذا الكتاب», and the page's book data
/// (title, author, pages, ISBN, language) and its cover candidates go back to the web app.
final class BookBrowser: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    struct Site {
        let name: String
        let search: String
    }

    static let sites: [Site] = [
        Site(name: "Goodreads", search: "https://www.goodreads.com/search?q=%@"),
        Site(name: "Google Books", search: "https://www.google.com/search?tbm=bks&q=%@"),
        Site(name: "أبجد", search: "https://www.abjjad.com/search?kw=%@"),
        Site(name: "Amazon", search: "https://www.amazon.sa/s?k=%@&i=stripbooks"),
        Site(name: "Open Library", search: "https://openlibrary.org/search?q=%@"),
        Site(name: "جملون", search: "https://jamalon.com/ar/catalogsearch/result/?q=%@"),
        Site(name: "صور Google", search: "https://www.google.com/search?tbm=isch&q=%@"),
    ]

    static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private var web: WKWebView!
    private let query: String
    private var siteIndex: Int
    private var done: (([String: Any]?) -> Void)?
    private let importButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var backItem: UIBarButtonItem!
    private var forwardItem: UIBarButtonItem!
    private var siteItem: UIBarButtonItem!
    private var observers: [NSKeyValueObservation] = []

    init(query: String, site: Int, done: @escaping ([String: Any]?) -> Void) {
        self.query = query
        self.siteIndex = max(0, min(site, BookBrowser.sites.count - 1))
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = BookBrowser.safariUA
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)

        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)

        let bar = UIView()
        bar.backgroundColor = .secondarySystemBackground
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        var c = UIButton.Configuration.filled()
        c.title = "استيراد هذا الكتاب".tr
        c.image = UIImage(systemName: "square.and.arrow.down")
        c.imagePadding = 8
        c.cornerStyle = .large
        c.buttonSize = .large
        importButton.configuration = c
        importButton.addTarget(self, action: #selector(doImport), for: .touchUpInside)
        importButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(importButton)

        let hint = UILabel()
        hint.text = "افتح صفحة الكتاب نفسه، ثم اضغط استيراد".tr
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(hint)

        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: bar.topAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            importButton.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            importButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            importButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])

        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.finish(nil)
        })
        backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in
            self?.web.goBack()
        })
        forwardItem = UIBarButtonItem(image: UIImage(systemName: "chevron.forward"), primaryAction: UIAction { [weak self] _ in
            self?.web.goForward()
        })
        siteItem = UIBarButtonItem(title: BookBrowser.sites[siteIndex].name, image: nil, primaryAction: nil, menu: siteMenu())
        navigationItem.rightBarButtonItems = [siteItem, forwardItem, backItem]

        observers = [
            web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] w, _ in self?.backItem.isEnabled = w.canGoBack },
            web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] w, _ in self?.forwardItem.isEnabled = w.canGoForward },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                guard let self = self else { return }
                self.progress.progress = Float(w.estimatedProgress)
                self.progress.isHidden = w.estimatedProgress >= 1
            },
            web.observe(\.title, options: [.new]) { [weak self] w, _ in self?.navigationItem.title = w.title },
        ]
        load(site: siteIndex)
    }

    private func siteMenu() -> UIMenu {
        let actions = BookBrowser.sites.enumerated().map { (i, s) in
            UIAction(title: s.name, state: i == siteIndex ? .on : .off) { [weak self] _ in self?.load(site: i) }
        }
        return UIMenu(title: "ابحث في".tr, children: actions)
    }

    private func load(site: Int) {
        siteIndex = site
        siteItem?.title = BookBrowser.sites[site].name
        siteItem?.menu = siteMenu()
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        let s = BookBrowser.sites[site].search.replacingOccurrences(of: "%@", with: q)
        if let u = URL(string: s) { web.load(URLRequest(url: u)) }
    }

    @objc private func doImport() {
        importButton.isEnabled = false
        web.evaluateJavaScript(BookBrowser.extractJS) { [weak self] result, _ in
            guard let self = self else { return }
            self.importButton.isEnabled = true
            var o = (result as? [String: Any]) ?? [:]
            o["url"] = self.web.url?.absoluteString ?? ""
            o["site"] = self.web.url?.host ?? BookBrowser.sites[self.siteIndex].name
            let title = (o["title"] as? String) ?? ""
            let images = (o["images"] as? [Any]) ?? []
            if title.isEmpty && images.isEmpty {
                let a = UIAlertController(title: "ما لقيت بيانات كتاب".tr, message: "افتح صفحة الكتاب نفسه (مو صفحة نتائج البحث)، ثم اضغط استيراد.".tr, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "حسنًا".tr, style: .default))
                self.present(a, animated: true)
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.finish(o)
        }
    }

    private func finish(_ o: [String: Any]?) {
        guard let d = done else { return }
        done = nil
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            (navigationController ?? self).dismiss(animated: true) { d(o) }
        } else {
            d(o)
        }
    }

    // swiped the sheet down
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let d = done {
            done = nil
            d(nil)
        }
    }

    // links that open a new window load here instead
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
    }

    /// Runs in the page: JSON-LD first, then site specifics (Amazon), then meta tags and the page text.
    static let extractJS = """
    (function(){
      function tx(s){s=String(s||'');if(/&[#a-z0-9]+;/i.test(s)){var t=document.createElement('textarea');t.innerHTML=s;s=t.value}return s.replace(/\\s+/g,' ').trim()}
      function abs(u){try{return new URL(u,location.href).href}catch(e){return ''}}
      function meta(n){var m=document.querySelector('meta[property="'+n+'"],meta[name="'+n+'"],meta[itemprop="'+n+'"]');return m?(m.getAttribute('content')||''):''}
      var o={title:'',author:'',pages:0,isbn:'',lang:'',cover:'',images:[],publisher:'',year:'',book:false};
      function visit(x){if(!x||typeof x!=='object')return;if(Array.isArray(x)){x.forEach(visit);return}
        if(x['@graph'])visit(x['@graph']);
        var t=[].concat(x['@type']||[]).join(' ');
        if(/Book|Product|CreativeWork/.test(t)){
          if(/Book|Product/.test(t))o.book=true;
          if(!o.title&&x.name)o.title=tx(x.name);
          if(!o.author&&x.author){o.author=[].concat(x.author).map(function(a){return typeof a==='string'?a:(a&&a.name)}).filter(Boolean).slice(0,3).join('، ')}
          if(!o.pages&&x.numberOfPages)o.pages=parseInt(x.numberOfPages,10)||0;
          if(!o.isbn&&x.isbn)o.isbn=String(x.isbn);
          if(!o.lang&&x.inLanguage)o.lang=String(typeof x.inLanguage==='object'?(x.inLanguage.name||x.inLanguage.alternateName||''):x.inLanguage);
          var im=x.image;if(im){im=[].concat(im)[0];if(im&&typeof im==='object')im=im.url||im.contentUrl;if(im&&!o.cover)o.cover=abs(im)}
          if(!o.publisher&&x.publisher)o.publisher=tx(typeof x.publisher==='object'?x.publisher.name:x.publisher);
          if(!o.year&&x.datePublished)o.year=String(x.datePublished).slice(0,4);
          if(x.workExample)visit(x.workExample);
        }}
      [].slice.call(document.querySelectorAll('script[type="application/ld+json"]')).forEach(function(s){try{visit(JSON.parse(s.textContent))}catch(e){}});
      var h=location.hostname,body=document.body?document.body.innerText:'';
      if(/amazon\\./.test(h)){
        var pt=document.getElementById('productTitle');if(pt){o.title=tx(pt.textContent);o.book=true}
        var by=[].slice.call(document.querySelectorAll('#bylineInfo .author > a, #bylineInfo .author .a-link-normal'));if(by.length)o.author=by.map(function(a){return tx(a.textContent)}).filter(Boolean).slice(0,3).join('، ');
        var li=document.querySelector('#landingImage,#imgBlkFront,#ebooksImgBlkFront,#main-image');
        if(li){var hi=li.getAttribute('data-old-hires'),dyn=li.getAttribute('data-a-dynamic-image');
          if(hi)o.cover=hi;else if(dyn){try{var m=JSON.parse(dyn),best='',bw=0;Object.keys(m).forEach(function(k){if(m[k][0]>bw){bw=m[k][0];best=k}});if(best)o.cover=best}catch(e){}}else if(li.src)o.cover=li.src}
      }
      if(/book|product/i.test(meta('og:type')))o.book=true;
      if(!o.title)o.title=tx(meta('og:title')||document.title);
      if(!o.cover)o.cover=abs(meta('og:image'));
      if(!o.author)o.author=tx(meta('books:author')||meta('book:author')||meta('author'));
      if(!o.isbn)o.isbn=meta('books:isbn')||meta('book:isbn')||meta('isbn');
      if(!o.pages){var ip=document.querySelector('[itemprop="numberOfPages"]');if(ip)o.pages=parseInt(tx(ip.textContent||ip.getAttribute('content')),10)||0}
      if(!o.pages){var mm=body.match(/(?:عدد الصفحات|الصفحات|Print length|Pages|Length)\\s*[:：]?\\s*(\\d{2,5})/i)||body.match(/(\\d{2,5})\\s*(?:pages|صفحة|صفحه)/i);if(mm)o.pages=parseInt(mm[1],10)||0}
      if(!o.isbn){var mi=body.match(/97[89][-\\s]?\\d{1,5}[-\\s]?\\d{1,7}[-\\s]?\\d{1,7}[-\\s]?\\d/);if(mi)o.isbn=mi[0].replace(/[^\\d]/g,'')}
      if(!o.lang){var ml=body.match(/(?:Edition language|Language|اللغة)\\s*[:：]?\\s*([A-Za-z\\u0600-\\u06FF]+)/);if(ml)o.lang=ml[1]}
      var seen={},imgs=[];function add(u,a){if(!u||seen[u])return;if(u.indexOf('data:')===0&&u.length>600000)return;seen[u]=1;imgs.push({u:u,a:a})}
      if(o.cover)add(o.cover,1e9);
      [].slice.call(document.images).forEach(function(im){var w=im.naturalWidth,hh=im.naturalHeight;if(w<90||hh<120)return;var r=w/hh;if(r<.4||r>1.1)return;
        var src=im.currentSrc||im.src;if(!src||/sprite|logo|avatar|icon|badge|banner/i.test(src))return;var hi2=im.getAttribute('data-old-hires');add(hi2||src,w*hh)});
      imgs.sort(function(a,b){return b.a-a.a});o.images=imgs.slice(0,12).map(function(x){return x.u});
      return o;
    })()
    """
}
