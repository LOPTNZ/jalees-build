/* Any other site (س17.4): when a link's site has no definition of its own, this one tries to read it the way most
   novel sites are built. The novel's page: its title (og:title or h1), cover (og:image), summary, and every link that
   looks like a chapter («الفصل 12», «Chapter 12», …/chapter-12). A chapter: the block with the most paragraph text,
   and the links named «التالي» / «Next». Never listed in Browse (it has no listing of its own). */
(function () {
  'use strict';
  var K = window.SourceKit, S = window.Sources = window.Sources || {};
  var CH = /(?:^|[\s:#\-–—|])(?:الفصل|فصل|الحلقة|chapter|chap\.?|ch\.?|episode|ep\.?)\s*[:#\-–—]?\s*([0-9٠-٩]+(?:[.,][0-9٠-٩]+)?)/i;
  var CH_URL = /(?:chapter|chap|ch|episode|ep|الفصل|فصل)[-_\/]?([0-9]+(?:[.\-][0-9]+)?)(?:[\/?#.-]|$)/i;
  var NEXT = /^(?:الفصل\s+)?(?:التالي|القادم|next(?:\s+chapter)?|›|»|>>)\s*[›»>]*$/i;
  var PREV = /^(?:الفصل\s+)?(?:السابق|prev(?:ious)?(?:\s+chapter)?|‹|«|<<)\s*[‹«<]*$/i;
  var INDEX = /^(?:الفهرس|فهرس|قائمة الفصول|صفحة الرواية|كل الفصول|index|table of contents|all chapters|novel info|chapter list)$/i;

  function host(u) { try { return new URL(u).hostname.replace(/^www\./, ''); } catch (e) { return ''; } }
  function num(s) { return K.digits(String(s).split(/[.,]/)[0]); }

  function chapterLinks(doc, url) {
    var h = host(url), seen = {}, rows = [];
    Array.prototype.forEach.call(doc.querySelectorAll('a[href]'), function (a) {
      var href = K.abs(a.getAttribute('href'), url).split('#')[0];
      if (!href || seen[href] || host(href) !== h) return;
      var t = K.txt(a), m = CH.exec(' ' + t), mu = CH_URL.exec(href);
      if (!m && !mu) return;
      if (t.length > 200) return;
      seen[href] = 1;
      var n = num(m ? m[1] : mu[1]);
      if (!n) return;
      var title = m ? t.slice(t.indexOf(m[1]) + m[1].length).replace(/^[\s:：\-–—|.]+/, '').trim() : '';
      rows.push({ url: href, num: n, title: title || (m ? '' : t), volume: '', date: '', byText: !!m });
    });
    /* numbers only from addresses that are really page ids (/chapter/301778/…): the page's own order instead */
    if (rows.length && !rows.some(function (r) { return r.byText; }) && rows.some(function (r) { return parseFloat(r.num) > 20000; })) {
      rows.forEach(function (r, i) { r.num = String(i + 1); });
    }
    rows.forEach(function (r) { delete r.byText; });
    /* one row per number (a site lists the newest twice, at the top and in the list) */
    var byNum = {};
    rows.forEach(function (r) { if (!byNum[r.num]) byNum[r.num] = r; });
    return Object.keys(byNum).map(function (k) { return byNum[k]; })
      .sort(function (x, y) { return parseFloat(y.num) - parseFloat(x.num); });
  }

  /* the block that holds the chapter's paragraphs itself: the most text in its own <p> children or its own lines
     (sites that write the text with <br>), so the page's menus and lists around it are left out */
  function bestBlock(doc) {
    var best = null, score = 0;
    Array.prototype.forEach.call(doc.querySelectorAll('div, article, section, main, td'), function (el) {
      var n = 0, kids = el.childNodes;
      for (var i = 0; i < kids.length; i++) {
        var k = kids[i];
        if (k.nodeType === 3) n += k.textContent.trim().length;
        else if (k.nodeType === 1 && /^(P|SPAN|FONT|B|I|EM|STRONG)$/.test(k.tagName)) {
          var t = (k.textContent || '').trim();
          if (t.length > 20 || k.tagName === 'P') n += t.length;
        }
      }
      if (n > score) { score = n; best = el; }
    });
    return score > 300 ? best : doc.body;
  }

  function linkBy(doc, url, re) {
    var as = doc.querySelectorAll('a[rel="next"], a[rel="prev"], a[href]');
    for (var i = 0; i < as.length; i++) {
      var t = K.txt(as[i]) || as[i].getAttribute('title') || as[i].getAttribute('aria-label') || '';
      if (re.test(t.trim())) return K.abs(as[i].getAttribute('href'), url);
    }
    return '';
  }

  S.generic = {
    id: 'generic', name: 'موقع آخر', home: '', lang: 'ar', hosts: [],
    isSeries: function (url) { return !CH_URL.test(url); },
    seriesUrl: function (doc, url) {
      var up = doc.querySelector('a[rel="up"], a[rel="index"]');
      if (up) return K.abs(up.getAttribute('href'), url);
      var as = doc.querySelectorAll('a[href]');
      for (var i = 0; i < as.length; i++) if (INDEX.test(K.txt(as[i]))) return K.abs(as[i].getAttribute('href'), url);
      var crumbs = Array.prototype.map.call(doc.querySelectorAll('nav[aria-label*="bread" i] a, .breadcrumb a, .breadcrumbs a, [class*="crumb"] a'), function (a) { return K.abs(a.getAttribute('href'), url); })
        .filter(function (h) { return h && h.split('#')[0] !== url && !CH_URL.test(h); });
      if (crumbs.length) return crumbs[crumbs.length - 1];
      /* the address without its chapter part */
      return url.replace(CH_URL, '').replace(/[\/\-_]+$/, '') || '';
    },
    clean: [/^(ترجمة|المترجم|تدقيق|المدقق)\s*[:：-]/, /^(translator|editor|tl|ed)\s*[:：-]/i, /^(اقرأ|إقرأ) (المزيد|أيضا)/, /discord\.gg|patreon\.com/i],

    series: function (doc, url) {
      try {
        /* the novel's name: the heading that the page's own title also holds («Read Shadow Slave online free») */
        var page = (doc.title || '').toLowerCase(), title = '';
        var cands = [K.meta(doc, 'og:title')].concat(Array.prototype.map.call(doc.querySelectorAll('h1, h2, h3, [class*="title"]'), K.txt));
        for (var i = 0; i < cands.length && !title; i++) {
          var c = (cands[i] || '').replace(/\s*[|–—-]\s*[^|–—-]+$/, '').trim();
          if (c.length > 1 && c.length < 150 && page.indexOf(c.toLowerCase()) >= 0) title = c;
        }
        if (!title) title = (K.meta(doc, 'og:title') || K.txt(doc.querySelector('h1')) || doc.title || '').replace(/\s*[|–—-]\s*[^|–—-]+$/, '').trim();
        if (!title) return { error: 'no-title' };
        var rows = this.list(doc, url);
        if (rows.length < 2) return { error: 'no-chapters' };
        var sum = doc.querySelector('[class*="summary"], [class*="synopsis"], [class*="desc"], [itemprop="description"], [class*="story"]');
        var pages = [], seen = {};
        Array.prototype.forEach.call(doc.querySelectorAll('a[href*="page="], a[href*="/page/"]'), function (a) {
          var h = K.abs(a.getAttribute('href'), url);
          if (host(h) === host(url) && !seen[h] && pages.length < 30) { seen[h] = 1; pages.push(h); }
        });
        return {
          title: title, author: K.txt(doc.querySelector('[itemprop="author"], .author, [class*="author"] a')).slice(0, 80),
          cover: K.meta(doc, 'og:image') || '', summary: (K.txt(sum) || K.meta(doc, 'og:description') || K.meta(doc, 'description')).slice(0, 4000),
          status: '', total: 0, translator: '', genres: [],
          listPages: pages.length ? [url].concat(pages) : [], rows: rows
        };
      } catch (e) { return { error: 'bad-page' }; }
    },

    list: function (doc, url) { return chapterLinks(doc, url); },

    chapter: function (doc, url) {
      try {
        var box = bestBlock(doc);
        var ps = K.paragraphs(box, 'nav, header, footer, aside, form, [class*="comment"], [class*="share"], [class*="related"], [class*="ads"], script, style');
        var title = K.txt(doc.querySelector('h1, h2'));
        if (ps.length && title && ps[0] === title) ps.shift();
        /* the chapter's own heading at the top of the text («Chapter 1: Nightmare Begins») is its title */
        if (ps.length && ps[0].length < 160 && CH.test(' ' + ps[0])) title = ps.shift();
        var c = K.tidy(ps, this.clean, 6);
        if (c.paras.length < 3) return { error: 'no-content' };
        return { title: title, paras: c.paras, removed: c.removed, next: linkBy(doc, url, NEXT), prev: linkBy(doc, url, PREV) };
      } catch (e) { return { error: 'bad-page' }; }
    }
  };
})();
