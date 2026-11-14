/* layl.io (Layl | روايات ويب مترجمة إلى العربية). A streaming Next.js site: the page's real content arrives inside
   <div hidden id="S:n"> blocks (a skeleton with aria-busy sits in <main>), so every selector below skips the skeletons.
   Novel: /novels/<slug>; chapter: /novels/<slug>/chapters/<n>. The whole chapter list is on the novel page.
   The site has no search and no paging (a handful of novels): browse reads /novels and filters by ?q= itself. */
(function () {
  'use strict';
  var K = window.SourceKit, S = window.Sources = window.Sources || {};
  var HOME = 'https://layl.io/';
  var MONTHS = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };

  function isoDate(s) {
    var m = /([A-Z][a-z]{2})\w*\s+(\d{1,2}),\s*(\d{4})/.exec(s || '');
    if (!m || !MONTHS[m[1]]) return '';
    return m[3] + '-' + (MONTHS[m[1]] < 10 ? '0' : '') + MONTHS[m[1]] + '-' + (m[2].length < 2 ? '0' : '') + m[2];
  }
  function lines(el) { return el ? (el.textContent || '').replace(/\r/g, '').split(/\n+/).map(function (x) { return x.replace(/\s+/g, ' ').trim(); }).filter(Boolean) : []; }

  S.layl = {
    id: 'layl', name: 'Layl | روايات ويب مترجمة إلى العربية', home: HOME, lang: 'ar',
    hosts: ['layl.io', 'www.layl.io'],
    isSeries: function (url) { return /\/novels\/[^\/?#]+\/?([?#].*)?$/.test(url) && !/\/novels\/genre\//.test(url); },
    seriesUrl: function (doc, url) {
      var a = doc.querySelector('a.chapter-bar-back[href]');
      if (a) return K.abs(a.getAttribute('href'), url).split(/[?#]/)[0];
      var m = /^(https?:\/\/[^\/]+\/novels\/[^\/?#]+)\/chapters\//.exec(url);
      return m ? m[1] : '';
    },
    clean: [/^(المترجم|المترجمة|ترجمة|تدقيق|المدقق|المحرر)\s*[:：-]/, /\blayl\b/i, /^(اقرأ|إقرأ) (المزيد|أيضا)/, /^(تابعونا|انضم(وا)? إلى)/],

    series: function (doc, url) {
      try {
        var head = doc.querySelector('section.novel-header:not([aria-busy])');
        var h1 = head ? head.querySelector('h1.novel-header-title') : null;
        if (!h1) return { error: 'no-title' };
        var st = K.txt(head.querySelector('[class*="Badge-module"][class*="status"]'));
        var status = /complete/i.test(st) ? 'مكتملة' : /ongoing/i.test(st) ? 'مستمرة' : /hiatus/i.test(st) ? 'متوقفة' : st;
        var orig = head.querySelectorAll('.novel-license-line bdi.orig');
        var rows = this.list(doc, url);
        var cnt = K.digits(K.txt(doc.querySelector('.chapter-list-heading-count')));
        var img = head.querySelector('img.novel-header-cover');
        return {
          title: K.txt(h1), titleEn: K.txt(head.querySelector('.novel-header-title-en')),
          author: orig.length > 1 ? K.txt(orig[orig.length - 1]) : '',
          cover: img ? K.abs(img.getAttribute('src') || '', url) : '',
          summary: lines(head.querySelector('.novel-synopsis')).join('\n\n').slice(0, 4000), status: status,
          total: cnt ? parseInt(cnt, 10) : rows.length, translator: '',
          genres: Array.prototype.map.call(head.querySelectorAll('a.genre-chip'), K.txt).filter(Boolean).slice(0, 10),
          listPages: [], rows: rows
        };
      } catch (e) { return { error: 'bad-page' }; }
    },

    list: function (doc, url) {
      var rows = [], seen = {};
      Array.prototype.forEach.call(doc.querySelectorAll('ol.chapter-list a.chapter-list-row[href]'), function (a) {
        var href = K.abs(a.getAttribute('href'), url); if (!href || seen[href]) return; seen[href] = 1;
        var m = /\/chapters\/(\d+)/.exec(href); if (!m) return;
        rows.push({ url: href, num: m[1], title: K.txt(a.querySelector('.chapter-list-title')), volume: '', date: isoDate(K.txt(a.querySelector('.chapter-list-date'))) });
      });
      rows.sort(function (x, y) { return parseInt(y.num, 10) - parseInt(x.num, 10); });
      return rows;
    },

    chapter: function (doc, url) {
      try {
        var box = doc.querySelector('.chapter-prose');
        if (!box) return { error: 'no-content' };
        var ps = [];
        Array.prototype.forEach.call(box.children, function (el) {
          var tag = el.tagName.toLowerCase();
          if (tag === 'hr') { if (ps.length && ps[ps.length - 1] !== '* * *') ps.push('* * *'); return; }
          if (!/^(p|div|blockquote|h2|h3)$/.test(tag)) return;
          if (el.hasAttribute('hidden') || el.getAttribute('aria-hidden') === 'true') return;
          var st = (el.getAttribute('style') || '').replace(/\s+/g, '').toLowerCase();
          if (/display:none|visibility:hidden|opacity:0(?![.\d])|font-size:0(?![.\d])/.test(st)) return;
          Array.prototype.forEach.call(el.querySelectorAll('br'), function (b) { b.parentNode.replaceChild(doc.createTextNode(' '), b); });
          var t = K.txt(el); if (t) ps.push(t);
        });
        while (ps.length && ps[ps.length - 1] === '* * *') ps.pop();
        var c = K.tidy(ps, this.clean, 4);
        var nx = doc.querySelector('a[aria-label="Next chapter"][href]'), pv = doc.querySelector('a[aria-label="Previous chapter"][href]');
        return { title: K.txt(doc.querySelector('h1.chapter-title-arabic')), paras: c.paras, removed: c.removed,
                 next: nx ? K.abs(nx.getAttribute('href'), url) : '', prev: pv ? K.abs(pv.getAttribute('href'), url) : '' };
      } catch (e) { return { error: 'bad-page' }; }
    },

    /* /novels lists everything and ignores ?q=, so browse() filters by it */
    browseURL: function (kind, page, q) {
      return HOME + 'novels' + (kind === 'search' && q ? '?q=' + encodeURIComponent(q) : '');
    },
    browse: function (doc, url) {
      try {
        var q = '';
        try { q = (new URL(url).searchParams.get('q') || '').trim().toLowerCase(); } catch (e0) { q = ''; }
        var items = [], seen = {};
        Array.prototype.forEach.call(doc.querySelectorAll('ul.novel-grid:not([aria-busy]) article.novel-card'), function (a) {
          var link = a.querySelector('.novel-card-title a[href]'); if (!link) return;
          var href = K.abs(link.getAttribute('href'), url).split(/[?#]/)[0];
          if (seen[href]) return; seen[href] = 1;
          var title = K.txt(link), slug = href.split('/').pop();
          try { slug = decodeURIComponent(slug); } catch (e1) { /* keep slug */ }
          var hay = (title + ' ' + K.txt(a.querySelector('.novel-card-synopsis')) + ' ' + slug.replace(/-/g, ' ')).toLowerCase();
          if (q && hay.indexOf(q) < 0) return;
          var img = a.querySelector('img.novel-card-cover');
          items.push({ url: href, title: title, cover: img ? K.abs(img.getAttribute('src') || '', url) : '',
                       meta: K.txt(a.querySelector('.novel-card-latest .bl-ar')) || K.txt(a.querySelector('.novel-card-latest a')) });
        });
        return { items: items, next: false };
      } catch (e) { return { error: 'bad-page' }; }
    }
  };
})();
