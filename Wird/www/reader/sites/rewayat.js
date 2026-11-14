/* نادي الروايات (rewayat.club): a Nuxt/Vue site backed by a public JSON API (api.rewayat.club, plain GET, no login).
   - novel page and chapter page: the server-rendered HTML is read (title, chips, paragraphs are all in it)
   - chapter list: https://api.rewayat.club/api/chapters/<slug>/?ordering=-number&page_size=2000 (all chapters in one answer)
   - listing / search: https://api.rewayat.club/api/novels/?page=N&search=q */
(function () {
  'use strict';
  var K = window.SourceKit, txt = K.txt, abs = K.abs, digits = K.digits;
  var HOME = 'https://rewayat.club/', API = 'https://api.rewayat.club/api/';

  function jsonOf(doc) {
    var t = ((doc.body ? doc.body.textContent : '') || '').trim();
    if (t.charAt(0) !== '{') return null;
    try { return JSON.parse(t); } catch (e) { return null; }
  }
  function slugOf(url) { var m = url.match(/\/novel\/([^\/?#]+)/); return m ? m[1] : ''; }
  function https(u) { return String(u || '').replace(/^http:\/\//, 'https://'); }

  Sources.rewayat = {
    id: 'rewayat', name: 'نادي الروايات', home: HOME, lang: 'ar',
    hosts: ['rewayat.club', 'www.rewayat.club'],
    isSeries: function (url) { return /\/novel\/[^\/?#]+\/?(?:[?#].*)?$/.test(url); },
    seriesUrl: function (doc, url) {
      var s = slugOf(url);
      if (!s) { var a = doc.querySelector('h1 a[href*="/novel/"]'); s = a ? slugOf(a.getAttribute('href')) : ''; }
      return s ? HOME + 'novel/' + s : '';
    },
    clean: [/نادي الروايات/, /rewayat/i, /^(ترجمة|تدقيق|المترجم|المدقق)\s*[:：-]/, /^(تابعونا|انضم(وا)? إلى)/],

    series: function (doc, url) {
      var h = doc.querySelector('h1'), title = txt(h);
      var slug = slugOf(url);
      if (!title || !slug) return { error: 'no-title' };
      var chips = Array.prototype.map.call(doc.querySelectorAll('.v-chip'), function (c) {
        return { t: txt(c), href: c.getAttribute('href') || '' };
      });
      var status = '';
      chips.forEach(function (c) { if (/^(مكتملة|مستمرة|متوقفة|قيد الترجمة)/.test(c.t)) status = c.t; });
      var genres = chips.filter(function (c) { return /genre=/.test(c.href); }).map(function (c) { return c.t; });
      var syn = doc.querySelector('.text-pre-line'), tr = doc.querySelector('a[href^="/user/"] .v-chip__content span:last-child, a[href^="/user/"]');
      var html = doc.documentElement ? doc.documentElement.innerHTML : '', cv = html.match(/poster_url:"([^"]+)"/);
      var cover = cv ? https(cv[1].replace(/\\u002F/g, '/')) : '';
      return {
        title: title, author: '', cover: cover, summary: txt(syn).slice(0, 4000), status: status, total: 0, translator: txt(tr),
        genres: genres.slice(0, 10),
        listPages: [HOME + 'novel/' + slug, API + 'chapters/' + slug + '/?ordering=-number&page_size=2000'],
        rows: []
      };
    },

    /* the JSON answer of the chapters API (newest first); on the novel page itself there are no rows */
    list: function (doc, url) {
      var j = jsonOf(doc), rows = [];
      var m = url.match(/\/api\/chapters\/([^\/?#]+)/);
      if (!j || !j.results || !m) return rows;
      var seen = {};
      j.results.forEach(function (c) {
        if (c.number === undefined || c.number === null) return;
        var href = HOME + 'novel/' + m[1] + '/' + c.number + '/';
        if (seen[href]) return; seen[href] = 1;
        rows.push({ url: href, num: String(c.number), title: String(c.title || '').trim(), volume: '', date: c.date || '' });
      });
      return rows;
    },

    chapter: function (doc, url) {
      var box = doc.querySelector('.v-card__text.pre-formatted, .pre-formatted');
      if (!box) return { error: 'no-content' };
      var sub = txt(doc.querySelector('.v-card__subtitle')), title = sub.replace(/^\s*[\d٠-٩]+\s*[-–—:]\s*/, '');
      var ps = K.paragraphs(box, '[hidden], [aria-hidden="true"]');
      var c = K.tidy(ps, this.clean, 6);
      var m = url.match(/\/novel\/([^\/?#]+)\/(\d+)/), next = '', prev = '';
      if (m) {
        var links = doc.querySelectorAll('a[href*="/novel/' + m[1] + '/"]');
        for (var i = 0; i < links.length; i++) {
          var lm = (links[i].getAttribute('href') || '').match(/\/novel\/[^\/?#]+\/(\d+)\/?(?:\?|$)/);
          if (!lm) continue;
          var n = parseInt(lm[1], 10), cur = parseInt(m[2], 10);
          if (n === cur + 1 && !next) next = HOME + 'novel/' + m[1] + '/' + n + '/';
          if (n === cur - 1 && !prev) prev = HOME + 'novel/' + m[1] + '/' + n + '/';
        }
      }
      return { title: title, paras: c.paras, removed: c.removed, next: next, prev: prev };
    },

    /* the API's default order is the site's own popular order */
    browseURL: function (kind, page, q) {
      var u = API + 'novels/?page=' + (page > 1 ? page : 1);
      if (kind === 'search') u += '&search=' + encodeURIComponent(q || '');
      return u;
    },
    browse: function (doc, url) {
      var j = jsonOf(doc), items = [];
      if (!j || !j.results) return { items: items, next: false };
      j.results.forEach(function (n) {
        if (!n.slug) return;
        var bits = [n.complete ? 'مكتملة' : 'مستمرة'];
        if (n.num_chapters) bits.push(n.num_chapters + ' فصل');
        items.push({ url: HOME + 'novel/' + n.slug, title: n.arabic || n.english || n.slug, cover: https(n.poster_url), meta: bits.join(' · ') });
      });
      return { items: items, next: !!j.next };
    }
  };
})();
