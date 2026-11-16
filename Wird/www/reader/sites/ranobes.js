/* Ranobes (ranobes.top / ranobes.net), English. A DLE (DataLife Engine) site behind a picture check: the app shows the
   site in its sign-in sheet, the owner answers the check himself, and the cookies are reused. This file only reads the
   real pages; it never tries to pass the check (a page that is the check has none of the markup below, so every function
   answers an error or an empty list).
   - Novel: /novels/<id>-<slug>.html. Poster `.poster img` (alt = title), `[itemprop=creator]`, description in
     `.moreless.cont-text.showcont-h` / `[itemprop=description]` / `.r-desription .cont-text`, status in
     `li[title*="Original status"] a`, genres in `#mc-fs-genre a`, the chapter count in the `li` titled "Glossary +
     illustrations + division of chapters, etc." The novel page only lists the newest chapters.
   - Chapter list: /chapters/<id>/page/N/ (25 a page, newest first), the rows are the JSON in `window.__DATA__`
     ({pages_count, chapters:[{id,title,date,link}]}), or `.cat_block.cat_line a[title]` in the HTML.
   - Chapter text: `#arrticle`, minus scripts, styles, ads (`ins`, `[id^="bg-ssp"]`).
   - Lists: /novels/page/N/ (cards `.short-cont`, cover in the `figure`'s style), search /search/<words>/page/N (the
     English site answers 404 when nothing is found; that page is no list, the app sees an empty one). */
