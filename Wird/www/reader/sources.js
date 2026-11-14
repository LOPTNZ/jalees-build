/* Site definitions: one per site, never per novel. The app downloads a page itself, then asks a definition to read it.
   Every function gets a parsed document and the page's address, and returns plain data.

   series(doc, url)  -> {title, author, cover, summary, status, total, listPages:[url…], rows:[…]}   (rows = list(doc,url))
   list(doc, url)    -> [{url, num, title, volume, date}]        newest first, as the site shows them
   chapter(doc, url) -> {title, paras:[…], removed, next, prev}

   The same file runs in the app (a hidden web view) and in any desktop browser, so a site can be fixed and tested on a PC. */
(function () {
  'use strict';

  function txt(el) { return el ? (el.textContent || '').replace(/ /g, ' ').replace(/[ \t\r\n]+/g, ' ').trim() : ''; }
  function abs(href, base) { try { return new URL(href, base).href; } catch (e) { return ''; } }
  function meta(doc, name) { var m = doc.querySelector('meta[property="' + name + '"],meta[name="' + name + '"]'); return m ? (m.getAttribute('content') || '').trim() : ''; }
  function digits(s) { return String(s || '').replace(/[٠-٩]/g, function (d) { return '٠١٢٣٤٥٦٧٨٩'.indexOf(d); }).replace(/[^\d]/g, ''); }

  /* Paragraphs of a content block, in reading order, skipping what the site hides or injects. */
  function paragraphs(box, skipSel) {
    var out = [], seen = box.querySelectorAll('p, h1, h2, h3, h4, li, blockquote, div');
    for (var i = 0; i < seen.length; i++) {
      var el = seen[i];
      if (skipSel && el.closest(skipSel)) continue;
      if (el.querySelector('p, div, li, blockquote, h1, h2, h3, h4')) continue;          /* only leaf blocks */
      if (el.closest('script, style, noscript, iframe, ins, form, button, nav')) continue;
      var st = (el.getAttribute('style') || '').replace(/\s+/g, '').toLowerCase();
      if (/display:none|visibility:hidden|opacity:0(?![.\d])|font-size:0(?![.\d])|height:0(?![.\d])|text-indent:-\d{3,}/.test(st)) continue;
      if (el.hasAttribute('hidden') || el.getAttribute('aria-hidden') === 'true') continue;
      var t = txt(el);
      if (t) out.push(t);
    }
    if (!out.length) { var t0 = txt(box); if (t0) out = t0.split(/\n{2,}/); }
    return out;
  }
  /* Drops site chatter from the first and last few lines only, so story text is never touched. */
  function tidy(paras, rules, edge) {
    var n = paras.length, removed = 0, keep = [];
    edge = edge || 6;
    for (var i = 0; i < n; i++) {
      var p = paras[i], nearEdge = i < 3 || i >= n - edge, hit = false;
      if (nearEdge) for (var r = 0; r < rules.length; r++) if (rules[r].test(p)) { hit = true; break; }
      if (hit) removed++; else keep.push(p);
    }
    return { paras: keep, removed: removed };
  }

  var S = {};

  /* ---------- ملوك الروايات (kolnovel.com) ---------- */
  S.kolnovel = {
    id: 'kolnovel', name: 'ملوك الروايات', home: 'https://kolnovel.com/', lang: 'ar',
    hosts: ['kolnovel.com', 'www.kolnovel.com'],
    isSeries: function (url) { return /\/series\/[^/]+\/?/.test(url); },
    /* a chapter page links back to its novel */
    seriesUrl: function (doc, url) {
      var links = doc.querySelectorAll('.kol-chapter-bar__jump[href], a[href*="/series/"]');
      for (var i = 0; i < links.length; i++) {
        var h = abs(links[i].getAttribute('href'), url).split('#')[0];
        if (/\/series\/[^\/?#]+\/?$/.test(h)) return h;
      }
      return '';
    },
    clean: [/^أعيدت ترجمة هذا الفصل/, /^اللهم\s/, /إن لاحظتم أي خطأ/, /^ترجمة\s*[:：-]/, /^(تدقيق|المترجم|المدقق)\s*[:：-]/,
            /^(إقرأ|اقرأ) (المزيد|أيضا)/, /ملوك الروايات/, /kolnovel/i, /^\s*(تابعونا|انضم(وا)? إلى)/],

    series: function (doc, url) {
      var root = doc.querySelector('[data-kol-series-title]');
      var title = (root && root.getAttribute('data-kol-series-title')) || meta(doc, 'og:title').replace(/\s*[–-]\s*ملوك الروايات\s*$/, '') || txt(doc.querySelector('h1'));
      var all = doc.querySelector('[data-kol-chapter-volume="__kol_all__"]');
      var pages = all ? parseInt(all.getAttribute('data-kol-volume-pages') || '1', 10) : 1;
      var count = all ? parseInt(digits(txt(all.querySelector('.kol-series-editorial__volume-count'))) || '0', 10) : 0;
      var base = url.split('#')[0].split('?')[0], list = [];
      for (var i = 1; i <= Math.max(1, pages); i++) list.push(base + '?chapter_volume=__kol_all__&chapter_search&chapter_order=newest&chapter_page=' + i);
      var info = {};
      doc.querySelectorAll('[class*="series"] dt, [class*="series"] th, [class*="meta"] dt').forEach(function (k) {
        var v = k.nextElementSibling; if (v) info[txt(k).replace(/[:：]\s*$/, '')] = txt(v);
      });
      var syn = doc.querySelector('[data-kol-series-synopsis], [class*="synopsis"] [class*="content"], [class*="synopsis"], [itemprop="description"]');
      return {
        title: title, author: info['المؤلف'] || info['الكاتب'] || txt(doc.querySelector('[itemprop="author"], a[href*="/writer/"], a[href*="/author/"]')),
        cover: (function () {
          var im = doc.querySelector('.kol-series-editorial__cover img, [itemprop="image"] img, .kol-series-cover img');
          var src = im ? (im.getAttribute('src') || '') : '';
          return src ? encodeURI(decodeURI(abs(src, url))) : '';
        })(),
        summary: txt(syn).slice(0, 4000), status: info['الحالة'] || '', total: count, listPages: list, rows: this.list(doc, url),
        translator: Array.prototype.map.call(doc.querySelectorAll('.kol-series-translators__label strong'), txt).filter(Boolean).slice(0, 4).join('، '),
        genres: Array.prototype.map.call(doc.querySelectorAll('a[href*="/genre/"]'), txt).filter(function (g, i, all) { return g && all.indexOf(g) === i; }).slice(0, 10)
      };
    },

    browseURL: function (kind, page, q) {
      if (kind === 'search') return 'https://kolnovel.com/?s=' + encodeURIComponent(q || '');
      var base = 'https://kolnovel.com/series/' + (kind === 'popular' ? '?order=popular' : '');
      return page > 1 ? base + (base.indexOf('?') >= 0 ? '&' : '?') + 'paged=' + page : base;
    },
    browse: function (doc, url) {
      var cards = doc.querySelectorAll('article.kol-series-archive__item, article.kol-search__item, article[itemtype*="CreativeWork"]'), items = [], seen = {};
      Array.prototype.forEach.call(cards, function (a) {
        var link = a.querySelector('a[href*="/series/"]'); if (!link) return;
        var href = abs(link.getAttribute('href'), url).split('#')[0];
        if (!/\/series\/[^\/?#]+\/?$/.test(href) || seen[href]) return; seen[href] = 1;
        var img = a.querySelector('img'), label = link.getAttribute('aria-label') || '';
        var title = (img && img.getAttribute('alt')) || txt(a.querySelector('h2, h3, [itemprop="name"]')) || label.split('،')[0];
        var bits = label.split('،').map(function (x) { return x.trim(); }).slice(1);
        items.push({ url: href, title: title, cover: img ? encodeURI(decodeURI(abs(img.getAttribute('src') || '', url))) : '', meta: bits.join(' · ') });
      });
      var nx = doc.querySelector('a.next, a[rel="next"], .pagination a.next, a[href*="paged="]:last-of-type');
      return { items: items, next: !!(nx && items.length) };
    },
    list: function (doc, url) {
      var rows = [], seen = {};
      var scope = doc.querySelector('[data-kol-chapter-volume="__kol_all__"]') || doc;
      scope.querySelectorAll('li[data-kol-chapter-row]').forEach(function (li) {
        var a = li.querySelector('a[href]'); if (!a) return;
        var href = abs(a.getAttribute('href'), url); if (!href || seen[href]) return; seen[href] = 1;
        var n = li.querySelector('[data-kol-chapter-number]'), t = li.querySelector('[data-kol-chapter-title]'),
            v = li.querySelector('.kol-series-chapter__volume'), d = li.querySelector('time[datetime]');
        rows.push({ url: href, num: n ? n.getAttribute('data-kol-chapter-number') : '', title: txt(t), volume: txt(v), date: d ? d.getAttribute('datetime') : '' });
      });
      return rows;
    },

    chapter: function (doc, url) {
      var box = doc.querySelector('#kol_content, [data-kol-reader-content], .epcontent');
      if (!box) return { error: 'no-content' };
      var head = box.querySelector(':scope > blockquote'), title = head ? txt(head) : '';
      if (title.length > 160) title = '';
      var ps = paragraphs(box, title ? 'blockquote' : null);
      if (!title && ps.length && /^(الفصل|فصل|chapter)\s*[\d٠-٩]/i.test(ps[0]) && ps[0].length < 160) title = ps.shift();
      if (title && ps.length && ps[0] === title) ps.shift();
      var c = tidy(ps, this.clean, 6);
      var nx = doc.querySelector('a[rel="next"][href]'), pv = doc.querySelector('a[rel="prev"][href]');
      return { title: title, paras: c.paras, removed: c.removed, next: nx ? abs(nx.getAttribute('href'), url) : '', prev: pv ? abs(pv.getAttribute('href'), url) : '' };
    }
  };

  /* ---------- a section of an EPUB book (local file, read through the app) ---------- */
  S.epub = {
    id: 'epub', name: 'كتاب EPUB', home: '', lang: 'ar', hosts: [],
    chapter: function (doc, url) {
      var body = doc.body || doc.documentElement, out = [];
      var walk = function (el) {
        for (var n = el.firstElementChild; n; n = n.nextElementSibling) {
          var tag = n.tagName.toLowerCase();
          if (/^(script|style|head|nav|aside)$/.test(tag)) continue;
          if (tag === 'img' || tag === 'image') {
            var src = n.getAttribute('src') || n.getAttribute('xlink:href') || n.getAttribute('href');
            if (src) out.push('￼img:' + abs(src, url));
            continue;
          }
          if (/^(p|h1|h2|h3|h4|h5|h6|li|blockquote|pre|dt|dd|figcaption)$/.test(tag) && !n.querySelector('p, div, img, image')) {
            var t = txt(n); if (t) out.push(t); continue;
          }
          if (n.querySelector('img, image')) { walk(n); continue; }
          if (tag === 'div' && !n.querySelector('p, div, li, h1, h2, h3, h4, h5, h6, blockquote')) { var d = txt(n); if (d) out.push(d); continue; }
          walk(n);
        }
      };
      walk(body);
      var h = doc.querySelector('h1, h2, h3'), title = h ? txt(h) : (doc.title || '');
      if (out.length && title && out[0] === title) out.shift();
      return { title: title, paras: out, removed: 0, next: '', prev: '' };
    }
  };

  /* ---------- entry points used by the app ---------- */
  window.Sources = S;
  /* the helpers, for the sites that live in their own files (www/reader/sites/<id>.js) */
  window.SourceKit = { txt: txt, abs: abs, meta: meta, digits: digits, paragraphs: paragraphs, tidy: tidy };
  window.SourceFor = function (url) {
    var h = ''; try { h = new URL(url).hostname.toLowerCase(); } catch (e) { return null; }
    for (var k in S) if (S[k].hosts.indexOf(h) >= 0) return k;
    return null;
  };
  window.SourceBrowseURL = function (site, kind, page, q) { var s = S[site]; return s && s.browseURL ? s.browseURL(kind, page, q) : ''; };
  window.SourceIsSeries = function (site, url) { var s = S[site]; return !!(s && (!s.isSeries || s.isSeries(url))); };
  window.SourceList = function () { return Object.keys(S).filter(function (k) { return S[k].browse; }).map(function (k) { return { id: k, name: S[k].name, home: S[k].home, lang: S[k].lang }; }); };
  window.SourceRun = function (site, fn, html, url) {
    var s = S[site]; if (!s || typeof s[fn] !== 'function') return { error: 'unknown-source' };
    var doc = new DOMParser().parseFromString(html, 'text/html');
    if (/just a moment|cf-chl|challenge-platform|attention required/i.test((doc.title || '') + ' ' + html.slice(0, 3000)) && !doc.querySelector('p')) return { error: 'blocked' };
    try { return s[fn](doc, url); } catch (e) { return { error: 'parse', detail: String(e && e.message || e) }; }
  };
})();
