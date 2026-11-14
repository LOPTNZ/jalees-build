/* WTR-LAB (wtr-lab.com/en), machine-translated novels. A Next.js (pages router) site: every page carries its data in
   <script id="__NEXT_DATA__">. Novel: /en/novel/<raw_id>/<slug>; chapter: /en/novel/<raw_id>/<slug>/chapter-<n>.
   - Novel info: __NEXT_DATA__ props.pageProps.serie.serie_data.
   - Chapter list: the plain GET https://wtr-lab.com/api/chapters/<raw_id> (all chapters, no login). The novel's slug is
     carried as `&slug=` (the server ignores it) because the API gives no addresses.
   - Chapter text: NOT in the chapter page and NOT reachable by a plain GET. The page only has the chapter's meta. The
     text needs  POST https://wtr-lab.com/api/reader/get  with JSON {translate:"ai",language:"en",raw_id,chapter_no}
     -> {content_url:"/api/v2/reader/content/…signed…"}, then a GET of that signed URL (valid for days), which is JSON
     {data:{data:{title, body:[paragraphs], glossary_data:{terms:[[english, chinese], …]}}}}. chapter() reads that JSON
     when it is handed it (names are written ※N⛬ in the text and are replaced by terms[N][0]); given the chapter
     page itself it answers { error } that says so.
   - Search is POST /api/search {text}; the site's GET pages cannot filter by text, so search is not available. */
