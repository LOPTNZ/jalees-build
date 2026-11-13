"""Builds tools/sim/sample.epub: a tiny Arabic EPUB 3 book (two sections, a table of contents, a picture),
used by the simulator check to test adding and reading EPUB files."""
import base64
import os
import zipfile

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "sample.epub")

# an 8x8 teal PNG
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGNk2CZ/hQEDMA42QwBDAgK4HD4Y/QAAAABJRU5ErkJggg=="
)

container = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

opf = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">jalees-sample</dc:identifier>
    <dc:title>كتاب تجريبي</dc:title>
    <dc:creator>جليس</dc:creator>
    <dc:language>ar</dc:language>
    <meta name="cover" content="cover"/>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="Text/two%20b.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="Images/cover.png" media-type="image/png" properties="cover-image"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>"""

nav = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>المحتويات</title></head>
<body><nav epub:type="toc"><ol>
<li><a href="Text/one.xhtml">البداية</a></li>
<li><a href="Text/two%20b.xhtml#x">الطريق إلى المكتبة</a></li>
</ol></nav></body></html>"""


def section(title, paras, img=False):
    body = "".join("<p>%s</p>" % p for p in paras)
    pic = '<div class="fig"><img src="../Images/cover.png" alt=""/></div>' if img else ""
    return ('<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>%s</title></head>'
            "<body><h1>%s</h1>%s%s</body></html>") % (title, title, body, pic)


one = section("البداية", ["كان المساء هادئًا حين فتح سالم الكتاب أول مرة.", "قرأ السطر الأول مرتين، ثم ابتسم: «هنا تبدأ الحكاية»."] * 6, img=True)
two = section("الطريق إلى المكتبة", ["مشى في الشارع القديم حتى وصل الباب الخشبي.", "<i>المكتبة لا تنام</i>، قال العجوز، «لكنها تحلم»."] * 6)

with zipfile.ZipFile(out, "w") as z:
    z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/Text/one.xhtml", one, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/Text/two b.xhtml", two, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/Images/cover.png", png, compress_type=zipfile.ZIP_STORED)
print(out, os.path.getsize(out))
