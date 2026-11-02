"""Writes the test book: a small EPUB (title "The Test Book", by "Test
Author") with a cover image and three chapters - made here, the same every
time, rather than downloaded (public domain books' files change).

    python3 make_book.py <book.epub>
"""
import struct
import sys
import zipfile
import zlib


def png(width, height, colour):
    """
    A plain PNG image of one colour.

    :param int   width:  Its width, in pixels
    :param int   height: Its height, in pixels
    :param tuple colour: Its colour (red, green, blue)

    :return: The PNG file's bytes
    """

    def chunk(kind, data):
        """
        One of a PNG's chunks: its length, kind, data and checksum.

        :param bytes kind: The chunk's kind (e.g. b"IHDR")
        :param bytes data: Its data

        :return: The chunk's bytes
        """
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
        )

    row = b"\x00" + bytes(colour) * width

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(
            b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
        )
        + chunk(b"IDAT", zlib.compress(row * height, 9))
        + chunk(b"IEND", b"")
    )


def page(title, body):
    """
    An XHTML page of the book.

    :param str title: Its title
    :param str body:  Its body's HTML

    :return: The page
    """
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>%s</title>'
        "</head>"
        "<body>%s</body></html>\n" % (title, body)
    )


CHAPTERS = [
    (
        "Chapter %d" % n,
        "".join(
            "<p>Paragraph %d of chapter %d. It was a dark and stormy night,"
            " and the test book "
            "went on, at some length, about very little at all.</p>" % (p, n)
            for p in range(1, 31)
        ),
    )
    for n in range(1, 4)
]

FILES = {
    "META-INF/container.xml": '<?xml version="1.0"?>\n<container version='
    '"1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type='
    '"application/oebps-package+xml"/>'
    "</rootfiles></container>\n",
    "OEBPS/content.opf": '<?xml version="1.0" encoding="utf-8"?>\n<package'
    ' xmlns="http://www.idpf.org/2007/opf" version="2.0" '
    'unique-identifier="id"><metadata'
    ' xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:opf="http://www.idpf.org/2007/opf"><dc:title>The Test Book'
    "</dc:title>"
    '<dc:creator opf:role="aut">Test Author</dc:creator><dc:language>en'
    "</dc:language>"
    '<dc:identifier id="id">urn:uuid:7d3c2f8e-0b1a-4f6e-9c5d-2a8b4e6f1c30'
    "</dc:identifier>"
    '<meta name="cover" content="cover-image"/></metadata><manifest>'
    '<item id="cover-image" href="cover.png" media-type="image/png"/>'
    '<item id="cover" href="cover.xhtml" media-type='
    '"application/xhtml+xml"/>'
    + "".join(
        '<item id="c%d" href="chapter%d.xhtml" media-type='
        '"application/xhtml+xml"/>' % (n, n)
        for n in range(1, 4)
    )
    + '<item id="ncx" href="toc.ncx" media-type='
    '"application/x-dtbncx+xml"/></manifest><spine toc="ncx">'
    '<itemref idref="cover"/>'
    + "".join('<itemref idref="c%d"/>' % n for n in range(1, 4))
    + "</spine></package>\n",
    "OEBPS/toc.ncx": '<?xml version="1.0" encoding="utf-8"?>\n<ncx'
    ' xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
    '<head><meta name="dtb:uid"'
    ' content="urn:uuid:7d3c2f8e-0b1a-4f6e-9c5d-2a8b4e6f1c30"/></head>'
    "<docTitle><text>The Test Book</text></docTitle><navMap>"
    + "".join(
        '<navPoint id="n%d" playOrder="%d"><navLabel><text>Chapter %d'
        "</text></navLabel>"
        '<content src="chapter%d.xhtml"/></navPoint>' % (n, n, n, n)
        for n in range(1, 4)
    )
    + "</navMap></ncx>\n",
    "OEBPS/cover.xhtml": page(
        "Cover", '<div><img src="cover.png" alt="The Test Book"/></div>'
    ),
}
FILES.update({
    "OEBPS/chapter%d.xhtml" % n: page(title, "<h1>%s</h1>%s" % (title, body))
    for n, (title, body) in enumerate(CHAPTERS, 1)
})


def write(path):
    """
    Writes the book: the mimetype first and stored, as EPUB requires, and
    fixed dates, so the file is the same every time.

    :param str path: Where to write it
    """
    with zipfile.ZipFile(path, "w") as book:
        stamp = (2026, 1, 1, 0, 0, 0)
        book.writestr(
            zipfile.ZipInfo("mimetype", stamp),
            "application/epub+zip",
            zipfile.ZIP_STORED,
        )
        book.writestr(
            zipfile.ZipInfo("OEBPS/cover.png", stamp),
            png(300, 450, (122, 75, 42)),
            zipfile.ZIP_DEFLATED,
        )

        for name, text in FILES.items():
            book.writestr(
                zipfile.ZipInfo(name, stamp), text, zipfile.ZIP_DEFLATED
            )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    write(sys.argv[1])
