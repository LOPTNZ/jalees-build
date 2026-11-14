/* The reading surface. Native code owns every control and calls JR.*; this page lays out chapter text and talks back
   through the "reader" message handler:
   {t:'ready'} {t:'loaded',id} {t:'pos',id,p,o,frac,left,end,top} {t:'tap',x,y} {t:'sel',on,rect}
   {t:'act',a,id} {t:'need',dir,id} {t:'markTap',id,ch,rect} {t:'page',i,n}

   Highlight offsets count characters of the paragraph's text without tatweel (ـ), so they stay valid whether the
   letter-spacing-by-kashida setting is on or off. */
(function () {
  'use strict';
  var page = document.getElementById('page'), root = document.documentElement;
  var secs = [];              // [{id, ch, el, paras:[el], text:[string]}] in reading order
  var marks = {};             // chapter id -> [mark]
  var P = { mode: 'chapter', anim: 'slide', kashida: 0, hideHead: false, ar: true, comments: true };
  var lastSent = '', raf = 0, idle = 0, selOn = false, needing = {}, guide = null, auto = null, find = null, wentUp = false, lastY = 0;

  function post(o) {
    try { window.webkit.messageHandlers.reader.postMessage(o); }
    catch (e) { if (window.__jrDev) window.__jrDev(o); }
  }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function num(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ','); }
  /* the English interface: the app hands over its words (JR.lang) */
  var TR = {};
  function T(s, v) { var t = TR[s] || s; return v == null ? t : t.replace('{}', v); }
  function minutesLabel(m) {
    if (TR.__en) return m <= 1 ? '1 minute' : m + ' minutes';
    return m <= 1 ? 'دقيقة' : m === 2 ? 'دقيقتان' : m <= 10 ? m + ' دقائق' : m + ' دقيقة';
  }
  function plain(s) { return String(s || '').replace(/ـ/g, ''); }
  function paged() { return P.mode === 'paged'; }
  function safeTop() {
    var t = document.getElementById('sat');
    if (!t) { t = document.createElement('div'); t.id = 'sat'; t.style.cssText = 'position:fixed;top:0;height:env(safe-area-inset-top,0px);width:0;visibility:hidden'; document.body.appendChild(t); }
    return t.getBoundingClientRect().height || 0;
  }
  function anchorY() { var v = parseFloat(getComputedStyle(root).getPropertyValue('--top')) || 64; return v + 6; }
  function kind(t) {
    if (/^[\s*＊٭\-–—_=~•·.]{3,}$/.test(t)) return 'sep';
    if (/^[\[【［『].*[\]】］』]$/.test(t) && t.length < 400) return 'sys';
    return '';
  }

  /* ---------- kashida: letter spacing for Arabic by stretching the joins ---------- */
  var NOJOIN = 'اأإآٱدذرزوؤةىءژ';
  function isAr(c) { var k = c.charCodeAt(0); return (k >= 0x0620 && k <= 0x064A) || (k >= 0x066E && k <= 0x06D3); }
  function isMark(c) { var k = c.charCodeAt(0); return (k >= 0x064B && k <= 0x065F) || k === 0x0670; }
  /* where a tatweel can go after the base letter at i: returns how many marks follow it, or -1 */
  function joinsNext(s, i) {
    var c = s[i];
    if (!isAr(c) || NOJOIN.indexOf(c) >= 0) return -1;
    var j = i + 1;
    while (j < s.length && isMark(s[j])) j++;
    return j < s.length && isAr(s[j]) ? j - i - 1 : -1;
  }

  /* ---------- a paragraph with its highlights ---------- */
  function paraHTML(text, list) {
    var s = plain(text), n = s.length, open = {}, close = {}, notes = {};
    (list || []).forEach(function (m) {
      var a = Math.max(0, Math.min(n, m.s)), b = Math.max(a, Math.min(n, m.e));
      if (b <= a) return;
      (open[a] = open[a] || []).push(m); (close[b] = close[b] || []).push(m);
      if (m.note && !notes[m.id]) notes[m.id] = a;
    });
    var out = '', active = [], k = P.kashida ? 'ـ'.repeat(P.kashida) : '';
    function openTag(m) { return '<mark class="hl c-' + esc(m.color || 'yellow') + (m.style === 'ul' ? ' ul' : '') + '" data-m="' + esc(m.id) + '">'; }
    for (var i = 0; i <= n; i++) {
      if (close[i] || open[i]) {
        for (var a = 0; a < active.length; a++) out += '</mark>';
        if (close[i]) active = active.filter(function (m) { return close[i].indexOf(m) < 0; });
        if (open[i]) open[i].forEach(function (m) { active.push(m); });
        for (var b = 0; b < active.length; b++) out += openTag(active[b]);
      }
      if (i === n) break;
      var c = s[i];
      out += c === '<' ? '&lt;' : c === '>' ? '&gt;' : c === '&' ? '&amp;' : c;
      if (k) { var mk = joinsNext(s, i); if (mk === 0) out += k; else if (mk > 0) { out += s.substr(i + 1, mk) + k; i += mk; } }
    }
    for (var z = 0; z < active.length; z++) out += '</mark>';
    /* notes sit in the margin beside the paragraph, like Apple Books */
    var ids = Object.keys(notes);
    if (ids.length) out = ids.map(function (id, j) { return '<span class="nt" data-m="' + esc(id) + '" style="top:' + (j * 1.1) + 'em" aria-label="' + T('ملاحظة') + '"></span>'; }).join('') + out;
    return out;
  }
  function paintPara(sec, i) {
    var el = sec.paras[i]; if (!el || el.classList.contains('pic')) return;
    var list = (marks[sec.id] || []).map(function (m) {
      var pe = m.pe == null ? m.p : m.pe;
      if (i < m.p || i > pe) return null;
      return { id: m.id, color: m.color, style: m.style, note: i === m.p ? m.note : '', s: i === m.p ? m.s : 0, e: i === pe ? m.e : 1e9 };
    }).filter(Boolean);
    el.innerHTML = paraHTML(sec.text[i], list);
    nameIn(el);
  }
  function paintSec(sec) { for (var i = 0; i < sec.paras.length; i++) paintPara(sec, i); }

  /* ---------- characters' names ---------- */
  var names = [], nameRe = null;
  function nameIn(el) {
    if (!nameRe || el.classList.contains('pic')) return;
    var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null), t, nodes = [];
    while ((t = w.nextNode())) if (!(t.parentElement && t.parentElement.closest('.nm'))) nodes.push(t);
    nodes.forEach(function (node) {
      var v = node.nodeValue, m, last = 0, frag = null;
      nameRe.lastIndex = 0;
      while ((m = nameRe.exec(v))) {
        var bare = m[2].replace(/ـ/g, ''), who = names.find(function (n) { return n.keys.indexOf(bare) >= 0; }); if (!who) continue;
        frag = frag || document.createDocumentFragment();
        var at = m.index + m[1].length;
        frag.appendChild(document.createTextNode(v.slice(last, at)));
        var s = document.createElement('span'); s.className = 'nm'; s.setAttribute('data-c', who.id); s.textContent = m[2]; frag.appendChild(s);
        last = at + m[2].length;
      }
      if (frag) { frag.appendChild(document.createTextNode(v.slice(last))); node.replaceWith(frag); }
    });
  }
  function namesAll() { secs.forEach(function (s) { s.paras.forEach(nameIn); }); }

  /* ---------- building a chapter ---------- */
  function secHTML(ch) {
    var h = '';
    /* an English chapter (its title and first lines in Latin letters) gets an English heading */
    var label = ch.label;
    var latin = label && /^الفصل\s+/.test(label) && !/[؀-ۿ]/.test((ch.title || '') + ' ' + (ch.paras[0] || '') + ' ' + (ch.paras[1] || ''));
    if (latin) label = label.replace(/^الفصل\s+/, 'Chapter ');
    if (!P.hideHead) h += '<header class="ch' + (latin ? ' lt' : '') + '">' + (label ? '<div class="n">' + esc(label) + '</div>' : '') + (ch.title ? '<div class="t">' + esc(ch.title) + '</div>' : '') + '</header>';
    else h += '<div class="ch-gap"></div>';
    h += '<article class="body">';
    for (var i = 0; i < ch.paras.length; i++) {
      var t = ch.paras[i];
      if (t.indexOf('￼img:') === 0) { h += '<p data-i="' + i + '" class="pic"><img src="' + esc(t.slice(5)) + '" alt="" loading="lazy"></p>'; continue; }
      var k = kind(t), ar = /[؀-ۿ]/.test(t);
      h += '<p data-i="' + i + '" class="' + [k, ar ? 'ar' : 'lt'].join(' ').trim() + '"></p>';
    }
    h += '</article><footer class="end"><div class="rule"></div>';
    var meta = [];
    if (ch.words) meta.push(T('عدد الكلمات {}', num(ch.words)));
    if (ch.minutes) meta.push(minutesLabel(ch.minutes));
    if (meta.length) h += '<div class="meta">' + meta.join(' · ') + '</div>';
    if (P.comments && ch.comments != null) h += '<button class="go cm" data-act="comments" data-id="' + ch.id + '"><span class="v">' + T('التعليقات') + (ch.comments ? ' (' + ch.comments + ')' : '') + '</span></button><div class="cms" data-cms="' + ch.id + '"></div>';
    if (P.mode !== 'continuous') {
      if (ch.next) h += '<button class="go" data-act="next"><span class="k">' + T('الفصل التالي') + '</span><span class="v">' + esc(ch.next) + '</span></button>';
      else h += '<div class="meta last">' + T('وصلت لآخر فصل منشور') + '</div>';
      if (ch.prev) h += '<button class="go prev" data-act="prev"><span class="v">' + esc(ch.prev) + '</span></button>';
    } else if (!ch.next) h += '<div class="meta last">' + T('وصلت لآخر فصل منشور') + '</div>';
    if (ch.removed) h += '<div class="clean">' + T('نظّفنا {} من إضافات الموقع', esc(ch.removed)) + '</div>';
    h += '</footer>';
    return h;
  }
  function makeSec(ch) {
    var el = document.createElement('section');
    el.className = 'chap'; el.setAttribute('data-id', ch.id); el.innerHTML = secHTML(ch);
    var sec = { id: ch.id, ch: ch, el: el, paras: Array.prototype.slice.call(el.querySelectorAll('.body p')), text: ch.paras.slice() };
    if (ch.marks) marks[ch.id] = ch.marks;
    paintSec(sec);
    return sec;
  }

  /* ---------- where the reader is ---------- */
  function secAt(y) {
    for (var i = 0; i < secs.length; i++) { var r = secs[i].el.getBoundingClientRect(); if (r.bottom > y) return secs[i]; }
    return secs[secs.length - 1];
  }
  function where() {
    if (!secs.length) return null;
    if (paged()) {
      var sec0 = secs[0], x = window.innerWidth / 2, best = 0;
      for (var q = 0; q < sec0.paras.length; q++) { var rr = sec0.paras[q].getBoundingClientRect(); if (rr.right > 0 && rr.left < window.innerWidth) { best = q; break; } }
      return { id: sec0.id, p: best, o: 0 };
    }
    var y = anchorY(), sec = secAt(y), ps = sec.paras;
    if (!ps.length) return { id: sec.id, p: 0, o: 0 };
    var lo = 0, hi = ps.length - 1;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (ps[mid].getBoundingClientRect().bottom > y) hi = mid; else lo = mid + 1; }
    var r = ps[lo].getBoundingClientRect(), o = r.height > 0 ? (y - r.top) / r.height : 0;
    return { id: sec.id, p: lo, o: Math.max(0, Math.min(1, +o.toFixed(4))) };
  }
  function secById(id) { for (var i = 0; i < secs.length; i++) if (secs[i].id === id) return secs[i]; return null; }
  function goTo(pos) {
    var sec = pos && pos.id != null ? secById(pos.id) : secs[0];
    if (!sec) sec = secs[0];
    if (!sec) return;
    if (paged()) {
      var tgt = pos && pos.end ? sec.el.querySelector('footer.end') : (pos && pos.p ? sec.paras[Math.min(sec.paras.length - 1, pos.p)] : null);
      pageTo(tgt ? pageOf(tgt) : 0, true);
      return;
    }
    if (pos && pos.end) { var f = sec.el.querySelector('footer.end'); window.scrollTo(0, Math.max(0, window.scrollY + f.getBoundingClientRect().bottom - window.innerHeight + 30)); return; }
    if (!pos || (!pos.p && !pos.o)) {
      if (secs[0] === sec) { window.scrollTo(0, 0); return; }
      var hd = sec.el.querySelector('header.ch, .ch-gap') || sec.el;
      window.scrollTo(0, Math.max(0, window.scrollY + hd.getBoundingClientRect().top - safeTop() - 18));
      return;
    }
    var el = sec.paras[Math.max(0, Math.min(sec.paras.length - 1, pos.p | 0))];
    if (!el) return;
    var r = el.getBoundingClientRect();
    window.scrollTo(0, Math.max(0, window.scrollY + r.top + r.height * (pos.o || 0) - anchorY()));
  }

  /* ---------- pages (slide and fade) ---------- */
  function pageW() { return window.innerWidth; }
  function pageCount() { return Math.max(1, Math.round(page.scrollWidth / pageW())); }
  function curPage() { return Math.round(Math.abs(window.scrollX) / pageW()); }
  function pageOf(el) { var r = el.getBoundingClientRect(); return Math.max(0, Math.floor((Math.abs(window.scrollX) + (pageW() - r.right)) / pageW())); }
  function pageTo(i, instant) {
    var n = pageCount(); i = Math.max(0, Math.min(n - 1, i));
    var x = -i * pageW();
    if (P.anim === 'curl') { window.scrollTo(x, 0); setTimeout(function () { report(true); }, 30); return; }
    if (P.anim === 'fade' && !instant) {
      page.style.transition = 'opacity .16s ease'; page.style.opacity = '0';
      setTimeout(function () { window.scrollTo(x, 0); page.style.opacity = '1'; report(true); }, 160);
    } else window.scrollTo({ left: x, top: 0, behavior: instant || P.anim === 'fade' ? 'auto' : 'smooth' });
    setTimeout(function () { report(true); }, 60);
  }

  function report(force, still) {
    if (!secs.length) return;
    var w = where(); if (!w) return;
    var m;
    if (paged()) {
      var n = pageCount(), i = curPage();
      m = { t: 'pos', id: w.id, p: w.p, o: 0, frac: n > 1 ? i / (n - 1) : 1, left: n - 1 - i, end: i >= n - 1, top: i === 0, page: i, pages: n };
    } else {
      var vh = window.innerHeight, sec = secById(w.id), r = sec.el.getBoundingClientRect();
      var below = r.bottom - vh, above = -r.top;
      m = { t: 'pos', id: w.id, p: w.p, o: w.o, frac: +Math.max(0, Math.min(1, above / Math.max(1, r.height - vh))).toFixed(4),
            left: Math.max(0, Math.ceil((below - 4) / vh)), end: below <= 40, top: above <= 2 };
      /* continuous: ask for the next chapter well before the end, and say when one is far behind */
      if (P.mode === 'continuous') {
        var last = secs[secs.length - 1], lr = last.el.getBoundingClientRect();
        if (lr.bottom - vh < vh * 1.5 && last.ch.next && !needing[last.id]) { needing[last.id] = 1; post({ t: 'need', dir: 'next', id: last.id }); }
        var first = secs[0];
        if (still && wentUp && first.el.getBoundingClientRect().top > -vh && first.ch.prev && !needing['p' + first.id] && window.scrollY < vh * 0.8) { needing['p' + first.id] = 1; wentUp = false; post({ t: 'need', dir: 'prev', id: first.id }); }
      }
    }
    var k = m.id + '|' + m.left + '|' + m.end + '|' + m.top + '|' + (m.page || 0);
    if (!force && k === lastSent) return;
    lastSent = k; post(m);
  }
  window.addEventListener('scroll', function () {
    var y = window.scrollY; if (y < lastY - 2) wentUp = true; lastY = y;
    if (!raf) raf = requestAnimationFrame(function () { raf = 0; report(false); });
    clearTimeout(idle); idle = setTimeout(function () { report(true, true); }, 200);
  }, { passive: true });

  function keepPlace(fn) { var w = secs.length ? where() : null; fn(); if (w) { goTo(w); report(true); } }

  var JR = window.JR = {};
  JR.lang = function (d) { TR = d || {}; };

  /* p: colours, fonts and sizes (see ReaderTheme.css) plus mode, anim, kashida, hideHead, comments */
  JR.setPrefs = function (p) {
    keepPlace(function () {
      var map = { bg: '--bg', fg: '--fg', soft: '--soft', line: '--line', tint: '--tint', font: '--font', head: '--head', latin: '--latin',
                  weight: '--weight', lh: '--lh', align: '--align' };
      Object.keys(map).forEach(function (k) { if (p[k] != null) root.style.setProperty(map[k], String(p[k])); });
      if (p.size != null) root.style.setProperty('--size', p.size + 'px');
      if (p.ls != null) root.style.setProperty('--ls', p.ls + 'em');
      if (p.ws != null) root.style.setProperty('--ws', p.ws + 'em');
      if (p.side != null) root.style.setProperty('--side', p.side + 'px');
      if (p.gap != null) root.style.setProperty('--gap', p.gap + 'em');
      if (p.top != null) root.style.setProperty('--top', p.top + 'px');
      if (p.bottom != null) root.style.setProperty('--bottom', p.bottom + 'px');
      if (p.cols != null) root.style.setProperty('--cols', String(p.cols));
      var rebuild = false;
      ['mode', 'anim', 'kashida', 'hideHead', 'comments'].forEach(function (k) { if (p[k] != null && p[k] !== P[k]) { P[k] = p[k]; rebuild = true; } });
      root.classList.toggle('paged', paged());
      root.classList.toggle('kashida', !!P.kashida);
      if (rebuild && secs.length) {
        var keep = secs.map(function (s) { return s.ch; }), first = keep[0];
        if (P.mode !== 'continuous') keep = [secs.length > 1 ? (secById(where().id) || secs[0]).ch : first];
        page.innerHTML = ''; secs = []; needing = {};
        keep.forEach(function (ch) { var s = makeSec(ch); secs.push(s); page.appendChild(s.el); });
      }
    });
  };
  JR.setSize = function (px) { keepPlace(function () { root.style.setProperty('--size', px + 'px'); }); if (guide) guideFollow(); };

  /* ch: {id,label,title,paras[],words,minutes,next,prev,removed,comments,marks}   pos: {p,o} | {end:true} | null */
  JR.load = function (ch, pos) {
    lastSent = ''; needing = {}; find = null; wentUp = false;
    page.innerHTML = ''; secs = [];
    var sec = makeSec(ch); secs.push(sec); page.appendChild(sec.el);
    var target = pos ? Object.assign({ id: ch.id }, pos) : null;
    goTo(target);
    var done = function () { goTo(target); report(true); post({ t: 'loaded', id: ch.id }); };
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(function () { requestAnimationFrame(done); });
    else requestAnimationFrame(done);
  };
  /* continuous reading: the next chapter joins the page below, the previous one above (the view stays put) */
  JR.append = function (ch) {
    if (secById(ch.id)) return;
    var last = secs[secs.length - 1];
    if (last) { var f = last.el.querySelector('footer.end'); if (f && !f.querySelector('.joint')) f.insertAdjacentHTML('beforeend', '<div class="joint"><span>' + esc(ch.label) + '</span></div>'); }
    var s = makeSec(ch); secs.push(s); page.appendChild(s.el);
    while (secs.length > 6) { var old = secs.shift(), h = old.el.getBoundingClientRect().height; old.el.remove(); window.scrollBy(0, -h); }
    report(true);
  };
  JR.prepend = function (ch) {
    if (secById(ch.id)) return;
    var s = makeSec(ch), before = document.documentElement.scrollHeight;
    var f = s.el.querySelector('footer.end'); if (f) f.insertAdjacentHTML('beforeend', '<div class="joint"><span>' + esc(secs[0] ? secs[0].ch.label : '') + '</span></div>');
    secs.unshift(s); page.insertBefore(s.el, page.firstChild);
    window.scrollBy(0, document.documentElement.scrollHeight - before);
    report(true);
  };

  /* state: 'loading' | 'error' */
  JR.state = function (state, title, detail) {
    secs = []; marks = {};
    page.innerHTML = '<div class="state">' + (state === 'loading' ? '<div class="spin"></div>' : '') +
      (title ? '<b>' + esc(title) + '</b>' : '') + (detail ? '<div>' + esc(detail) + '</div>' : '') +
      (state === 'error' ? '<button class="go" data-act="retry" style="max-width:260px"><span class="v">' + T('حاول مرة ثانية') + '</span></button>' : '') + '</div>';
    window.scrollTo(0, 0);
  };
  JR.where = function () { return where(); };
  JR.here = function () { var w = where(); lastY = window.scrollY; return w ? { id: w.id } : null; };
  JR.toChapter = function (id) {
    if (paged()) return 0;
    var s = secById(id); if (!s) return 0;
    goTo({ id: id }); lastY = window.scrollY; wentUp = false; report(true);
    return 1;
  };
  JR.goTo = function (pos) { goTo(pos); report(true); };
  JR.scrollBy = function (screens) { if (paged()) { pageTo(curPage() + (screens > 0 ? 1 : -1)); return; } window.scrollBy({ top: window.innerHeight * screens * 0.9, behavior: 'smooth' }); };
  JR.turn = function (dir, instant) { if (!paged()) return 0; var i = curPage(), n = pageCount(); if ((dir > 0 && i >= n - 1) || (dir < 0 && i <= 0)) return 0; pageTo(i + dir, !!instant); return 1; };
  JR.chapters = function () { return secs.map(function (s) { return s.id; }); };
  /* list: [{id, name, alias}] — names (and aliases) are matched as whole words, with common Arabic prefixes */
  JR.setNames = function (list, on, style) {
    ['tint', 'underline', 'bold', 'glow'].forEach(function (k) { root.classList.toggle('nm-' + k, (style || 'tint') === k); });
    names = (on ? list || [] : []).map(function (c) { return { id: c.id, keys: [c.name, c.alias].filter(function (k) { return k && k.trim().length > 1; }).map(function (k) { return k.trim(); }) }; }).filter(function (n) { return n.keys.length; });
    var keys = []; names.forEach(function (n) { keys = keys.concat(n.keys); });
    keys.sort(function (a, b) { return b.length - a.length; });
    var escRe = function (k) { return k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); };
    /* any letter may be followed by kashida when letter spacing is on */
    var stretchy = function (k) { return k.split('').map(escRe).join('ـ*'); };
    nameRe = keys.length ? new RegExp('(^|[^\\u0600-\\u06FFA-Za-z])(?:[وفبلك]ـ*)?(' + keys.map(stretchy).join('|') + ')(?=$|[^\\u0600-\\u06FFA-Za-z])', 'g') : null;
    secs.forEach(function (s) { paintSec(s); });
    return 1;
  };

  /* ---------- highlights ---------- */
  JR.setMarks = function (ch, list) { marks[ch] = list || []; var s = secById(ch); if (s) { keepPlace(function () { paintSec(s); }); } };
  JR.putMark = function (m) { var l = marks[m.ch] || (marks[m.ch] = []), i = l.findIndex(function (x) { return x.id === m.id; }); if (i >= 0) l[i] = m; else l.push(m); var s = secById(m.ch); if (s) { var pe = m.pe == null ? m.p : m.pe; for (var p = m.p; p <= pe; p++) paintPara(s, p); } };
  JR.dropMark = function (ch, id) { var l = marks[ch] || []; var m = l.find(function (x) { return x.id === id; }); marks[ch] = l.filter(function (x) { return x.id !== id; }); var s = secById(ch); if (s && m) { var pe = m.pe == null ? m.p : m.pe; for (var p = m.p; p <= pe; p++) paintPara(s, p); } };

  /* offset of (node, off) inside a paragraph, in characters without tatweel */
  function offsetIn(pEl, node, off) {
    var n = 0, w = document.createTreeWalker(pEl, NodeFilter.SHOW_TEXT, null), t;
    while ((t = w.nextNode())) {
      if (t === node) return n + plain(t.nodeValue.slice(0, off)).length;
      n += plain(t.nodeValue).length;
    }
    if (node === pEl || pEl.contains(node)) {
      /* the boundary is an element: count the text before its off-th child */
      var count = 0, kids = node.childNodes;
      for (var i = 0; i < off && i < kids.length; i++) count += plain(kids[i].textContent).length;
      var before = 0, w2 = document.createTreeWalker(pEl, NodeFilter.SHOW_TEXT, null), t2;
      while ((t2 = w2.nextNode())) { if (node.contains(t2)) break; before += plain(t2.nodeValue).length; }
      return before + count;
    }
    return n;
  }
  function paraOf(node) { var el = node.nodeType === 1 ? node : node.parentElement; return el && el.closest ? el.closest('.body p') : null; }
  /* the selected text as a highlight-to-be: {ch, chLabel, p, s, pe, e, text, rect} */
  JR.selection = function () {
    var sel = window.getSelection(); if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    var r = sel.getRangeAt(0), a = paraOf(r.startContainer), b = paraOf(r.endContainer);
    if (!a) return null; if (!b) b = a;
    var secEl = a.closest('section.chap'), sec = secEl && secById(+secEl.getAttribute('data-id'));
    if (!sec) return null;
    if (!secEl.contains(b)) b = sec.paras[sec.paras.length - 1];
    var p = +a.getAttribute('data-i'), pe = +b.getAttribute('data-i');
    var s = offsetIn(a, r.startContainer, r.startOffset), e = offsetIn(b, r.endContainer, r.endOffset);
    var ta = plain(sec.text[p]), tb = plain(sec.text[pe]);
    while (s > 0 && isWordChar(ta[s - 1])) s--;
    while (s < ta.length && /\s/.test(ta[s])) s++;
    while (e < tb.length && isWordChar(tb[e])) e++;
    while (e > 0 && /\s/.test(tb[e - 1])) e--;
    var rc = r.getBoundingClientRect();
    var out = { ch: sec.id, chLabel: sec.ch.label, p: p, s: s, pe: pe, e: e, rect: { x: rc.left, y: rc.top, w: rc.width, h: rc.height } };
    /* an existing highlight under the selection grows to cover both, and any other one it touches goes */
    var over = (marks[sec.id] || []).filter(function (m) { return before(m.p, m.s, out.pe, out.e) && before(out.p, out.s, m.pe == null ? m.p : m.pe, m.e); });
    if (over.length) {
      var m0 = over[0];
      over.forEach(function (m) {
        var mpe = m.pe == null ? m.p : m.pe;
        if (before(m.p, m.s, out.p, out.s)) { out.p = m.p; out.s = m.s; }
        if (before(out.pe, out.e, mpe, m.e)) { out.pe = mpe; out.e = m.e; }
      });
      out.merge = m0.id;
      out.drop = over.slice(1).map(function (m) { return m.id; });
    }
    out.text = textOf(sec, out.p, out.s, out.pe, out.e);
    return out;
  };
  function isWordChar(c) { return !!c && /[\u0600-\u06FF\u0750-\u077F\w]/.test(c); }
  /* (p1,s1) comes strictly before (p2,s2) */
  function before(p1, s1, p2, s2) { return p1 < p2 || (p1 === p2 && s1 < s2); }
  function textOf(sec, p, s, pe, e) {
    var parts = [];
    for (var i = p; i <= pe; i++) { var t = plain(sec.text[i]); parts.push(t.slice(i === p ? s : 0, i === pe ? e : t.length)); }
    return parts.join('\n').trim();
  }
  JR.clearSelection = function () { var s = window.getSelection(); if (s) s.removeAllRanges(); return 1; };
  /* the sentence around a selection, for a word's example */
  JR.sentence = function () {
    var sel = window.getSelection(); if (!sel || !sel.rangeCount) return '';
    var p = paraOf(sel.getRangeAt(0).startContainer); if (!p) return '';
    var t = plain(p.textContent), w = plain(sel.toString()).trim(), i = t.indexOf(w); if (i < 0) return t.slice(0, 240);
    var a = Math.max(t.lastIndexOf('.', i - 1), t.lastIndexOf('؟', i - 1), t.lastIndexOf('!', i - 1), t.lastIndexOf('\n', i - 1)) + 1;
    var ends = ['.', '؟', '!', '\n'].map(function (c) { var k = t.indexOf(c, i + w.length); return k < 0 ? t.length : k + 1; });
    return t.slice(a, Math.min.apply(null, ends)).trim().slice(0, 300);
  };
  JR.markRect = function (id) { var el = document.querySelector('mark[data-m="' + id + '"]'); if (!el) return null; var r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };

  /* ---------- comments at the end of a chapter ---------- */
  function cmHTML(list) {
    return list.map(function (c) {
      return '<div class="cm' + (c.spoiler ? ' spoil' : '') + '"><div class="cm-h"><b>' + esc(c.who || T('قارئ')) + '</b><small>' + esc(c.when || '') + '</small></div>' +
        '<p>' + esc(c.text).replace(/\n/g, '<br>') + '</p>' +
        (c.replies && c.replies.length ? '<div class="cm-r">' + c.replies.map(function (r) { return '<div class="cm"><div class="cm-h"><b>' + esc(r.who || T('قارئ')) + '</b><small>' + esc(r.when || '') + '</small></div><p>' + esc(r.text).replace(/\n/g, '<br>') + '</p></div>'; }).join('') + '</div>' : '') + '</div>';
    }).join('');
  }
  function cmTail(box, ch, total) {
    var shown = box.querySelectorAll(':scope > .cm').length;
    return (total > shown ? '<button class="go cm more" data-act="moreComments" data-id="' + ch + '"><span class="v">' + T('تعليقات أقدم ({})', num(total - shown)) + '</span></button>' : '') +
      '<button class="go cm site" data-act="commentsSite" data-id="' + ch + '"><span class="v">' + T('افتحها في الموقع بأسماء أصحابها') + '</span></button>';
  }
  JR.comments = function (ch, list, total) {
    var box = document.querySelector('[data-cms="' + ch + '"]'); if (!box) return;
    if (list == null) { box.innerHTML = '<div class="cm-wait"><span class="spin sm"></span>' + T('أجيب التعليقات') + '</div>'; return; }
    if (!list.length) { box.innerHTML = '<p class="cm-none">' + T('ما فيه تعليقات على هالفصل.') + '</p>'; return; }
    box.innerHTML = cmHTML(list);
    box.insertAdjacentHTML('beforeend', cmTail(box, ch, total));
  };
  JR.moreComments = function (ch, list, total) {
    var box = document.querySelector('[data-cms="' + ch + '"]'); if (!box) return;
    var y = window.scrollY;
    box.querySelectorAll(':scope > button, :scope > .cm-wait').forEach(function (b) { b.remove(); });
    if (list && list.length) box.insertAdjacentHTML('beforeend', cmHTML(list));
    box.insertAdjacentHTML('beforeend', cmTail(box, ch, list && list.length ? total : 0));
    window.scrollTo(0, y);
  };

  /* ---------- find in chapter ---------- */
  JR.find = function (q, nth) {
    document.querySelectorAll('mark.fd').forEach(function (m) { var t = document.createTextNode(m.textContent); m.replaceWith(t); });
    secs.forEach(function (s) { s.el.normalize(); });
    q = plain(q || '').trim(); if (!q) return 0;
    var hits = [];
    secs.forEach(function (s) {
      var w = document.createTreeWalker(s.el.querySelector('.body'), NodeFilter.SHOW_TEXT, null), t, nodes = [];
      while ((t = w.nextNode())) nodes.push(t);
      nodes.forEach(function (node) {
        var v = node.nodeValue, i = plain(v).indexOf(q);
        if (i < 0 || /ـ/.test(v)) return;
        var rest = node, at = i;
        while (at >= 0) {
          var mid = rest.splitText(at), after = mid.splitText(q.length), m = document.createElement('mark');
          m.className = 'fd'; m.textContent = mid.nodeValue; mid.replaceWith(m); hits.push(m);
          rest = after; at = rest.nodeValue.indexOf(q);
        }
      });
    });
    if (hits.length) { var h = hits[Math.max(0, Math.min(hits.length - 1, nth || 0))]; h.classList.add('on'); h.scrollIntoView({ block: 'center' }); report(true); }
    return hits.length;
  };

  /* ---------- line guide ---------- */
  /* the band sits exactly on a line of text; while dragging it follows the finger */
  function guideFollow(free) {
    if (!guide) return;
    var L = lineAt(guide.y), top = free ? guide.y : L.top, h = L.h * guide.lines;
    guide.el.style.setProperty('--y', (top - 2) + 'px');
    guide.el.style.setProperty('--h', (h + 4) + 'px');
  }
  /* the text's line height (from a paragraph, where it is set) */
  function lineH() {
    var p = document.querySelector('#page .body p:not(.pic)');
    var v = parseFloat(getComputedStyle(p || document.body).lineHeight);
    return v > 0 ? v : 30;
  }
  /* the line box under screen height y: its top and height, from the paragraph there */
  function lineAt(y) {
    var lh = lineH();
    for (var i = 0; i < secs.length; i++) for (var j = 0; j < secs[i].paras.length; j++) {
      var r = secs[i].paras[j].getBoundingClientRect();
      if (r.bottom >= y && r.top <= y + lh) {
        var n = Math.max(0, Math.round((y - r.top) / lh));
        return { top: r.top + n * lh, h: lh };
      }
    }
    return { top: y, h: lh };
  }
  JR.lineGuide = function (o) {
    var el = document.getElementById('guide');
    if (!o || !o.on) { if (el) el.remove(); guide = null; return 0; }
    if (!el) { el = document.createElement('div'); el.id = 'guide'; el.innerHTML = '<div class="g-band"></div><div class="g-grip" aria-label="' + T('حرّك دليل السطر') + '"><i></i><i></i></div>'; document.body.appendChild(el); }
    guide = { y: guide ? guide.y : window.innerHeight * 0.42, lines: o.lines || 1, dim: o.dim == null ? 0.72 : o.dim, el: el };
    el.style.setProperty('--dim', String(guide.dim));
    guideFollow();
    var grip = el.querySelector('.g-grip');
    if (!grip._drag) {
      grip._drag = 1; var startY = 0, startG = 0;
      grip.addEventListener('touchstart', function (e) { startY = e.touches[0].clientY; startG = guide.y; el.classList.add('moving'); }, { passive: true });
      grip.addEventListener('touchmove', function (e) { e.preventDefault(); guide.y = Math.max(20, Math.min(window.innerHeight - 60, startG + e.touches[0].clientY - startY)); guideFollow(true); }, { passive: false });
      var end = function () { el.classList.remove('moving'); guide.y = lineAt(guide.y).top; guideFollow(); };
      grip.addEventListener('touchend', end, { passive: true });
      grip.addEventListener('touchcancel', end, { passive: true });
    }
    return 1;
  };

  /* ---------- auto scroll ---------- */
  /* ---------- reading aloud: the sentence being read, marked and kept in view ---------- */
  /* plain offsets (without tatweel, which the page may add for letter spacing) to a range in the paragraph */
  function rangeAt(el, s, e) {
    var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), n, count = 0, r = document.createRange(), started = false;
    while ((n = w.nextNode())) {
      var t = n.nodeValue;
      for (var i = 0; i < t.length; i++) {
        if (t[i] === 'ـ') continue;
        if (!started && count === s) { r.setStart(n, i); started = true; }
        count++;
        if (started && count >= e) { r.setEnd(n, i + 1); return r; }
      }
    }
    if (started) { r.setEnd(el, el.childNodes.length); return r; }
    return null;
  }
  /* WebKit can leave a removed highlight painted: the paragraph that had it is drawn again */
  var ttsEl = null;
  function ttsUnmark() {
    if (window.CSS && CSS.highlights) CSS.highlights.delete('tts');
    if (ttsEl) {
      var was = ttsEl; ttsEl = null;
      was.classList.add('tts-rp');
      requestAnimationFrame(function () { requestAnimationFrame(function () { was.classList.remove('tts-rp'); }); });
    }
    var old = document.querySelectorAll('.tts-p'); for (var i = 0; i < old.length; i++) old[i].classList.remove('tts-p');
  }
  JR.ttsMark = function (id, p, s, e) {
    var sec = secById(id); if (!sec) return 0;
    var el = sec.paras[p]; if (!el) return 0;
    ttsUnmark();
    ttsEl = el;
    var r = null; try { r = rangeAt(el, s, e); } catch (x) { r = null; }
    if (r && window.CSS && CSS.highlights && window.Highlight) CSS.highlights.set('tts', new Highlight(r));
    else el.classList.add('tts-p');
    var rc = (r || el).getBoundingClientRect();
    if (paged()) {
      var pg = Math.max(0, Math.floor((Math.abs(window.scrollX) + (pageW() - rc.right)) / pageW()));
      if (pg !== curPage()) pageTo(pg);
    } else if (rc.top < anchorY() + 24 || rc.bottom > window.innerHeight - 170) {
      window.scrollBy({ top: rc.top - window.innerHeight * 0.32, behavior: 'smooth' });
    }
    return 1;
  };
  JR.ttsClear = function () { ttsUnmark(); return 1; };

  JR.autoScroll = function (pxPerSec) {
    if (auto) { cancelAnimationFrame(auto.raf); auto = null; }
    if (!pxPerSec || paged()) return 0;
    var last = performance.now(), acc = 0;
    auto = { raf: 0 };
    var step = function (t) { if (!auto) return; acc += (t - last) * pxPerSec / 1000; last = t; if (acc >= 1) { window.scrollBy(0, Math.floor(acc)); acc -= Math.floor(acc); } auto.raf = requestAnimationFrame(step); };
    auto.raf = requestAnimationFrame(step);
    return 1;
  };

  /* ---------- taps ---------- */
  document.addEventListener('click', function (e) {
    var b = e.target.closest ? e.target.closest('[data-act]') : null;
    if (b) {
      e.preventDefault();
      if (b.getAttribute('data-act') === 'moreComments') { if (b.disabled) return; b.disabled = true; b.innerHTML = '<span class="v"><span class="spin sm"></span> ' + T('أجيب الأقدم') + '</span>'; }
      post({ t: 'act', a: b.getAttribute('data-act'), id: +(b.getAttribute('data-id') || 0) });
      return;
    }
    var s = window.getSelection && window.getSelection();
    if (s && !s.isCollapsed) return;
    var nm = e.target.closest ? e.target.closest('.nm') : null;
    if (nm && !(window.getSelection() && !window.getSelection().isCollapsed)) { var nr = nm.getBoundingClientRect(); post({ t: 'nameTap', id: nm.getAttribute('data-c'), rect: { x: nr.left, y: nr.top, w: nr.width, h: nr.height } }); return; }
    var im = e.target.closest ? e.target.closest('p.pic img') : null;
    if (im) { post({ t: 'img', src: im.getAttribute('src') }); return; }
    var mk = e.target.closest ? e.target.closest('mark.hl, .nt') : null;
    if (mk) {
      var id = mk.getAttribute('data-m'), sec = mk.closest('section.chap'), r = mk.getBoundingClientRect();
      post({ t: 'markTap', id: id, ch: sec ? +sec.getAttribute('data-id') : 0, rect: { x: r.left, y: r.top, w: r.width, h: r.height } });
      return;
    }
    var tp = paraOf(e.target), tsec = tp && tp.closest('section.chap');
    post({ t: 'tap', x: +(e.clientX / window.innerWidth).toFixed(3), y: +(e.clientY / window.innerHeight).toFixed(3),
           pid: tsec ? +tsec.getAttribute('data-id') : null, pp: tp ? +tp.getAttribute('data-i') : null });
  });
  document.addEventListener('selectionchange', function () {
    var s = window.getSelection && window.getSelection(), on = !!(s && !s.isCollapsed);
    if (on !== selOn) { selOn = on; post({ t: 'sel', on: on }); }
  });
  window.addEventListener('resize', function () { report(true); });

  /* local preview in a desktop browser: reader.html?dev=<json file> */
  var dev = /[?&]dev=([^&]+)/.exec(location.search);
  if (dev) {
    window.__jrDev = function (o) { if (o.t === 'pos') document.title = 'ch' + o.id + ' p' + o.p + ' · left ' + o.left + (o.pages ? ' · page ' + o.page + '/' + o.pages : ''); else console.log('JR', JSON.stringify(o)); };
    fetch(decodeURIComponent(dev[1])).then(function (r) { return r.json(); }).then(function (ch) { JR.load(ch, null); });
  }
  post({ t: 'ready' });
})();
