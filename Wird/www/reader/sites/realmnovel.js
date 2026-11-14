/* realmnovel.com (realmnovel — عالم الروايات بالعربي). Server-rendered HTML.
   Novel page: /novel/<24-hex id>[/slug]; chapter: /novel/<id>/chapter/<n>. The whole chapter list sits on the novel page,
   but only the first ~50 chapters of each novel are free: the rest are rows with class "is-locked" and their pages answer
   403 (app-only), so the list keeps the open rows and reports the full count in `total`. No popular listing exists. */
(function () {
  'use strict';
  var K = window.SourceKit, S = window.Sources = window.Sources || {};
  var HOME = 'https://realmnovel.com/';

  function novelId(url) { var m = /\/novel\/([0-9a-f]{24})/i.exec(url || ''); return m ? m[1] : ''; }
  function coverOf(img, base) { var s = img ? (img.getAttribute('src') || '') : ''; return s ? K.abs(s, base) : ''; }

  S.realmnovel = {
    id: 'realmnovel', name: 'realmnovel — عالم الروايات بالعربي', home: HOME, lang: 'ar',
    hosts: ['realmnovel.com', 'www.realmnovel.com'],
    isSeries: function (url) { return /\/novel\/[0-9a-f]{24}(\/[^\/?#]*)?\/?([?#].*)?$/i.test(url) && !/\/chapter\/\d+/.test(url); },
    seriesUrl: function (doc, url) {
      var a = doc.querySelector('nav.crumb a[href*="/novel/"]');
      var h = a ? K.abs(a.getAttribute('href'), url) : '';
      var id = novelId(h) || novelId(url);
      return id ? HOME + 'novel/' + id : '';
    },
    clean: [/^(المترجم|المترجمة|ترجمة|تدقيق|المدقق|المحرر)\s*[:：-]/, /^(تحرير|تحرير ومراجعة)\s*[:：-]/, /realmnovel/i, /sky\s*novel/i,
            /^(حمّل|حمل) تطبيق/, /^(اقرأ|إقرأ) (المزيد|أيضا)/, /^نهاية الفصل/, /^(تابعونا|انضم(وا)? إلى)/],

    series: function (doc, url) {
      try {
        var h1 = doc.querySelector('article.novel-head h1');
        if (!h1) return { error: 'no-title' };
        var status = '', total = 0;
        Array.prototype.forEach.call(doc.querySelectorAll('article.novel-head .badge'), function (el) {
          var b = K.txt(el);
          if (/فصل/.test(b) && /\d/.test(b)) total = parseInt(K.digits(b), 10) || 0;
          else if (/مستمرة|مكتملة|متوقفة|منتهية/.test(b)) status = b;
        });
        var rows = this.list(doc, url);
        return {
          title: K.txt(h1), titleEn: K.txt(doc.querySelector('article.novel-head h2.sub')), author: '',
          cover: coverOf(doc.querySelector('img.cover'), url) || K.meta(doc, 'og:image'),
          summary: K.txt(doc.querySelector('article.novel-head .desc')).slice(0, 4000), status: status, total: total, translator: '',
          genres: Array.prototype.map.call(doc.querySelectorAll('article.novel-head a.tag'), K.txt).filter(Boolean).slice(0, 10),
          listPages: [], rows: rows, locked: doc.querySelectorAll('a.chapter-row.is-locked').length
        };
      } catch (e) { return { error: 'bad-page' }; }
    },

    /* every chapter the page lists, newest first; the ones the site keeps for its app are marked locked (a lock in
       the app's list) */
    list: function (doc, url) {
      var rows = [], seen = {};
      Array.prototype.forEach.call(doc.querySelectorAll('a.chapter-row[href*="/chapter/"]'), function (a) {
        var locked = a.classList.contains('is-locked');
        var href = K.abs(a.getAttribute('href'), url); if (!href || seen[href]) return; seen[href] = 1;
        var m = /\/chapter\/(\d+)/.exec(href); if (!m) return;
        var parts = K.txt(a.querySelector('span')).split(/\s+[—–-]\s+/), t = (parts.length > 1 ? parts.slice(1).join(' — ') : '').trim();
        if (/^(الفصل|فصل)\s*[\d٠-٩]+\s*$/.test(t)) t = '';
        rows.push({ url: href, num: m[1], title: t, volume: '', date: '', locked: locked });
      });
      rows.sort(function (x, y) { return parseInt(y.num, 10) - parseInt(x.num, 10); });
      return rows;
    },

    chapter: function (doc, url) {
      try {
        var box = doc.querySelector('.chapter-content');
        if (!box) return { error: doc.querySelector('.locked, .is-locked') ? 'locked' : 'no-content' };
        var ps = K.paragraphs(box, null), title = '';
        if (ps.length && /^(الفصل|فصل|chapter)\s*[\d٠-٩]+/i.test(ps[0]) && ps[0].length < 160) title = ps.shift();
        if (!title) title = K.txt(doc.querySelector('h1.h1'));
        var c = K.tidy(ps, this.clean, 6);
        var m = /\/novel\/([0-9a-f]{24})\/chapter\/(\d+)/i.exec(url), nx = doc.querySelector('.locked a.btn[href*="/chapter/"]'), prev = '';
        if (m && parseInt(m[2], 10) > 1) prev = HOME + 'novel/' + m[1] + '/chapter/' + (parseInt(m[2], 10) - 1);
        return { title: title, paras: c.paras, removed: c.removed, next: nx ? K.abs(nx.getAttribute('href'), url) : '', prev: prev };
      } catch (e) { return { error: 'bad-page' }; }
    },

    /* one listing (latest updates first) and a ?q= search; the site has no popularity order */
    browseURL: function (kind, page, q) {
      var p = [];
      if (kind === 'search' && q) p.push('q=' + encodeURIComponent(q));
      if (page > 1) p.push('page=' + page);
      return HOME + (p.length ? '?' + p.join('&') : '');
    },
    browse: function (doc, url) {
      try {
        var items = [], seen = {};
        Array.prototype.forEach.call(doc.querySelectorAll('a.g3card'), function (a) {
          var href = K.abs(a.getAttribute('href'), url).split('#')[0];
          if (!novelId(href) || seen[href]) return; seen[href] = 1;
          var chaps = K.digits(K.txt(a.querySelector('.g3chaps')));
          var bits = [K.txt(a.querySelector('.g3status')), chaps ? chaps + ' فصل' : '', K.txt(a.querySelector('.g3cat'))].filter(Boolean);
          items.push({ url: href, title: K.txt(a.querySelector('.g3title')), cover: coverOf(a.querySelector('img'), url), meta: bits.join(' · ') });
        });
        return { items: items, next: !!(items.length && doc.querySelector('a[rel="next"]')) };
      } catch (e) { return { error: 'bad-page' }; }
    }
  };
})();
