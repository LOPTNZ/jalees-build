# Site definitions (one file per site)

Each file registers one site: `Sources.<id> = { … }`. It runs inside a hidden web view in the app (and in any
desktop browser). The app downloads every page itself (plain HTTPS GET with an iPhone Safari user agent, no cookies,
no JavaScript run) and hands the text to the definition, parsed with `DOMParser` as `text/html`. A JSON answer can be
read with `JSON.parse(doc.body ? doc.body.textContent : html)`; many Next.js/Nuxt sites carry their data in
`<script id="__NEXT_DATA__">` or similar JSON inside the HTML.

Helpers: `SourceKit.txt(el)`, `abs(href, base)`, `meta(doc, name)`, `digits(s)` (Arabic-Indic digits to Western, digits
only), `paragraphs(box, skipSelector)` (leaf blocks in reading order, skipping hidden or injected ones), `tidy(paras,
rules, edge)` (drops site chatter matching `rules` from the first 3 and last `edge` lines; returns `{paras, removed}`).

```js
Sources.mysite = {
  id: 'mysite', name: 'اسم الموقع كما يكتبه', home: 'https://…/', lang: 'ar' /* or 'en' */,
  hosts: ['mysite.com', 'www.mysite.com'],
  isSeries: function (url) { return true when url is a novel's page (not a chapter) },
  seriesUrl: function (doc, url) { from a CHAPTER page, the novel's page address },
  clean: [ /regexes for site chatter at a chapter's start or end/ ],
  series: function (doc, url) {
    return { title, author, cover /* absolute URL */, summary, status /* site's words, e.g. مستمرة / مكتملة */,
             total /* chapter count if shown */, translator, genres: [..],
             listPages: [ every URL that lists chapters, page 1 first; [] if all on the novel page ],
             rows: this.list(doc, url) /* chapters on THIS page */ };
  },
  list: function (doc, url) { return [{ url, num /* '691' */, title /* without the number */, volume, date }] NEWEST FIRST },
  chapter: function (doc, url) { return { title, paras: [..plain text paragraphs..], removed, next, prev } },
  browseURL: function (kind /* 'latest' | 'popular' | 'search' */, page, q) { return a URL },
  browse: function (doc, url) { return { items: [{ url /* novel page */, title, cover, meta }], next: bool } }
};
```

Rules: `list` returns the newest chapter first (the app reverses). `listPages[0]` is the page already read (the app
fetches the rest). Chapter `paras` hold no HTML, no site ads, no hidden decoy paragraphs. Images inside a chapter go
as `'￼img:' + absoluteURL`. Never throw: return `{ error: '…' }` when the page is not what was expected.

**Fetch steps.** When a chapter's text needs more than its page (a POST, or a second address the page names),
`chapter` may answer `{ fetch: { url, method /* 'GET' (default) or 'POST' */, json /* POST body, sent as JSON */,
headers } }`. The app fetches that and calls `chapter(doc, url)` again with the answer (`url` stays the chapter's
address), up to three times.

