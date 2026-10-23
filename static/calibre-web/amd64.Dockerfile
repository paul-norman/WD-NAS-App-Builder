# Calibre-Web's build: Debian Bookworm, whose glibc (2.36) and libraries are bundled with the app as its own runtime -
# the NAS's glibc (2.31) is too old for Calibre 9's converter. The build script patches every program it prepares to use
# that runtime (see build.sh)
FROM debian:bookworm

ENV LANG=C.UTF-8

# The tools (clang: the portable Python builds packages without a ready-made wheel with it), the libraries Calibre and the Python packages expect from a system (copied into the runtime), ImageMagick
# (covers, through Python's Wand), libmagic (file types) and Ghostscript (covers of PDFs, for ImageMagick)
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy --no-install-recommends \
	binutils ca-certificates clang file gcc libc6-dev patchelf wget xz-utils \
	libstdc++6 libgcc-s1 libfontconfig1 libfreetype6 libnss3 libnspr4 libmount1 libuuid1 libpcre2-8-0 \
	libegl1 libopengl0 libglx0 libx11-6 libx11-xcb1 libxext6 libxrandr2 libxkbcommon0 libxkbcommon-x11-0 libdrm2 libasound2 \
	libice6 libsm6 libinput10 libmtdev1 libudev1 libwayland-client0 libwayland-cursor0 libwayland-egl1 libxcb-cursor0 \
	libxcb-glx0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-render0 libxcb-shape0 \
	libxcb-shm0 libxcb-sync1 libxcb-xfixes0 libxcb-xkb1 libxcb1 libncursesw6 \
	libmagickwand-6.q16-6 libmagic1 libmagic-mgc ghostscript && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
