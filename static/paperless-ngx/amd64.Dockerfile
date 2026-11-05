# Paperless-ngx's build: Debian Trixie (as Paperless's own image), whose glibc (2.41) and libraries are bundled with the
# app as its own runtime - the NAS's glibc (2.31) is too old for the OCR tools and some Python packages. The build script
# patches every program it prepares to use that runtime (see build.sh)
FROM debian:trixie

ENV LANG=C.UTF-8

# The tools (clang: the portable Python builds packages without a ready-made wheel with it), and what Paperless's own
# image installs for documents: OCR (Tesseract with English and German, OCRmyPDF's helpers unpaper, pngquant, qpdf,
# Ghostscript - unpaper is built by build.sh), poppler (PDF pages as images, their text), libmagic (file types), fonts
# for text files' thumbnails
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy --no-install-recommends \
	binutils ca-certificates clang file gcc libc6-dev make patchelf wget xz-utils \
	tesseract-ocr tesseract-ocr-eng tesseract-ocr-deu tesseract-ocr-osd pkgconf pngquant qpdf ghostscript \
	icc-profiles-free jbig2dec poppler-utils libmagic1 libmagic-mgc fonts-liberation libxml2 libxslt1.1 zlib1g zlib1g-dev && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
