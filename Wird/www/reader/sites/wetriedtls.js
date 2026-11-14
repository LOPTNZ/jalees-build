/* We Tried TLs (wetriedtls.com), English. The site is a Next.js app: a novel page carries no chapter list in its HTML
   (the browser asks the API afterwards), so the list comes from the JSON API https://api.wetriedtls.com (no login, no
   cookies). Chapter pages carry their text in <article data-reader-article>. A chapter that needs coins or a
   subscription answers with a "404" page instead of the text: such chapters are marked `locked: true` in the list. */
(function () {
  'use strict';
  var K = window.SourceKit, txt = K.txt, abs = K.abs, S = window.Sources;
  var SITE = 'https://wetriedtls.com', API = 'https://api.wetriedtls.com';

  function json(doc) {
    try { var t = doc && doc.body ? doc.body.textContent : ''; return t ? JSON.parse(t) : null; } catch (e) { return null; }
  }
  function slugOf(url) { var m = /\/series\/([^\/?#]+)/.exec(url || ''); return m ? m[1] : ''; }
  function slugFromSeriesUrl(url) { var m = /\/series\/([^\/?#]+)/.exec(url || ''); return m ? m[1] : ''; }
  /* "874.0" -> "874", "12.5" -> "12.5" */
  function numOf(ix) { var f = parseFloat(ix); return isNaN(f) ? '' : String(f); }
  /* the numeric id of the novel, hidden in the page's script data */
  function seriesId(doc) {
    var scripts = doc.querySelectorAll('script'), pats = [/seriesId\\*"\s*:\s*(\d+)/, /series_id\\*"\s*:\s*(\d+)\s*,\s*\\*"series_type/], i, p, m;
    for (p = 0; p < pats.length; p++)
      for (i = 0; i < scripts.length; i++) { m = pats[p].exec(scripts[i].textContent || ''); if (m) return m[1]; }
    return '';
  }

  /* lines at the start / end of a chapter that are the translators' chatter */
  var HEAD = [/^(we\s*tried\s*(translations|tls)|translated by|edited by)\b.{0,80}$/i,
              /^(translators?|editors?|proofreaders?)\s*(\/\s*\w+)?\s*[:：]/i, /discord/i, /dsc\.gg/i, /ko-?fi/i, /patreon/i,
              /^join (the|our) /i, /^support /i, /^[\s\-–—_=*~─━•·.]{3,}$/, /^(chapter|ch\.?)\s*\d+[\d.]*\b.{0,160}$/i];
  var TAIL = [/dsc\.gg/i, /discord/i, /ko-?fi/i, /patreon/i, /^join (the|our) /i, /^support /i, /wetried/i, /^[\s\-–—_=*~─━•·.]{3,}$/];
  function matchAny(rules, s) { for (var i = 0; i < rules.length; i++) if (rules[i].test(s)) return true; return false; }

  S.wetriedtls = {
    id: 'wetriedtls', name: 'We Tried TLs', home: SITE + '/', lang: 'en',
    hosts: ['wetriedtls.com', 'www.wetriedtls.com'],
    isSeries: function (url) { return /^https?:\/\/(www\.)?wetriedtls\.com\/(vi\/)?series\/[^\/?#]+\/?(?:[?#].*)?$/.test(url || ''); },
    seriesUrl: function (doc, url) {
      var a = doc.querySelector('a[aria-label="Back to series"][href]');
      if (a) return abs(a.getAttribute('href'), url).split('#')[0];
      var s = slugFromSeriesUrl(url);
      return s ? SITE + '/series/' + s : '';
    },

    series: function (doc, url) {
      var h1 = doc.querySelector('h1');
      if (!h1) return { error: 'no-title' };
      var slug = slugOf(url), id = seriesId(doc), info = {};
      doc.querySelectorAll('dl > div').forEach(function (d) {
        var k = d.querySelector('dt'), v = d.querySelector('dd');
        if (k && v) info[txt(k).toLowerCase()] = txt(v);
      });
      var genres = Array.prototype.map.call(doc.querySelectorAll('ul[aria-label="Genres"] a'), txt).filter(Boolean);
      var summary = '', ul = doc.querySelector('ul[aria-label="Genres"]');
      if (ul && ul.parentElement) {
        var kids = ul.parentElement.children, best = '';
        for (var i = 0; i < kids.length; i++) {
          if (kids[i] === ul || kids[i].querySelector('[aria-label="Release days"]')) continue;
          var t = txt(kids[i]);
          if (/^Part of/.test(t) || /Chapters\s*Gallery/.test(t) || /^Chapters/.test(t)) continue;
          if (t.length > best.length) best = t;
        }
        summary = best;
      }
      if (!summary) summary = K.meta(doc, 'og:description');
      /* the page glues the synopsis paragraphs together; put the missing spaces back */
      summary = summary.replace(/([.!?…”"’])(?=[A-Z“"‘])/g, '$1 ').slice(0, 4000);
      var total = parseInt(K.digits(info['chapters']), 10) || 0;
      return {
        title: txt(h1), author: info['author'] || '', cover: K.meta(doc, 'og:image'), summary: summary,
        status: info['status'] || '', total: total, translator: '', genres: genres.slice(0, 12),
        /* the novel page itself has no chapters; one API call returns them all */
        listPages: id && slug ? [url, API + '/chapters/' + id + '/all?slug=' + encodeURIComponent(slug)] : [],
        rows: this.list(doc, url)
      };
    },

    list: function (doc, url) {
      if (!/api\.wetriedtls\.com\/chapters\//.test(url || '')) return [];
      var data = json(doc), rows = [];
      var m = /[?&]slug=([^&#]+)/.exec(url || ''), slug = m ? decodeURIComponent(m[1]) : '';
      if (data && !Array.isArray(data) && Array.isArray(data.data)) data = data.data;
      if (!Array.isArray(data) || !slug) return [];
      data.forEach(function (c) {
        if (!c || !c.chapter_slug) return;
        var row = {
          url: SITE + '/series/' + slug + '/' + c.chapter_slug, num: numOf(c.index) || K.digits(c.chapter_name),
          title: String(c.chapter_title || '').trim(), volume: '', date: c.release_date || c.created_at || ''
        };
        if (c.price > 0 || c.public === false) row.locked = true;
        rows.push(row);
      });
      rows.sort(function (a, b) { return (parseFloat(b.num) || 0) - (parseFloat(a.num) || 0); });   /* newest first */
      return rows;
    },

    chapter: function (doc, url) {
      var art = doc.querySelector('article[data-reader-article]');
      if (!art) return { error: 'no-content (locked chapter or missing page)' };
      var lines = [];
      var flush = function (buf) { var t = buf.replace(/[ \t\r\n]+/g, ' ').trim(); if (t) lines.push(t); };
      for (var n = art.firstElementChild; n; n = n.nextElementSibling) {
        var tag = n.tagName.toLowerCase();
        if (tag === 'hr') { lines.push('* * *'); continue; }
        if (/^(script|style|iframe|ins|form|button|nav)$/.test(tag)) continue;
        if (n.getAttribute('hidden') !== null || n.getAttribute('aria-hidden') === 'true') continue;
        var st = (n.getAttribute('style') || '').replace(/\s+/g, '').toLowerCase();
        if (/display:none|visibility:hidden|opacity:0(?![.\d])|font-size:0(?![.\d])/.test(st)) continue;
        /* a paragraph may hold several lines separated by <br> */
        var buf = '';
        for (var c = n.firstChild; c; c = c.nextSibling) {
          if (c.nodeType === 3) buf += c.nodeValue;
          else if (c.nodeType === 1 && c.tagName.toLowerCase() === 'br') { flush(buf); buf = ''; }
          else if (c.nodeType === 1) buf += c.textContent;
        }
        flush(buf);
      }
      var removed = 0;
      while (lines.length && matchAny(HEAD, lines[0].replace(/ /g, ' ')) && removed < 14) { lines.shift(); removed++; }
      while (lines.length && matchAny(TAIL, lines[lines.length - 1]) && removed < 20) { lines.pop(); removed++; }
      var h1 = doc.querySelector('#reader-container h1'), sub = h1 ? h1.parentElement.querySelector('p') : null;
      var title = h1 ? txt(h1) + (sub && txt(sub) ? ': ' + txt(sub) : '') : '';
      var nx = doc.querySelector('a[aria-label="Next chapter"][href]'), pv = doc.querySelector('a[aria-label="Previous chapter"][href]');
      return { title: title, paras: lines, removed: removed, next: nx ? abs(nx.getAttribute('href'), url) : '', prev: pv ? abs(pv.getAttribute('href'), url) : '' };
    },

    /* the site's own search/browse API: JSON, 20 novels a page */
    browseURL: function (kind, page, q) {
      var order = kind === 'popular' ? 'total_views' : 'latest';
      return API + '/query?series_type=Novel&language=en&order=desc&orderBy=' + order + '&perPage=20&page=' + (page || 1) +
             '&query_string=' + (kind === 'search' ? encodeURIComponent(q || '') : '');
    },
    browse: function (doc, url) {
      var d = json(doc);
      if (!d || !Array.isArray(d.data)) return { items: [], next: false };
      var items = d.data.filter(function (x) { return x && x.series_slug; }).map(function (x) {
        var bits = [];
        if (x.status) bits.push(x.status);
        if (x.rating) bits.push('★ ' + (Math.round(x.rating * 10) / 10));
        if (x.badge) bits.push(x.badge);
        return { url: SITE + '/series/' + x.series_slug, title: x.title || '', cover: x.thumbnail || '', meta: bits.join(' · ') };
      });
      var mt = d.meta || {};
      return { items: items, next: !!(mt.current_page && mt.last_page && mt.current_page < mt.last_page) };
    }
  };
})();