(function () {
  'use strict';
  var K = window.SourceKit, abs = K.abs, S = window.Sources = window.Sources || {};
  var HOME = 'https://wtr-lab.com/en', ORIGIN = 'https://wtr-lab.com';
  var GENRES = { 1: 'Action', 2: 'Adult', 3: 'Adventure', 4: 'Comedy', 5: 'Drama', 6: 'Ecchi', 7: 'Erciyuan', 8: 'Fan-Fiction', 9: 'Fantasy',
    10: 'Game', 11: 'Gender Bender', 12: 'Harem', 13: 'Historical', 14: 'Horror', 15: 'Josei', 16: 'Martial Arts', 17: 'Mature', 18: 'Mecha',
    19: 'Military', 20: 'Mystery', 21: 'Psychological', 22: 'Romance', 23: 'School Life', 24: 'Sci-Fi', 25: 'Seinen', 26: 'Shoujo',
    27: 'Shoujo Ai', 28: 'Shounen', 29: 'Shounen Ai', 30: 'Slice of Life', 31: 'Smut', 32: 'Sports', 33: 'Supernatural', 34: 'Tragedy',
    35: 'Urban Life', 36: 'Wuxia', 37: 'Xianxia', 38: 'Xuanhuan', 39: 'Yaoi', 40: 'Yuri' };
  var STATUS = { 0: 'Ongoing', 1: 'Completed', 2: 'Hiatus', 3: 'Dropped' };

  /* "%{Soul Land|RG91bHVv}" is a glossary mark: keep the visible name */
  function plain(s) { return String(s || '').replace(/%\{([^|}]*)\|[^}]*\}/g, '$1').trim(); }
  function json(doc) {
    try { var t = doc && doc.body ? doc.body.textContent : ''; return t ? JSON.parse(t) : null; } catch (e) { return null; }
  }
  function nextData(doc) {
    try {
      var el = doc.querySelector('script#__NEXT_DATA__');
      var d = el ? JSON.parse(el.textContent) : null;
      return d && d.props && d.props.pageProps ? d.props.pageProps : null;
    } catch (e) { return null; }
  }
  function novelUrl(s) { return s && s.raw_id && s.slug ? HOME + '/novel/' + s.raw_id + '/' + s.slug : ''; }
  function ids(url) { var m = /\/novel\/(\d+)\/([^\/?#]+)/.exec(url || ''); return m ? { raw: m[1], slug: m[2] } : null; }

  S.wtrlab = {
    id: 'wtrlab', name: 'WTR-LAB', home: HOME, lang: 'en',
    hosts: ['wtr-lab.com', 'www.wtr-lab.com'],
    isSeries: function (url) { return /wtr-lab\.com\/(?:[a-z]{2}\/)?novel\/\d+\/[^\/?#]+\/?(?:[?#].*)?$/.test(url || ''); },
    seriesUrl: function (doc, url) {
      var i = ids(url);
      return i ? HOME + '/novel/' + i.raw + '/' + i.slug : '';
    },

    series: function (doc, url) {
      var pp = nextData(doc), sd = pp && pp.serie && pp.serie.serie_data;
      if (!sd || !sd.raw_id) return { error: 'no-title' };
      var d = sd.data || {}, slug = sd.slug || (ids(url) || {}).slug || '';
      var summary = plain(d.description);
      return {
        title: plain(d.title), author: d.author || '', cover: d.image || '', summary: summary.slice(0, 4000),
        status: STATUS[sd.status] || '', total: sd.chapter_count || 0, translator: 'WTR-LAB (machine translation)',
        genres: (sd.genres || []).map(function (g) { return GENRES[g]; }).filter(Boolean),
        /* the novel page itself has no chapter list; one API call returns them all */
        listPages: [url, ORIGIN + '/api/chapters/' + sd.raw_id + '?slug=' + encodeURIComponent(slug)],
        rows: []
      };
    },

    list: function (doc, url) {
      var m = /\/api\/chapters\/(\d+)/.exec(url || ''), s = /[?&]slug=([^&#]+)/.exec(url || '');
      var d = json(doc);
      if (!m || !s || !d || !Array.isArray(d.chapters)) return [];
      var base = HOME + '/novel/' + m[1] + '/' + decodeURIComponent(s[1]) + '/chapter-';
      var rows = d.chapters.filter(function (c) { return c && c.order > 0; }).map(function (c) {
        var row = {
          url: base + c.order, num: String(c.order),
          title: plain(c.title).replace(/^(chapter|ch\.?)\s*\d+(\.\d+)?\s*[:：.\-–—]?\s*/i, ''),
          volume: '', date: c.updated_at ? String(c.updated_at).replace(' ', 'T') : ''
        };
        if (c.locked) row.locked = true;
        return row;
      });
      rows.sort(function (a, b) { return Number(b.num) - Number(a.num); });   /* newest first */
      return rows;
    },

    chapter: function (doc, url) {
      var j = json(doc), body = j && j.data && j.data.data && j.data.data.body;
      if (!Array.isArray(body)) {
        var pp = nextData(doc);
        if (pp && pp.serie && pp.serie.chapter) return { error: 'needs-post: the chapter text is only given by POST https://wtr-lab.com/api/reader/get (then a GET of the content_url it returns)' };
        return { error: 'no-content' };
      }
      var terms = (j.data.data.glossary_data && j.data.data.glossary_data.terms) || [];
      var fix = function (s) {
        return String(s).replace(/※(\d+)⛬/g, function (all, n) { var t = terms[Number(n)]; return t && t[0] ? t[0] : all; });
      };
      var paras = [];
      body.forEach(function (b) {
        if (typeof b !== 'string') return;
        var t = fix(b).replace(/\s+/g, ' ').trim();
        if (t) paras.push(t);
      });
      var title = fix(j.data.data.title || '').trim();
      var m = /^(.*\/chapter-)(\d+)/.exec(url || ''), n = m ? Number(m[2]) : 0;
      return {
        title: title, paras: paras, removed: 0,
        next: m ? m[1] + (n + 1) : '', prev: m && n > 1 ? m[1] + (n - 1) : ''
      };
    },

    /* the novel list pages (10 novels a page); search is POST-only on this site, so it falls back to the plain list */
    browseURL: function (kind, page, q) {
      var order = kind === 'popular' ? 'view' : 'update';
      return HOME + '/novel-list?orderBy=' + order + '&order=desc&page=' + (page || 1) +
             (kind === 'search' && q ? '&text=' + encodeURIComponent(q) : '');
    },
    browse: function (doc, url) {
      var pp = nextData(doc);
      if (!pp || !Array.isArray(pp.series)) return { items: [], next: false };
      var items = pp.series.filter(function (s) { return s && s.slug && s.raw_id; }).map(function (s) {
        var d = s.data || {}, bits = [];
        if (STATUS[s.status]) bits.push(STATUS[s.status]);
        if (s.chapter_count) bits.push(s.chapter_count + ' chapters');
        if (s.rating) bits.push('★ ' + (Math.round(s.rating * 10) / 10));
        return { url: novelUrl(s), title: plain(d.title), cover: d.image || '', meta: bits.join(' · ') };
      });
      var cur = Number((/[?&]page=(\d+)/.exec(url || '') || [0, 1])[1]), total = Number(pp.count) || 0;
      return { items: items, next: items.length >= 10 && cur * 10 < total };
    }
  };
})();
