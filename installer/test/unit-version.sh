#!/bin/bash
# unit-version.sh — the version primitives. Four representations ship in this repo
# (pins.env "3.83.39", RaceStudio3.xmv "3.83.26.0", release tag "v3.83.39-1",
# CFBundleVersion "3.83.39.1") and a naive string compare gets every cross-pair wrong.
_T_NAME="unit-version"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/harness.sh"

FIX="$HERE/fixtures/RaceStudio3-3.83.26.xmv"
assert_file "$FIX"

# ---- ver_cmp -------------------------------------------------------------------------------
assert_eq "$(ver_cmp 3.83.26 3.83.39)" lt "older is lt"
assert_eq "$(ver_cmp 3.83.39 3.83.26)" gt "newer is gt"
assert_eq "$(ver_cmp 3.83.39 3.83.39)" eq "same is eq"
assert_eq "$(ver_cmp 3.84.0 3.83.39)"  gt "minor bump beats a big patch number"
assert_eq "$(ver_cmp 3.9.0 3.10.0)"    lt "numeric, not lexical, field compare"
# unequal field counts: the missing field is zero, not 'smaller'
assert_eq "$(ver_cmp 3.83.39 3.83.39.0)" eq "trailing .0 is eq"
assert_eq "$(ver_cmp 3.83.39.1 3.83.39)" gt "trailing .1 is gt"
# the two shapes build-apps.sh emits for the SAME build must compare equal
assert_eq "$(ver_cmp v3.83.39-1 3.83.39.1)" eq "release tag == CFBundleVersion"
assert_eq "$(ver_cmp v3.83.39-2 v3.83.39-1)" gt "pkg rev is a real field"
# leading zeros must not be read as octal
assert_eq "$(ver_cmp 3.83.08 3.83.7)" gt "leading zero compares base-10"
# garbage is refused, not guessed
assert_false "ver_cmp 3.83.x 3.83.39" "non-numeric field returns nonzero"
assert_eq "$(ver_cmp 3.83.x 3.83.39)" "" "non-numeric field prints nothing"
# Malformed input must be refused, not guessed at. Word splitting used to collapse an empty or
# whitespace field into a valid-looking one, so these all silently compared equal.
assert_false "ver_cmp 3..8 3.8"          "empty field is refused"
assert_eq "$(ver_cmp 3..8 3.8)" ""       "empty field prints nothing"
assert_false "ver_cmp '3.83. 8' 3.83.8"  "whitespace inside a field is refused"
assert_false "ver_cmp 3.83.39. 3.83.39"  "trailing separator is refused"
assert_false "ver_cmp 3.83 3.83"         "one-field-too-few is refused"
# An unbounded digit run overflows bash arithmetic and reverses the answer, so it is refused
# rather than compared.
assert_false "ver_cmp 999999999999999999999999999.0.0 1.0.0" "oversized field is refused"
assert_eq "$(ver_cmp 999999999999999999999999999.0.0 1.0.0)" "" "oversized field prints nothing"
# A wrong argument count must fail, not return a comparison against nothing.
assert_false "ver_cmp 3.83.39"           "one argument is refused"
assert_false "ver_cmp"                   "no arguments is refused"

# ---- rs3_installed_ver ---------------------------------------------------------------------
assert_eq "$(rs3_installed_ver "$FIX")" "3.83.26.0" "reads VERSION from the real manifest"

MISSING="$SANDBOX/nope.xmv"
assert_false "rs3_installed_ver '$MISSING'" "missing file returns nonzero"
assert_eq "$(rs3_installed_ver "$MISSING")" "" "missing file prints nothing"

NOTAG="$SANDBOX/notag.xmv"
printf '<?xml version="1.0"?>\r\n<info_version_sw>\r\n</info_version_sw>' > "$NOTAG"
assert_false "rs3_installed_ver '$NOTAG'" "manifest without a VERSION tag returns nonzero"
assert_eq "$(rs3_installed_ver "$NOTAG")" "" "tagless manifest prints nothing"

JUNK="$SANDBOX/junk.xmv"
printf '<p n="VERSION">not.a.version</p>\r\n' > "$JUNK"
assert_false "rs3_installed_ver '$JUNK'" "non-version value is refused"
assert_eq "$(rs3_installed_ver "$JUNK")"  "" "implausible value prints nothing"

OVER="$SANDBOX/over.xmv"
printf '<p n="VERSION">999999999999999999999999999.0.0</p>\r\n' > "$OVER"
assert_false "rs3_installed_ver '$OVER'" "oversized version is refused"

TRUNC="$SANDBOX/trunc.xmv"
printf '<p n="VERSION">3.83</p>\r\n' > "$TRUNC"
assert_false "rs3_installed_ver '$TRUNC'" "two-field value is refused (needs 3 or 4)"

THREE="$SANDBOX/three.xmv"
printf '<p n="VERSION">3.83.26</p>\r\n' > "$THREE"
assert_eq "$(rs3_installed_ver "$THREE")" "3.83.26" "three-field value is accepted"

# ---- rs3_installed_at_least (reads $PREFIX/drive_c/$RS3_REL_XMV) ----------------------------
mkdir -p "$PREFIX/drive_c/$(dirname "$RS3_REL_XMV")"
assert_false "rs3_installed_at_least" "no argument is refused"
assert_false "rs3_installed_at_least 3.83.39" "unknown install is NOT satisfied"

ditto "$FIX" "$PREFIX/drive_c/$RS3_REL_XMV"
assert_false "rs3_installed_at_least 3.83.39" "3.83.26.0 installed vs 3.83.39 wanted: not satisfied"
assert_true  "rs3_installed_at_least 3.83.26" "equal version is satisfied"
assert_true  "rs3_installed_at_least 3.82.0"  "newer than wanted is satisfied (never downgrade)"

finish
