#!/usr/bin/env python3
"""Rename Wine's macOS app-menu title by patching the loader's embedded Info.plist.

winemac.drv runs unbundled (the GUI process image is lib/wine/<arch>-unix/wine),
so macOS/CFBundle takes the app's CFBundleName from the Mach-O __TEXT,__info_plist
section embedded in that loader — NOT from our outer RaceStudio 3.app/Info.plist.
Stock Wine ships CFBundleName="Wine", which is why the bold app menu (top-left)
reads "Wine". We patch that string to the desired name.

The __info_plist section is a fixed-size Mach-O section, so we cannot grow it.
We keep the byte count identical by stripping the plist's 4-space indentation
(insignificant XML whitespace) to make room for the longer name, then pad back to
the original section size with trailing newlines (ignored by CFBundle, which stops
parsing at </plist>).

Usage: patch-wine-appname.py <path-to-unix-loader> [app-name]
Default app name: "RaceStudio 3". Idempotent: re-running is a no-op if already set.
Re-sign the binary afterwards (this invalidates any existing code signature).
"""
import sys
import struct

LC_SEGMENT_64 = 0x19


def find_info_plist_section(data: bytes):
    """Return (file_offset, size) of the __TEXT,__info_plist section, or None."""
    if data[:4] not in (b"\xcf\xfa\xed\xfe",):  # MH_MAGIC_64 little-endian
        # Could be fat or big-endian; this loader is thin x86_64 LE in practice.
        raise SystemExit("unsupported Mach-O magic (expected thin 64-bit LE)")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32  # past mach_header_64
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            segname = data[off + 8:off + 24].rstrip(b"\x00")
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            soff = off + 72  # past segment_command_64 header
            for _ in range(nsects):
                sectname = data[soff:soff + 16].rstrip(b"\x00")
                if segname == b"__TEXT" and sectname == b"__info_plist":
                    secfileoff = struct.unpack_from("<I", data, soff + 48)[0]
                    secsize = struct.unpack_from("<Q", data, soff + 40)[0]
                    return secfileoff, secsize
                soff += 80  # sizeof(section_64)
        off += cmdsize
    return None


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: patch-wine-appname.py <unix-loader> [app-name]")
    path = sys.argv[1]
    name = sys.argv[2] if len(sys.argv) > 2 else "RaceStudio 3"

    data = bytearray(open(path, "rb").read())
    loc = find_info_plist_section(data)
    if not loc:
        raise SystemExit("no __TEXT,__info_plist section found")
    off, size = loc
    sec = bytes(data[off:off + size])

    new_name = name.encode("utf-8")
    target = b"<string>" + new_name + b"</string>"
    if target in sec:
        print(f"already patched to {name!r}; nothing to do")
        return

    # CFBundleName's value is the unique literal <string>Wine</string>
    # (NSPrincipalClass is "WineApplication", identifier is "org.winehq.wine").
    needle = b"<string>Wine</string>"
    count = sec.count(needle)
    if count != 1:
        raise SystemExit(f"expected exactly one {needle!r}, found {count}")

    patched = sec.replace(needle, target)
    # Reclaim the extra bytes by removing the 4-space XML indentation.
    patched = patched.replace(b"\n    ", b"\n")

    end = patched.find(b"</plist>")
    if end < 0:
        raise SystemExit("</plist> not found after patch")
    doc = patched[:end + len(b"</plist>")]
    if len(doc) > size:
        raise SystemExit(f"patched plist {len(doc)}B exceeds section {size}B")
    out = doc + b"\n" * (size - len(doc))
    assert len(out) == size

    data[off:off + size] = out
    open(path, "wb").write(data)
    print(f"patched CFBundleName -> {name!r} in {path} ({size}B section preserved)")


if __name__ == "__main__":
    main()
