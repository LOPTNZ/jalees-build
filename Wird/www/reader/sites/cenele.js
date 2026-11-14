/* فضاء الروايات (cenele.com): a Madara (WordPress) site with a custom theme.
   The novel page only shows the last 8 chapters in HTML (the full list needs a POST), so the chapter list comes from the
   site's own public JSON: /wp-json/nhv/v1/novels/<post id>/chapters?per_page=300&page=N (plain GET, no login).
   The API gives no addresses, so the novel's folder is carried in the URL as `&n=<slug>` (the server ignores it). */
(function () {
  'use strict';
  var K = window.SourceKit, txt = K.txt, abs = K.abs, meta = K.meta, digits = K.digits;
  var HOME = 'https://cenele.com/', PER = 300;

  function cover(img, url) {
    if (!img) return '';
    var src = img.getAttribute('data-src') || img.getAttribute('src') || '';
    return src && !/^data:/.test(src) ? abs(src, url) : '';
  }
  function baseOf(url) { return url.split('#')[0].split('?')[0].replace(/\/+$/, '') + '/'; }
  /* the text of a <strong> that follows a label in the novel page's facts block */
  function fact(doc, label) {
    var divs = doc.querySelectorAll('.nhv-novel-meta div, .nhv-novel-status');
    for (var i = 0; i < divs.length; i++) {
      var sp = divs[i].querySelector(':scope > span'), st = divs[i].querySelector(':scope > strong');
      if (sp && st && txt(sp).indexOf(label) >= 0) return txt(st);
    }
    return '';
  }
  function postId(doc) {
    var m = (doc.body && doc.body.getAttribute('class') || '').match(/\bpostid-(\d+)/);
    if (m) return m[1];
    var t = doc.querySelector('.nhv-gems-box[data-manga-id], .nhv-reading-topbar[data-id]');
    if (t) return t.getAttribute('data-manga-id') || t.getAttribute('data-id') || '';
    var html = doc.documentElement ? doc.documentElement.innerHTML : '';
    m = html.match(/"manga_id":"(\d+)"/);
    return m ? m[1] : '';
  }
  function isoDate(s) { return String(s || '').replace(' ', 'T'); }
  function jsonOf(doc) {
    var t = (doc.body ? doc.body.textContent : '') || '';
    t = t.trim();
    if (t.charAt(0) !== '{') return null;
    try { return JSON.parse(t); } catch (e) { return null; }
  }

  Sources.cenele = {
    id: 'cenele', name: 'فضاء الروايات', home: HOME, lang: 'ar',
    hosts: ['cenele.com', 'www.cenele.com'],
    isSeries: function (url) { return /\/cont\/(?!page\/)[^\/?#]+\/?(?:[?#].*)?$/.test(url); },
    seriesUrl: function (doc, url) {
      var a = doc.querySelector('a.manga_page[href]');
      if (a) return baseOf(abs(a.getAttribute('href'), url));
      var w = doc.querySelector('[data-nhv-novel-url]');
      if (w) return baseOf(abs(w.getAttribute('data-nhv-novel-url'), url));
      var m = url.match(/^(https?:\/\/[^\/]+\/cont\/[^\/?#]+)\//);
      return m ? m[1] + '/' : '';
    },
    clean: [/^بسم الله الرحمن الرحيم/, /^(المترجم|مترجمكم|ترجمة|تدقيق|المدقق)\s*[:：-]/, /^[ـ\-—_=*•\s]{4,}$/,
            /^قراءة ممتعة/, /^لا تنسوا الدعم/, /^سبحان الله/, /^استغفر الله/, /^لا إ?له إلا الله|^لا اله الا الله/, /^سبحانك اللهم/,
            /اذا وجدتم اي اخطاء/, /^إذا وجدتم أي أخطاء/, /(تطبيق|موقع) فضاء الروايات/, /cenele/i, /^(تابعونا|انضموا|للدعم)/],

    series: function (doc, url) {
      var title = txt(doc.querySelector('h1.nhv-novel-title')) || meta(doc, 'og:title').replace(/^رواية\s+/, '');
      if (!title) return { error: 'no-title' };
      var base = baseOf(url), id = postId(doc);
      var total = parseInt(digits(fact(doc, 'الفصول')) || '0', 10);
      var listPages = [base];
      if (id) {
        var pages = Math.max(1, Math.ceil((total || PER) / PER));
        for (var p = 1; p <= pages; p++) {
          listPages.push(HOME + 'wp-json/nhv/v1/novels/' + id + '/chapters?per_page=' + PER + '&page=' + p + '&n=' + encodeURIComponent(base.split('/cont/')[1].replace(/\/$/, '')));
        }
      }
      var syn = doc.querySelector('.nhv-novel-synopsis'), summary = '';
      if (syn) {
        summary = Array.prototype.map.call(syn.querySelectorAll('p'), txt).filter(Boolean).join('\n\n');
        if (!summary) summary = txt(syn);
      }
      var tr = doc.querySelector('.nhv-novel-meta a[href*="/cont-artist/"]'), au = doc.querySelector('.nhv-novel-meta a[href*="/cont-author/"]');
      return {
        title: title, author: txt(au), cover: cover(doc.querySelector('.nhv-novel-cover img'), url) || meta(doc, 'og:image'),
        summary: summary.slice(0, 4000), status: fact(doc, 'الحالة'), total: total, translator: txt(tr),
        genres: Array.prototype.map.call(doc.querySelectorAll('.nhv-novel-genres a'), txt).filter(Boolean).slice(0, 10),
        listPages: listPages, rows: id ? [] : this.list(doc, url)
      };
    },

    /* Either the novel page (last 8 chapters) or one page of the chapters JSON. Newest first. */
    list: function (doc, url) {
      var rows = [], seen = {}, j = jsonOf(doc);
      if (j) {
        var data = j.data || {}, arr = data.chapters || [];
        var nm = url.match(/[?&]n=([^&#]+)/);
        if (!nm) return rows;
        var base = HOME + 'cont/' + nm[1] + '/';
        arr.forEach(function (c) {
          var name = String(c.chapter_name || ''), nn = name.match(/(\d+)/), num = nn ? nn[1] : '';
          if (!c.chapter_slug || (num && num.length > 7)) return;     /* the translator's 999999999999 note page is not a chapter */
          var href = base + (c.volume_slug ? c.volume_slug + '/' : '') + c.chapter_slug + '/';
          if (seen[href]) return; seen[href] = 1;
          var rest = String(c.chapter_name_extend || '').trim();
          if (!rest) rest = name.replace(/^\s*(الفصل|فصل)?\s*[\d٠-٩]+\s*[:：\-–—]?\s*/, '').trim();
          rows.push({ url: href, num: num, title: rest, volume: c.volume_name || '', date: isoDate(c.date) });
        });
        return rows;
      }
      doc.querySelectorAll('li.wp-manga-chapter').forEach(function (li) {
        var a = li.querySelector('a[href]'); if (!a) return;
        var href = abs(a.getAttribute('href'), url); if (!href || seen[href]) return;
        var name = txt(a), nn = name.match(/(\d+)/), num = nn ? nn[1] : '';
        if (num && num.length > 7) return;
        seen[href] = 1;
        var d = li.querySelector('.chapter-release-date');
        rows.push({ url: href, num: num, title: name.replace(/^\s*(الفصل|فصل)?\s*[\d٠-٩]+\s*[:：\-–—]?\s*/, '').trim(), volume: '', date: txt(d) });
      });
      return rows;
    },

    chapter: function (doc, url) {
      var box = doc.querySelector('story-fold') || doc.querySelector('.reading-content');
      if (!box) return { error: 'no-content' };
      /* decoys: random-class blockquotes marked inert/data-nosnippet, plus the app promo, PayPal form and the like */
      var skip = '[inert], [data-nosnippet], .nhv-reader-promo, .nhv-reader-store-promo, form, table, aside';
      var ps = K.paragraphs(box, skip).filter(function (t) { return !/^[\s ]*$/.test(t); });
      var h = doc.querySelector('.reading-content h3.chapter-name, h3.chapter-name');
      var title = txt(h);
      /* the text usually repeats «الفصل N : عنوان» as a bold first line, which carries the real chapter name */
      for (var i = 0; i < Math.min(4, ps.length); i++) {
        if (/^(الفصل|فصل)\s*[\d٠-٩]+/.test(ps[i]) && ps[i].length < 160) {
          if (!title || ps[i].length > title.length) title = ps[i];
          ps.splice(i, 1); break;
        }
      }
      var c = K.tidy(ps, this.clean, 10);
      var nx = doc.querySelector('a.next_page[href]'), pv = doc.querySelector('a.prev_page[href]');
      var next = nx ? abs(nx.getAttribute('href'), url) : '', prev = pv ? abs(pv.getAttribute('href'), url) : '';
      if (/-\d{8,}\/?$/.test(next)) next = '';   /* the translator's note page (chapter 999999999999) */
      if (/-\d{8,}\/?$/.test(prev)) prev = '';
      return { title: title, paras: c.paras, removed: c.removed, next: next, prev: prev };
    },

    browseURL: function (kind, page, q) {
      if (kind === 'search') return HOME + (page > 1 ? 'page/' + page + '/' : '') + '?s=' + encodeURIComponent(q || '') + '&post_type=wp-manga';
      var order = kind === 'popular' ? 'views' : 'latest';
      return HOME + 'cont/' + (page > 1 ? 'page/' + page + '/' : '') + '?m_orderby=' + order;
    },
    browse: function (doc, url) {
      var items = [], seen = {};
      doc.querySelectorAll('article.nhv-library-card').forEach(function (a) {
        var l = a.querySelector('.nhv-library-card__title a[href], a.nhv-library-card__cover[href]'); if (!l) return;
        var href = abs(l.getAttribute('href'), url); if (seen[href]) return; seen[href] = 1;
        var chip = txt(a.querySelector('.nhv-library-card__chip')), st = txt(a.querySelector('.nhv-library-card__status'));
        items.push({ url: href, title: txt(a.querySelector('.nhv-library-card__title')), cover: cover(a.querySelector('img'), url),
                     meta: [st, chip].filter(Boolean).join(' · ') });
      });
      doc.querySelectorAll('.c-tabs-item__content').forEach(function (a) {
        var l = a.querySelector('.post-title a[href]'); if (!l) return;
        var href = abs(l.getAttribute('href'), url); if (seen[href]) return; seen[href] = 1;
        var st = a.querySelector('.mg_status .summary-content'), ch = a.querySelector('.latest-chap .chapter');
        items.push({ url: href, title: txt(l), cover: cover(a.querySelector('img'), url),
                     meta: [txt(st), txt(ch)].filter(Boolean).join(' · ') });
      });
      var nx = doc.querySelector('nav.nhv-archive-pagination a.next, .nav-links .nav-previous a[href]');
      return { items: items, next: !!(nx && items.length) };
    }
  };
})();