(function () {
  'use strict';
  var K = window.SourceKit, txt = K.txt, abs = K.abs, S = window.Sources = window.Sources || {};
  var HOME = 'https://ranobes.top/';
  var PAGE_SIZE = 25, MAX_PAGES = 400;     /* up to 10000 chapters listed */

  function novelId(url) { var m = /\/novels\/(\d+)-/.exec(url || ''); return m ? m[1] : ''; }
  function origin(url) { var m = /^(https?:\/\/[^\/]+)/.exec(url || ''); return m ? m[1] : HOME.replace(/\/$/, ''); }
  function cleanDate(s) { return String(s || '').trim(); }
  function numOf(title) {
    var m = /(?:chapter|ch\.?|episode|ep\.?)\s*(\d+(?:\.\d+)?)/i.exec(title || '') || /^\s*(\d+(?:\.\d+)?)\b/.exec(title || '');
    return m ? m[1] : '';
  }
  function stripNum(title) {
    return String(title || '').replace(/^\s*(?:chapter|ch\.?|episode|ep\.?)\s*\d+(?:\.\d+)?\s*[:：.\-–—]?\s*/i, '').trim();
  }
  /* the chapter list page's own data: window.__DATA__ = {...} */
  function pageData(doc) {
    var scripts = doc.querySelectorAll('script'), i, t, k, s;
    for (i = 0; i < scripts.length; i++) {
      t = scripts[i].textContent || '';
      k = t.indexOf('window.__DATA__');
      if (k < 0) continue;
      s = t.slice(t.indexOf('=', k) + 1).trim().replace(/;\s*$/, '');
      try { return JSON.parse(s); } catch (e) {
        var a = s.indexOf('{'), b = s.lastIndexOf('}');
        if (a >= 0 && b > a) { try { return JSON.parse(s.slice(a, b + 1)); } catch (e2) { /* no data */ } }
      }
    }
    return null;
  }
  /* "/chapters/<id>/" from the novel page */
  function chaptersBase(doc, url) {
    var a = doc.querySelector('a[href*="/chapters/"]'), h = a ? abs(a.getAttribute('href'), url) : '';
    var m = /^(https?:\/\/[^\/]+\/chapters\/[^\/?#]+)\//.exec(h);
    if (m) return m[1];
    var html = doc.documentElement ? doc.documentElement.innerHTML : '', m2 = /\/chapters\/[^"'\/?#\s]+(?=\/["'])/.exec(html);
    return m2 ? origin(url) + m2[0] : '';
  }
  function parseCards(doc, url) {
    var items = [], seen = {};
    function push(href, title, cover, meta) {
      href = (href || '').split('#')[0];
      if (!/\/novels\/\d+-[^\/?#]+\.html/.test(href) || seen[href] || !title) return;
      seen[href] = 1;
      items.push({ url: href, title: title, cover: cover || '', meta: meta || '' });
    }
    Array.prototype.forEach.call(doc.querySelectorAll('.short-cont, article.block.story.shortstory, article.story'), function (card) {
      var a = card.querySelector('h2.title a[href], .title a[href]');
      if (!a) return;
      var fig = card.querySelector('figure, .img-fit, .poster'), cover = '';
      var st = fig ? (fig.getAttribute('style') || '') : '', m = /url\(\s*['"]?([^'")]+)['"]?\s*\)/.exec(st);
      if (m) cover = abs(m[1], url);
      else { var img = card.querySelector('img'); if (img) cover = abs(img.getAttribute('data-src') || img.getAttribute('src') || '', url); }
      var bits = [], st2 = card.querySelector('.status, .meta .status'), ch = card.querySelector('.chapters, .meta .chapters');
      if (st2) bits.push(txt(st2));
      if (ch) bits.push(txt(ch));
      push(abs(a.getAttribute('href'), url), txt(a), cover, bits.filter(Boolean).join(' · '));
    });
    if (!items.length) {
      Array.prototype.forEach.call(doc.querySelectorAll('h2 a[href*="/novels/"], h3 a[href*="/novels/"]'), function (a) {
        push(abs(a.getAttribute('href'), url), txt(a), '', '');
      });
    }
    return items;
  }

  S.ranobes = {
    id: 'ranobes', name: 'Ranobes', home: HOME, lang: 'en',
    hosts: ['ranobes.top', 'www.ranobes.top', 'ranobes.net', 'www.ranobes.net'],
    isSeries: function (url) { return /^https?:\/\/(?:www\.)?ranobes\.(?:top|net)\/novels\/\d+-[^\/?#]+\.html(?:[?#].*)?$/.test(url || ''); },
    seriesUrl: function (doc, url) {
      var a = doc.querySelector('a[href*="/novels/"][href$=".html"]'), best = '';
      if (/\/novels\/\d+-/.test(url || '') && !/\/read-/.test(url)) return String(url).split(/[?#]/)[0];
      var cands = doc.querySelectorAll('a[href*="/novels/"]'), i, h;
      for (i = 0; i < cands.length; i++) {
        h = abs(cands[i].getAttribute('href'), url);
        if (/\/novels\/\d+-[^\/?#]+\.html/.test(h)) { best = h.split(/[?#]/)[0]; break; }
      }
      if (!best && a) best = abs(a.getAttribute('href'), url).split(/[?#]/)[0];
      return best;
    },
    clean: [/^(translator|translated by|editor|edited by|proofreader)\s*[:：]/i, /ranobes/i, /^join (the|our) /i, /discord/i],

    series: function (doc, url) {
      try {
        var poster = doc.querySelector('.poster img, .poster'), img = poster && poster.tagName === 'IMG' ? poster : (poster ? poster.querySelector('img') : null);
        var title = img ? (img.getAttribute('alt') || '').trim() : '';
        if (!title) {
          var h1 = doc.querySelector('h1.title, h1');
          if (h1) { var c = h1.cloneNode(true), sub = c.querySelector('.subtitle, span'); if (sub) sub.remove(); title = txt(c); }
        }
        if (!title) return { error: 'no-title' };
        var cover = img ? abs(img.getAttribute('src') || img.getAttribute('data-src') || '', url) : '';
        if (!cover) cover = K.meta(doc, 'og:image');
        var author = txt(doc.querySelector('[itemprop="creator"]'));
        var sumEl = doc.querySelector('.moreless.cont-text.showcont-h, [itemprop="description"], .r-desription .cont-text');
        var summary = '';
        if (sumEl) {
          var sc = sumEl.cloneNode(true);
          Array.prototype.forEach.call(sc.querySelectorAll('style, script'), function (e) { e.remove(); });
          Array.prototype.forEach.call(sc.querySelectorAll('br'), function (e) { e.replaceWith('\n'); });
          Array.prototype.forEach.call(sc.querySelectorAll('p'), function (e) { e.appendChild(doc.createTextNode('\n\n')); });
          summary = (sc.textContent || '').replace(/ /g, ' ').replace(/[ \t]*\n[ \t]*/g, '\n').replace(/[ \t]{2,}/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
        }
        var status = '', total = 0;
        Array.prototype.forEach.call(doc.querySelectorAll('li[title]'), function (li) {
          var t = li.getAttribute('title') || '';
          if (/Original status/i.test(t)) status = txt(li.querySelector('a')) || txt(li).replace(/^.*status[^:]*:\s*/i, '');
          else if (/^Glossary \+ illustrations/i.test(t)) total = parseInt(K.digits(txt(li)), 10) || 0;
        });
        var genres = Array.prototype.map.call(doc.querySelectorAll('#mc-fs-genre a'), txt).filter(Boolean).slice(0, 12);
        var base = chaptersBase(doc, url), pages = [url];
        if (base) {
          var n = Math.min(MAX_PAGES, Math.max(1, Math.ceil((total || PAGE_SIZE) / PAGE_SIZE)));
          for (var p = 1; p <= n; p++) pages.push(base + '/page/' + p + '/');
        }
        /* the novel page lists only the newest chapters; with the table of contents they are listed once, from it */
        return {
          title: title, author: author, cover: cover, summary: summary.slice(0, 4000), status: status, total: total,
          translator: '', genres: genres, listPages: base ? pages : [], rows: base ? [] : this.list(doc, url)
        };
      } catch (e) { return { error: 'bad-page' }; }
    },

    /* chapters on this page, newest first: a table of contents page (JSON in window.__DATA__) or the novel page */
    list: function (doc, url) {
      try {
        var rows = [], seen = {};
        function add(href, title, date) {
          href = href ? href.split('#')[0] : '';
          if (!href || seen[href]) return;
          seen[href] = 1;
          rows.push({ url: href, num: numOf(title), title: stripNum(title), volume: '', date: cleanDate(date) });
        }
        var d = pageData(doc);
        if (d && Array.isArray(d.chapters) && d.chapters.length) {
          d.chapters.forEach(function (c) { if (c && c.link) add(abs(c.link, url), String(c.title || ''), c.date); });
          return rows;
        }
        Array.prototype.forEach.call(doc.querySelectorAll('.cat_block.cat_line a[href][title]'), function (a) {
          var small = a.parentNode && a.parentNode.querySelector ? a.parentNode.querySelector('small') : null;
          add(abs(a.getAttribute('href'), url), a.getAttribute('title') || txt(a), small ? txt(small) : '');
        });
        if (!rows.length) {
          Array.prototype.forEach.call(doc.querySelectorAll('a[rel="chapter"][href]'), function (a) {
            add(abs(a.getAttribute('href'), url), txt(a.querySelector('.title')) || txt(a), txt(a.querySelector('.grey')));
          });
        }
        return rows;
      } catch (e) { return []; }
    },

    chapter: function (doc, url) {
      try {
        var box = doc.querySelector('#arrticle');
        if (!box) return { error: 'no-content' };
        Array.prototype.forEach.call(box.querySelectorAll('script, style, ins, iframe, [id^="bg-ssp"]'), function (e) { e.remove(); });
        var ps = K.paragraphs(box, null);
        if (ps.length <= 1 && box.querySelector('br')) {
          /* text split by <br> instead of paragraphs */
          var parts = box.innerHTML.split(/<br\s*\/?>/i).map(function (h) {
            var t = doc.createElement('div'); t.innerHTML = h; return txt(t);
          }).filter(Boolean);
          if (parts.length > ps.length) ps = parts;
        }
        var h1 = doc.querySelector('h1.title, h1'), title = '';
        if (h1) { var c = h1.cloneNode(true), sub = c.querySelector('.subtitle, small'); if (sub) sub.remove(); title = txt(c); }
        if (ps.length && ps[0] === title) ps.shift();
        var t2 = K.tidy(ps, this.clean, 4);
        var nx = doc.querySelector('#next[href], a.next[href], a[rel="next"][href]'), pv = doc.querySelector('#prev[href], a.prev[href], a[rel="prev"][href]');
        var next = nx ? abs(nx.getAttribute('href'), url) : '', prev = pv ? abs(pv.getAttribute('href'), url) : '';
        /* the "next" on the last chapter points at the novel's page or the table of contents */
        if (!/\/read-/.test(next)) next = '';
        if (!/\/read-/.test(prev)) prev = '';
        if (!t2.paras.length) return { error: 'no-content' };
        return { title: title, paras: t2.paras, removed: t2.removed, next: next, prev: prev };
      } catch (e) { return { error: 'bad-page' }; }
    },

    /* /novels/ lists every novel (the site's own order); search is /search/<words>/page/N */
    browseURL: function (kind, page, q) {
      var p = page || 1;
      if (kind === 'search' && q) return HOME + 'search/' + encodeURIComponent(q) + '/page/' + p + '/';
      if (kind === 'latest') return HOME + 'updates/page/' + p + '/';
      return HOME + 'novels/page/' + p + '/';
    },
    browse: function (doc, url) {
      try {
        var items = parseCards(doc, url);
        var cur = Number((/\/page\/(\d+)/.exec(url || '') || [0, 1])[1]);
        var next = false, links = doc.querySelectorAll('a[href*="/page/"]'), i, m;
        for (i = 0; i < links.length; i++) {
          m = /\/page\/(\d+)/.exec(links[i].getAttribute('href') || '');
          if (m && Number(m[1]) > cur) { next = true; break; }
        }
        if (doc.querySelector('.pages a.next, .navigation a.next, a[rel="next"]')) next = true;
        return { items: items, next: !!(items.length && next) };
      } catch (e) { return { error: 'bad-page' }; }
    }
  };
})();
