#!/usr/bin/env python3
"""Patch Wine's macOS loader Info.plist: app-menu title AND Local Network usage.

winemac.drv runs unbundled (the GUI process image is lib/wine/<arch>-unix/wine),
so macOS/CFBundle takes the app's CFBundleName from the Mach-O __TEXT,__info_plist
section embedded in that loader — NOT from our outer RaceStudio 3.app/Info.plist.
Stock Wine ships CFBundleName="Wine", which is why the bold app menu (top-left)
reads "Wine". We patch that string to the desired name.

That SAME loader is the process that opens RS3's device-discovery UDP socket, so on
macOS 15+/26 it is the executable TCC evaluates for the Local Network privacy grant.
TCC keys on the accessing executable's embedded Info.plist + code signature; without
an NSLocalNetworkUsageDescription bound to THIS binary, macOS denies the access
silently — no prompt, no entry under Settings > Privacy > Local Network — and AiM
devices never appear in RS3 (cf. claude-code#27828, same root cause for a bare
Mach-O). The outer app bundle's plist string doesn't help: the applet isn't the
process opening the socket. So we inject the usage string here and re-sign.

The __info_plist section is a fixed-size Mach-O section, so we cannot grow it. We
reclaim room by collapsing the plist's insignificant inter-tag whitespace, then pad
back to the original section size with trailing newlines (ignored by CFBundle, which
stops parsing at </plist>).

Usage: patch-wine-appname.py <path-to-unix-loader> [app-name]
Default app name: "RaceStudio 3". Idempotent: re-running is a no-op if already set.
Re-sign the binary afterwards (this invalidates any existing code signature).
"""
import re
import sys
import struct
from xml.sax.saxutils import escape

LC_SEGMENT_64 = 0x19

# Why this binary and not the outer .app: the unix loader is the process that opens
# the discovery UDP socket, so it is the executable TCC attributes Local Network to.
LOCALNET_KEY = b"NSLocalNetworkUsageDescription"
LOCALNET_MSG = b"Connects to your AiM logger or dash over Wi-Fi."


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

    # Escape XML metacharacters so a name with & or < keeps the embedded plist well-formed.
    # Escaping first also makes the idempotency check below compare against the stored (escaped) value.
    new_name = escape(name).encode("utf-8")

    def cur_val(key):
        m = re.search(rb"<key>" + re.escape(key) + rb"</key>\s*<string>([^<]*)</string>", sec)
        return m.group(1) if m else None

    # Patch ONLY CFBundleName (drives the macOS menu-bar app name). Do NOT touch CFBundleExecutable:
    # it doesn't change the Dock/process name (macOS uses the real on-disk loader filename "wine"),
    # AND a mismatch breaks LaunchServices icon resolution (blank Dock icon). Verified 2026-06-02.
    has_localnet = cur_val(LOCALNET_KEY) == LOCALNET_MSG
    if cur_val(b"CFBundleName") == new_name and has_localnet:
        print(f"already patched ({name!r} + Local Network usage); nothing to do")
        return

    # 1) CFBundleName -> the desired app-menu name.
    pat = re.compile(rb"(<key>CFBundleName</key>\s*<string>)[^<]*(</string>)")
    patched, n = pat.subn(rb"\g<1>" + new_name + rb"\g<2>", sec)
    if n != 1:
        raise SystemExit(f"expected exactly one CFBundleName key/value, found {n}")

    # 2) Inject NSLocalNetworkUsageDescription before </dict> if absent, so the unix
    #    loader (the process that opens the discovery socket) declares the capability.
    if not has_localnet:
        entry = (b"<key>" + LOCALNET_KEY + b"</key><string>"
                 + escape(LOCALNET_MSG.decode()).encode() + b"</string>")
        patched, n = re.subn(rb"</dict>", entry + b"</dict>", patched, count=1)
        if n != 1:
            raise SystemExit("expected exactly one </dict> to insert before")

    # 3) Reclaim bytes: collapse insignificant inter-tag whitespace (the fixed-size
    #    section can't grow). Safe for plist XML; values keep their inner whitespace
    #    because that sits between letters, not between '>' and '<'.
    patched = re.sub(rb">\s+<", b"><", patched)

    end = patched.find(b"</plist>")
    if end < 0:
        raise SystemExit("</plist> not found after patch")
    doc = patched[:end + len(b"</plist>")]
    if len(doc) > size:
        raise SystemExit(f"patched plist {len(doc)}B exceeds section {size}B "
                         f"(shorten LOCALNET_MSG by {len(doc) - size}B)")
    out = doc + b"\n" * (size - len(doc))
    assert len(out) == size

    data[off:off + size] = out
    open(path, "wb").write(data)
    print(f"patched CFBundleName -> {name!r} + Local Network usage in {path} "
          f"({len(doc)}/{size}B used)")


if __name__ == "__main__":
    main()
