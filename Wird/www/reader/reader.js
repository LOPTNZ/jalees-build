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
  var P = { mode: 'chapter', anim: 'slide', kashida: 0, hideHead: false, ar: true, comments: true, dir: 'auto' };
  var rtl = true;             // the book's direction (see bookDir)
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
  /* an EPUB footnote reference is one private-use character in the text (Epub.swift); fn = {n: markers before this
     paragraph, notes: {k: text}} says which note it opens. One character in the text, one in the page, so the
     highlight offsets stay what they are. */
  function fnTag(fn, k) {
    if (fn && fn.notes && fn.notes[k]) return '<a class="fn" data-fn="' + k + '" data-n="' + k + '"></a>';
    return '<span class="fn0"></span>';
  }
  function paraHTML(text, list, fn) {
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
      if (c === '') { if (fn) fn.n++; out += fnTag(fn, fn ? fn.n : 0); continue; }
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
    el.innerHTML = paraHTML(sec.text[i], list, { n: sec.fnBase ? sec.fnBase[i] : 0, notes: sec.notes });
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
    /* an EPUB section brings its footnotes as a last paragraph «￼notes:{json}» (Epub.swift): they are not text to read */
    var lastP = ch.paras.length ? ch.paras[ch.paras.length - 1] : '';
    if (typeof lastP === 'string' && lastP.indexOf('￼notes:') === 0) {
      try { ch.notes = JSON.parse(lastP.slice(7)); } catch (e) { ch.notes = ch.notes || {}; }
      ch.paras = ch.paras.slice(0, -1);
    }
    var el = document.createElement('section');
    el.className = 'chap'; el.setAttribute('data-id', ch.id); el.innerHTML = secHTML(ch);
    var sec = { id: ch.id, ch: ch, el: el, paras: Array.prototype.slice.call(el.querySelectorAll('.body p')), text: ch.paras.slice(), notes: ch.notes || {}, fnBase: [] };
    for (var fi = 0, fc = 0; fi < sec.text.length; fi++) { sec.fnBase.push(fc); fc += (String(sec.text[fi]).match(//g) || []).length; }
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
    /* past a chapter's last paragraph (its footer, which shows the next chapter's name) is the next chapter's top:
       at the top of chapter 34 the reader is in 34, not at the end of 33 (that made a swipe forward land on the same
       chapter, a swipe back skip one, and the place saved be the end of the chapter before) */
    var lastR = ps[ps.length - 1].getBoundingClientRect(), k = secs.indexOf(sec);
    if (y > lastR.bottom && k >= 0 && k + 1 < secs.length) return { id: secs[k + 1].id, p: 0, o: 0 };
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
  /* the book's direction: an Arabic book turns its pages to the left (scrollX goes negative), an English one to the
     right (scrollX goes positive), whatever the app's own language is */
  function pageW() { return window.innerWidth; }
  function pageCount() { return Math.max(1, Math.round(page.scrollWidth / pageW())); }
  function curPage() { return Math.round(Math.abs(window.scrollX) / pageW()); }
  /* the page holding the start of a box (a rect in viewport coordinates) */
  function pageOfRect(r) {
    var x = rtl ? Math.abs(window.scrollX) + (pageW() - r.right) : window.scrollX + r.left;
    return Math.max(0, Math.floor(x / pageW()));
  }
  function pageOf(el) { return pageOfRect(el.getBoundingClientRect()); }
  function pageTo(i, instant) {
    var n = pageCount(); i = Math.max(0, Math.min(n - 1, i));
    var x = (rtl ? -i : i) * pageW();
    if (P.anim === 'curl') { window.scrollTo(x, 0); setTimeout(function () { report(true); guideRefresh(); }, 30); return; }
    if (P.anim === 'fade' && !instant) {
      page.style.transition = 'opacity .16s ease'; page.style.opacity = '0';
      setTimeout(function () { window.scrollTo(x, 0); page.style.opacity = '1'; report(true); guideRefresh(); }, 160);
    } else window.scrollTo({ left: x, top: 0, behavior: instant || P.anim === 'fade' ? 'auto' : 'smooth' });
    setTimeout(function () { report(true); guideRefresh(); }, 60);
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
    clearTimeout(idle); idle = setTimeout(function () { report(true, true); guideRefresh(); }, 200);
  }, { passive: true });

  /* a book reads in the direction of its language: by the letters of its first paragraphs unless P.dir says 'rtl' or 'ltr' */
  function bookDir(ch) {
    if (P.dir === 'rtl') return true;
    if (P.dir === 'ltr') return false;
    if (!ch) return rtl;
    var a = 0, l = 0, ps = ch.paras || [];
    for (var i = 0; i < ps.length && i < 80; i++) {
      var t = String(ps[i] || ''); if (t.indexOf('￼img:') === 0) continue;
      t = t.slice(0, 400);
      a += (t.match(/[؀-ۿݐ-ݿ]/g) || []).length; l += (t.match(/[A-Za-z]/g) || []).length;
    }
    if (!a && !l) return rtl;
    return a >= l;
  }
  function applyDir(r) {
    rtl = !!r;
    root.setAttribute('dir', rtl ? 'rtl' : 'ltr'); root.setAttribute('lang', rtl ? 'ar' : 'en');
    root.classList.toggle('ltr', !rtl);
    post({ t: 'dir', rtl: rtl });   // the page turns, taps and swipes outside follow it
  }

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
      if (p.dir != null && p.dir !== P.dir) { P.dir = p.dir; applyDir(bookDir(secs.length ? secs[0].ch : null)); }
      var rebuild = false, curId = secs.length > 1 ? where().id : null;   // read before the mode changes
      ['mode', 'anim', 'kashida', 'hideHead', 'comments'].forEach(function (k) { if (p[k] != null && p[k] !== P[k]) { P[k] = p[k]; rebuild = true; } });
      root.classList.toggle('paged', paged());
      root.classList.toggle('kashida', !!P.kashida);
      if (rebuild && secs.length) {
        var keep = secs.map(function (s) { return s.ch; }), first = keep[0];
        /* highlights made since the chapter came in must survive the rebuild */
        keep.forEach(function (c) { if (marks[c.id]) c.marks = marks[c.id]; });
        if (P.mode !== 'continuous') keep = [curId != null ? (secById(curId) || secs[0]).ch : first];
        page.innerHTML = ''; secs = []; needing = {};
        keep.forEach(function (ch) { var s = makeSec(ch); secs.push(s); page.appendChild(s.el); });
      }
    });
    guideRefresh(true);   // the columns may have changed (rotation, mode)
  };
  JR.setSize = function (px) { keepPlace(function () { root.style.setProperty('--size', px + 'px'); }); if (guide) guideFollow(); };

  /* ch: {id,label,title,paras[],words,minutes,next,prev,removed,comments,marks}   pos: {p,o} | {end:true} | null */
  JR.load = function (ch, pos) {
    lastSent = ''; needing = {}; find = null; wentUp = false;
    page.innerHTML = ''; secs = []; marks = {};
    applyDir(bookDir(ch));
    var sec = makeSec(ch); secs.push(sec); page.appendChild(sec.el);
    var target = pos ? Object.assign({ id: ch.id }, pos) : null;
    goTo(target);
    var done = function () { goTo(target); report(true); guideRefresh(true); post({ t: 'loaded', id: ch.id }); };
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(function () { requestAnimationFrame(done); });
    else requestAnimationFrame(done);
  };
  /* continuous reading: the next chapter joins the page below, the previous one above (the view stays put) */
  JR.append = function (ch) {
    if (secById(ch.id)) return;
    var last = secs[secs.length - 1];
    if (last) { var f = last.el.querySelector('footer.end'); if (f && !f.querySelector('.joint')) f.insertAdjacentHTML('beforeend', '<div class="joint"><span>' + esc(ch.label) + '</span></div>'); }
    var s = makeSec(ch); secs.push(s); page.appendChild(s.el);
    while (secs.length > 6) {
      var old = secs.shift(), h = old.el.getBoundingClientRect().height; old.el.remove(); window.scrollBy(0, -h);
      delete marks[old.id]; delete needing['p' + old.id]; post({ t: 'drop', id: old.id });
    }
    if (secs[0]) delete needing['p' + secs[0].id];
    report(true);
  };
  JR.prepend = function (ch) {
    if (secById(ch.id)) return;
    var s = makeSec(ch), before = document.documentElement.scrollHeight;
    var f = s.el.querySelector('footer.end'); if (f) f.insertAdjacentHTML('beforeend', '<div class="joint"><span>' + esc(secs[0] ? secs[0].ch.label : '') + '</span></div>');
    secs.unshift(s); page.insertBefore(s.el, page.firstChild);
    window.scrollBy(0, document.documentElement.scrollHeight - before);
    /* far below the reader: let go of the last chapters (they can be asked for again) */
    while (secs.length > 6) {
      var tail = secs.pop(); tail.el.remove(); delete marks[tail.id]; delete needing[tail.id]; post({ t: 'drop', id: tail.id });
    }
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
  /* a chapter already on the page: at its start, or at pos ({p, o}: where the reader stopped in it) */
  JR.toChapter = function (id, pos) {
    if (paged()) return 0;
    var s = secById(id); if (!s) return 0;
    goTo(pos && (pos.p || pos.o) ? { id: id, p: pos.p, o: pos.o } : { id: id }); lastY = window.scrollY; wentUp = false; report(true); guideRefresh();
    return 1;
  };
  JR.goTo = function (pos) { goTo(pos); report(true); guideRefresh(); };
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
    /* whole words, but only the ones the selection is inside: an end that iOS puts at the start of the next word
       (after the space) or a start just after the previous one must not take that word in */
    while (s < ta.length && /\s/.test(ta[s])) s++;
    if (s < ta.length && isWordChar(ta[s])) while (s > 0 && isWordChar(ta[s - 1])) s--;
    while (e > 0 && /\s/.test(tb[e - 1])) e--;
    if (e > 0 && isWordChar(tb[e - 1])) while (e < tb.length && isWordChar(tb[e])) e++;
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
    return parts.join('\n').replace(//g, '').trim();   // footnote markers are not part of the quoted words
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
    q = plain(q || '').trim().toLowerCase(); if (!q) return 0;   // the search list ignores case, so the nth hit matches
    var hits = [];
    secs.forEach(function (s) {
      var w = document.createTreeWalker(s.el.querySelector('.body'), NodeFilter.SHOW_TEXT, null), t, nodes = [];
      while ((t = w.nextNode())) nodes.push(t);
      nodes.forEach(function (node) {
        var v = node.nodeValue, i = v.toLowerCase().indexOf(q);
        if (i < 0 || /ـ/.test(v)) return;
        var rest = node, at = i;
        while (at >= 0) {
          var mid = rest.splitText(at), after = mid.splitText(q.length), m = document.createElement('mark');
          m.className = 'fd'; m.textContent = mid.nodeValue; mid.replaceWith(m); hits.push(m);
          rest = after; at = rest.nodeValue.toLowerCase().indexOf(q);
        }
      });
    });
    if (hits.length) { var h = hits[Math.max(0, Math.min(hits.length - 1, nth || 0))]; h.classList.add('on'); h.scrollIntoView({ block: 'center' }); report(true); }
    return hits.length;
  };

  /* ---------- line guide ---------- */
  /* The band sits exactly on a line of text; while dragging it follows the finger. In one column it spans the screen.
     Where the text runs in several columns (a landscape chapter, two pages side by side) the guide belongs to ONE of
     them: the band covers that column only, snaps to its lines, and the grip sits at the column's outer edge.
     Dragging the grip along the lines moves it on, past a column's last line into the next column (reading order
     follows the book's direction), and sideways onto another column moves it there. */

  /* the columns the text is in, in reading order: {n, cols:[{x0,x1,left}]} (left: the column is on the screen's left half) */
  function guideGeo() {
    var W = window.innerWidth, n = 1, vis = [], cs = getComputedStyle(page), k;
    if (paged()) {
      var cw = parseFloat(cs.columnWidth);
      n = cw > 0 ? Math.max(1, Math.round(W / cw)) : 1;
      for (k = 0; k < n; k++) vis.push({ x0: k * W / n, x1: (k + 1) * W / n });
    } else {
      n = parseInt(cs.columnCount, 10) || 1;
      if (n > 1) {
        var r = page.getBoundingClientRect(), pl = parseFloat(cs.paddingLeft) || 0, pr = parseFloat(cs.paddingRight) || 0;
        var gap = parseFloat(cs.columnGap); if (!(gap >= 0)) gap = parseFloat(cs.fontSize) || 22;
        var w = (r.width - pl - pr - (n - 1) * gap) / n;
        for (k = 0; k < n; k++) vis.push({ x0: r.left + pl + k * (w + gap), x1: r.left + pl + k * (w + gap) + w });
      }
    }
    if (n < 2) return { n: 1, cols: [{ x0: 0, x1: W, left: true }] };
    for (k = 0; k < n; k++) vis[k].left = k < n / 2;
    return { n: n, cols: rtl ? vis.reverse() : vis };
  }
  function colAtX(g, x) {
    var best = 0, d = 1e9;
    for (var i = 0; i < g.n; i++) { var m = Math.abs(x - (g.cols[i].x0 + g.cols[i].x1) / 2); if (m < d) { d = m; best = i; } }
    return best;
  }
  /* the text's line height (from a paragraph, where it is set) */
  function lineH() {
    var p = document.querySelector('#page .body p:not(.pic)');
    var v = parseFloat(getComputedStyle(p || document.body).lineHeight);
    return v > 0 ? v : 30;
  }
  /* the lines of text in column ci (all of the document when `all`, else those on the screen): [top] sorted, one per
     line (the middle of each line's text boxes, less half a line) */
  function colLines(g, ci, all) {
    var lh = lineH(), vh = window.innerHeight, c = g.cols[ci], rg = document.createRange(), cys = [];
    for (var i = 0; i < secs.length; i++) for (var j = 0; j < secs[i].paras.length; j++) {
      var p = secs[i].paras[j], pr = p.getBoundingClientRect();
      if (!pr.height || pr.right < c.x0 || pr.left > c.x1) continue;
      if (!all && (pr.bottom < -lh || pr.top > vh + lh)) continue;
      var w = document.createTreeWalker(p, NodeFilter.SHOW_TEXT, null), t;
      while ((t = w.nextNode())) {
        rg.selectNodeContents(t);
        var rs = rg.getClientRects();
        for (var q = 0; q < rs.length; q++) {
          var rc = rs[q];
          if (rc.width < 1 || rc.height < 1) continue;
          if (colAtX(g, (rc.left + rc.right) / 2) !== ci) continue;
          if (!all && (rc.bottom < -lh || rc.top > vh + lh)) continue;
          cys.push((rc.top + rc.bottom) / 2);
        }
      }
    }
    cys.sort(function (a, b) { return a - b; });
    var out = [];
    for (var m = 0; m < cys.length; m++) {
      if (out.length && cys[m] - out[out.length - 1].cy < lh * 0.45) continue;
      out.push({ cy: cys[m], top: cys[m] - lh / 2 });
    }
    return out.map(function (o) { return o.top; });
  }
  /* the line of column ci nearest to screen height y (a line's top and height), or y itself where there is no line */
  function nearLine(g, ci, y) {
    var lh = lineH(), tops = colLines(g, ci, false), best = null, d = 1e9;
    for (var i = 0; i < tops.length; i++) { var m = Math.abs(tops[i] - y); if (m < d) { d = m; best = tops[i]; } }
    return d <= lh * 1.2 && best != null ? { top: best, h: lh } : { top: y, h: lh };
  }
  /* the line box under screen height y: its top and height, from the paragraph there (one column) */
  function lineAtOne(y) {
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
  function lineAt(y) {
    var g = guideGeo();
    return g.n < 2 ? lineAtOne(y) : nearLine(g, Math.min(guide ? guide.col || 0 : 0, g.n - 1), y);
  }
  function guideFollow(free) {
    if (!guide) return;
    var g = guideGeo(), el = guide.el, W = window.innerWidth;
    if (g.n < 2) {
      el.classList.remove('mc');
      var L = lineAtOne(guide.y), top = free ? guide.y : L.top, h = L.h * guide.lines;
      el.style.setProperty('--y', (top - 2) + 'px');
      el.style.setProperty('--h', (h + 4) + 'px');
      return;
    }
    var ci = Math.min(guide.col || 0, g.n - 1), c = g.cols[ci];
    guide.col = ci;
    var L2 = nearLine(g, ci, guide.y), top2 = free ? guide.y : L2.top, h2 = L2.h * guide.lines;
    el.classList.add('mc');
    el.style.setProperty('--y', (top2 - 2) + 'px');
    el.style.setProperty('--h', (h2 + 4) + 'px');
    el.style.setProperty('--x0', c.x0 + 'px');
    el.style.setProperty('--x1', c.x1 + 'px');
    /* the grip at the column's outer edge: left of a left column, right of a right one (beside the text, not on it) */
    el.style.setProperty('--gx', (c.left ? Math.max(2, c.x0 - 32) : Math.min(W - 32, c.x1 + 2)) + 'px');
  }
  /* put the guide in place again after the text moved or reflowed (page turn, rotation, size): only where it matters,
     as the one-column scrolling guide has always stayed where it was */
  function guideRefresh(force) {
    if (!guide) return;
    if (force || paged() || guideGeo().n > 1) guideFollow();
  }
  /* is there more of the column below the screen (above it)? Only scrolling text has any */
  function moreBelow() { if (paged()) return false; var cs = getComputedStyle(page); return page.getBoundingClientRect().bottom - (parseFloat(cs.paddingBottom) || 0) > window.innerHeight + 2; }
  function moreAbove() { return !paged() && window.scrollY > 2; }
  /* move into column ci at its first (or last) line; scrolling text is scrolled to show that line. Returns the new
     screen height of the band, or null if the column has no lines to go to */
  function guideEnter(g, ci, first) {
    var lh = lineH(), vh = window.innerHeight, tops = colLines(g, ci, !paged());
    if (!tops.length) return null;
    var t = first ? tops[0] : tops[tops.length - 1];
    if (!paged() && (t < anchorY() || t > vh - 80)) {
      var dest = first ? anchorY() + 20 : vh - 110, y0 = window.scrollY;
      window.scrollTo(0, Math.max(0, y0 + t - dest));
      t -= window.scrollY - y0;
    }
    guide.col = ci;
    return Math.max(20, Math.min(vh - 60, t));
  }
  JR.lineGuide = function (o) {
    var el = document.getElementById('guide');
    if (!o || !o.on) { if (el) el.remove(); guide = null; return 0; }
    if (!el) { el = document.createElement('div'); el.id = 'guide'; el.innerHTML = '<div class="g-band"></div><div class="g-grip" aria-label="' + T('حرّك دليل السطر') + '"><i></i><i></i></div>'; document.body.appendChild(el); }
    guide = { y: guide ? guide.y : window.innerHeight * 0.42, col: guide ? guide.col : 0, lines: o.lines || 1, dim: o.dim == null ? 0.72 : o.dim, el: el };
    el.style.setProperty('--dim', String(guide.dim));
    guideFollow();
    var grip = el.querySelector('.g-grip');
    if (!grip._drag) {
      grip._drag = 1; var startY = 0, startG = 0;
      grip.addEventListener('touchstart', function (e) { startY = e.touches[0].clientY; startG = guide.y; el.classList.add('moving'); }, { passive: true });
      grip.addEventListener('touchmove', function (e) {
        e.preventDefault();
        var tc = e.touches[0], vh = window.innerHeight, g = guideGeo();
        if (g.n < 2) { guide.y = Math.max(20, Math.min(vh - 60, startG + tc.clientY - startY)); guideFollow(true); return; }
        /* sideways onto another column: the guide goes there, at the same height */
        var cc = colAtX(g, tc.clientX);
        if (cc !== guide.col) { guide.col = cc; guide.y = Math.max(20, Math.min(vh - 60, startG + tc.clientY - startY)); guideFollow(true); return; }
        var raw = startG + tc.clientY - startY, lh = lineH(), tops = colLines(g, guide.col, false), moved = null, to = guide.col;
        if (tops.length) {
          /* past a column's last line (first line): on into the next (previous) column of the book */
          if (raw > tops[tops.length - 1] + lh * 1.3 && !moreBelow() && guide.col + 1 < g.n) { to = guide.col + 1; moved = guideEnter(g, to, true); }
          else if (raw < tops[0] - lh * 0.6 && !moreAbove() && guide.col > 0) { to = guide.col - 1; moved = guideEnter(g, to, false); }
        }
        if (moved != null) { guide.y = moved; startY = tc.clientY; startG = moved; guideFollow(); return; }
        guide.y = Math.max(20, Math.min(vh - 60, raw)); guideFollow(true);
      }, { passive: false });
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
      var pg = pageOfRect(rc);
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

  /* ---------- footnotes in a small window (EPUB) ---------- */
  var fnPop = null;
  function fnClose() { if (fnPop) { if (fnPop.parentNode) fnPop.parentNode.removeChild(fnPop); fnPop = null; } }
  function fnOpen(a) {
    var secEl = a.closest('section.chap'), sec = secEl && secById(+secEl.getAttribute('data-id'));
    var text = sec && sec.notes && sec.notes[a.getAttribute('data-fn')];
    if (!text) return;
    var pop = document.createElement('div'); pop.id = 'fnpop'; pop._a = a;
    var body = document.createElement('div'); body.className = 'fb'; body.setAttribute('dir', 'auto'); body.textContent = text;
    pop.appendChild(body); pop.style.visibility = 'hidden';
    document.body.appendChild(pop); fnPop = pop;
    var W = window.innerWidth, H = window.innerHeight, r = a.getBoundingClientRect(), w = Math.min(W - 24, 340);
    pop.style.width = w + 'px';
    var h = pop.offsetHeight, left = Math.max(12, Math.min(W - w - 12, r.left + r.width / 2 - w / 2)), top = r.bottom + 8;
    if (top + h > H - 12) top = Math.max(safeTop() + 8, r.top - 8 - h);
    pop.style.left = left + 'px'; pop.style.top = top + 'px'; pop.style.visibility = '';
  }
  /* capture phase: a tap on a reference opens its note, a tap anywhere else only closes it; neither reaches the
     handler below, so the controls do not toggle and nothing is selected */
  document.addEventListener('click', function (e) {
    var t = e.target, a = t && t.closest ? t.closest('a.fn') : null;
    if (a) {
      e.preventDefault(); e.stopPropagation();
      var same = fnPop && fnPop._a === a; fnClose();
      if (!same) fnOpen(a);
      return;
    }
    if (fnPop) {
      e.stopPropagation();
      if (!(t && t.closest && t.closest('#fnpop'))) { e.preventDefault(); fnClose(); }
    }
  }, true);
  window.addEventListener('scroll', fnClose, { passive: true });
  window.addEventListener('resize', fnClose);
  document.addEventListener('touchmove', function (e) { if (fnPop && !(e.target && e.target.closest && e.target.closest('#fnpop'))) fnClose(); }, { passive: true });

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
  window.addEventListener('resize', function () {
    report(true);
    if (guide) { guide.y = Math.min(guide.y, window.innerHeight - 60); guideRefresh(true); setTimeout(function () { guideRefresh(true); }, 250); }
  });

  /* local preview in a desktop browser: reader.html?dev=<json file> */
  var dev = /[?&]dev=([^&]+)/.exec(location.search);
  if (dev) {
    window.__jrDev = function (o) { if (o.t === 'pos') document.title = 'ch' + o.id + ' p' + o.p + ' · left ' + o.left + (o.pages ? ' · page ' + o.page + '/' + o.pages : ''); else console.log('JR', JSON.stringify(o)); };
    fetch(decodeURIComponent(dev[1])).then(function (r) { return r.json(); }).then(function (ch) { JR.load(ch, null); });
  }
  post({ t: 'ready' });
})();
