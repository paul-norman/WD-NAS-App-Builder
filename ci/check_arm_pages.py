#!/usr/bin/env python3
"""
Checks that ARM programs and libraries can be loaded on the ARM models, whose
kernels use large memory pages (32KB on the My Cloud EX2 Ultra, for one): each
loadable segment's address and file offset must be congruent modulo the page
size, and code mustn't share a page with a segment of other permissions.
Programs linked for 4KB pages (as Debian's and Alpine's ARM packages are) crash
there ("Segmentation fault"), or their libraries fail to load. Zig's and Go's
own output is laid out for 64KB pages, which suits every page size up to 64KB.

    python3 ci/check_arm_pages.py <file or folder> [...]

Checks every 32-bit ARM ELF file found (others are skipped) and prints each
one that breaks the rules, with why. Exits 1 if any does, else 0.
"""

import os
import struct
import sys

PAGE = 65536
PT_LOAD = 1
EM_ARM = 40


def segments(path):
    """
    A 32-bit ARM ELF file's loadable segments.

    :param str path: The file

    :return: (offset, address, file size, memory size, flags) for each, or
             None if it isn't a 32-bit little-endian ARM ELF file
    """
    with open(path, "rb") as handle:
        header = handle.read(52)

        if len(header) < 52 or header[:4] != b"\x7fELF" or header[4] != 1:
            return None

        if header[5] != 1 or struct.unpack_from("<H", header, 18)[0] != EM_ARM:
            return None

        phoff = struct.unpack_from("<I", header, 28)[0]
        phentsize, phnum = struct.unpack_from("<HH", header, 42)
        found = []

        for index in range(phnum):
            handle.seek(phoff + index * phentsize)
            entry = handle.read(32)
            kind, offset, vaddr, _, filesz, memsz, flags = struct.unpack_from(
                "<IIIIIII", entry
            )

            if kind == PT_LOAD:
                found.append((offset, vaddr, filesz, memsz, flags))

    return found


def problems(path):
    """
    What stops a file loading on a kernel with large pages.

    :param str path: The file

    :return: The problems (none if it's fine, or not an ARM ELF file)
    """
    loads = segments(path)

    if not loads:
        return []

    found = []
    pages = []

    for offset, vaddr, filesz, memsz, flags in loads:
        if (vaddr - offset) % PAGE:
            found.append(
                f"segment at 0x{vaddr:x} (file offset 0x{offset:x}) isn't"
                f" aligned to {PAGE // 1024}KB pages"
            )

        last = (vaddr + max(memsz, 1) - 1) // PAGE
        pages.append((vaddr // PAGE, last, flags & 7))

    # Two segments in one page get the same permissions there: fine for data
    # beside data, not for code beside data
    for (_, last, flags), (next_first, _, next_flags) in zip(pages, pages[1:]):
        mixed = flags != next_flags and (flags | next_flags) & 1

        if next_first <= last and mixed:
            found.append(
                f"code shares the {PAGE // 1024}KB page at"
                f" 0x{next_first * PAGE:x} with a segment of other permissions"
            )

    return found


def files(paths):
    """
    The regular files under the paths given (not following links).

    :param list paths: Files or folders

    :return: Their paths
    """
    for path in paths:
        if os.path.isfile(path) and not os.path.islink(path):
            yield path
        elif os.path.isdir(path):
            for root, _, names in os.walk(path):
                for name in sorted(names):
                    full = os.path.join(root, name)

                    if os.path.isfile(full) and not os.path.islink(full):
                        yield full


def main():
    """
    Checks the files given, printing each that breaks the rules.

    :return: The exit status
    """
    if len(sys.argv) < 2:
        print(__doc__.strip())

        return 2

    bad = 0
    checked = 0

    for path in files(sys.argv[1:]):
        if segments(path) is None:
            continue

        checked += 1
        found = problems(path)

        if found:
            bad += 1
            print(f"{path}: {'; '.join(found)}")

    print(f"{checked} ARM files checked, {bad} won't load with large pages")

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
