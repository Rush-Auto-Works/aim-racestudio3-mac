#!/bin/bash
# unit-patch-wine.sh — patch-wine-appname.py: CFBundleName rename + NSLocalNetworkUsageDescription
# injection into the Wine unix-loader's fixed-size __TEXT,__info_plist section.
#
# Hermetic: synthesizes a tiny thin x86_64 Mach-O carrying a wine-like __info_plist (no real Wine
# binary needed), so it runs in CI on any host with python3.
_T_NAME="unit-patch-wine"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/harness.sh"

PATCHER="$(cd "$HERE/../build" && pwd)/patch-wine-appname.py"
assert_file "$PATCHER"

# Build a fake thin Mach-O at $1 whose __TEXT,__info_plist section is exactly $2 bytes.
build_fixture() { # <out> <secsize>
  python3 - "$1" "$2" <<'PY'
import sys, struct
out, secsize = sys.argv[1], int(sys.argv[2])
plist = (b'<?xml version="1.0" encoding="UTF-8"?>\n'
         b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
         b'<plist version="1.0">\n<dict>\n'
         b'    <key>CFBundleExecutable</key>\n    <string>wine</string>\n'
         b'    <key>CFBundleIdentifier</key>\n    <string>org.winehq.wine</string>\n'
         b'    <key>CFBundleName</key>\n    <string>Wine</string>\n'
         b'    <key>LSUIElement</key>\n    <string>1</string>\n'
         b'</dict>\n</plist>')
if len(plist) > secsize:
    sys.exit("fixture plist (%d) larger than secsize (%d)" % (len(plist), secsize))
secdata = plist + b'\n' * (secsize - len(plist))
SECOFF = 184  # 32 (mach_header_64) + 152 (one LC_SEGMENT_64 + one section_64)
hdr = struct.pack("<IiiIIIII", 0xfeedfacf, 0x01000007, 3, 2, 1, 152, 0, 0)
seg = struct.pack("<II16sQQQQiiII", 0x19, 152, b"__TEXT", 0, 0, 0, 0, 7, 5, 1, 0)
sect = struct.pack("<16s16sQQIIIIIIII", b"__info_plist", b"__TEXT", 0, secsize, SECOFF,
                   0, 0, 0, 0, 0, 0, 0)
blob = hdr + seg + sect
assert len(blob) == SECOFF, len(blob)
open(out, "wb").write(blob + secdata)
PY
}

# Print the embedded __info_plist doc (up to </plist>) of the Mach-O at $1.
read_plist() { # <bin>
  python3 - "$1" <<'PY'
import sys, struct
data = open(sys.argv[1], "rb").read()
ncmds = struct.unpack_from("<I", data, 16)[0]; o = 32
for _ in range(ncmds):
    cmd, cs = struct.unpack_from("<II", data, o)
    if cmd == 0x19:
        seg = data[o+8:o+24].rstrip(b"\0"); ns = struct.unpack_from("<I", data, o+64)[0]; so = o+72
        for _ in range(ns):
            if seg == b"__TEXT" and data[so:so+16].rstrip(b"\0") == b"__info_plist":
                foff = struct.unpack_from("<I", data, so+48)[0]; sz = struct.unpack_from("<Q", data, so+40)[0]
                sec = data[foff:foff+sz]; sys.stdout.buffer.write(sec[:sec.find(b"</plist>")+8]); sys.exit()
            so += 80
    o += cs
PY
}

# ---- happy path: rename + inject, section size preserved -----------------------------------
FIX="$SANDBOX/wine-ok"
build_fixture "$FIX" 936
size_before="$(stat -f%z "$FIX")"
out1="$(python3 "$PATCHER" "$FIX" 2>&1)"; rc1=$?
size_after="$(stat -f%z "$FIX")"
assert_eq "$rc1" "0" "patcher exits 0 on a roomy section"
assert_eq "$size_before" "$size_after" "file/section byte count preserved"

doc="$(read_plist "$FIX")"
assert_true "printf '%s' \"\$doc\" | grep -q '<string>RaceStudio 3</string>'" "CFBundleName -> RaceStudio 3"
assert_true "printf '%s' \"\$doc\" | grep -q 'NSLocalNetworkUsageDescription'"   "NSLocalNetworkUsageDescription key present"
assert_true "printf '%s' \"\$doc\" | grep -q 'over Wi-Fi'"                       "usage string value injected"
assert_true "printf '%s' \"\$doc\" | grep -q '<string>org.winehq.wine</string>'" "other keys (CFBundleIdentifier) preserved"
assert_true "printf '%s' \"\$doc\" | grep -q '<string>1</string>'"               "LSUIElement preserved"

# ---- idempotency: a second run is a no-op --------------------------------------------------
out2="$(python3 "$PATCHER" "$FIX" 2>&1)"; rc2=$?
assert_eq "$rc2" "0" "second run exits 0"
assert_true "printf '%s' \"\$out2\" | grep -qi 'nothing to do'" "second run is idempotent (no-op)"

# ---- overflow guard: a section with no room must fail loudly, not corrupt ------------------
# Size the section to the RAW (indented) plist: it holds the fixture, but after the patcher
# compacts whitespace and adds the ~95B usage key the result no longer fits -> must raise.
TIGHT="$(python3 - <<'PY'
plist = (b'<?xml version="1.0" encoding="UTF-8"?>\n'
         b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
         b'<plist version="1.0">\n<dict>\n'
         b'    <key>CFBundleExecutable</key>\n    <string>wine</string>\n'
         b'    <key>CFBundleIdentifier</key>\n    <string>org.winehq.wine</string>\n'
         b'    <key>CFBundleName</key>\n    <string>Wine</string>\n'
         b'    <key>LSUIElement</key>\n    <string>1</string>\n'
         b'</dict>\n</plist>')
print(len(plist))
PY
)"
FIX2="$SANDBOX/wine-tight"
build_fixture "$FIX2" "$TIGHT"
before2="$(stat -f%z "$FIX2")"
out3="$(python3 "$PATCHER" "$FIX2" 2>&1)"; rc3=$?
after2="$(stat -f%z "$FIX2")"
assert_false "[ $rc3 -eq 0 ]" "patcher fails (nonzero) when the key cannot fit"
assert_true  "printf '%s' \"\$out3\" | grep -q 'exceeds section'" "overflow error message names the cause"
assert_eq "$before2" "$after2" "failed patch leaves the binary byte count unchanged"

finish