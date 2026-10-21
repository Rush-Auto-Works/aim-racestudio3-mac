#!/bin/bash
# unit-publish-bump.sh — publish-rs3-bump.sh commits corrected pins even when the tag exists.
# Regression test for issue #39: the old inline step exited before `git commit` on an existing tag,
# so a bad tag could never be corrected. Uses a local bare repo as origin and a stub `gh`.
_T_NAME="unit-publish-bump"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../build/publish-rs3-bump.sh"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3pub.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT
P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkdir "$SBX/bin"
printf '#!/bin/bash\necho "$*" >> "$GH_LOG"\n' > "$SBX/bin/gh"; chmod +x "$SBX/bin/gh"

# setup <name> <tag-pins|"">: origin main has pins V=1; an optional tag v9-1 carries <tag-pins> on a
# side branch; the working clone is on main with pins rewritten to V=2 (uncommitted), as after --apply.
setup() {
  local d="$SBX/$1"; mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/w" 2>/dev/null
  ( cd "$d/w" && git checkout -q -b main && mkdir -p installer/src && echo 'V=1' > installer/src/pins.env \
    && git add . && git commit -qm init && git push -q origin main
    if [ -n "$2" ]; then
      git checkout -q -b tagside && echo "$2" > installer/src/pins.env && git commit -qam tagged \
        && git tag -a v9-1 -m t && git push -q origin v9-1 && git checkout -q main
    fi
    echo 'V=2' > installer/src/pins.env )
}
run() { # <name>
  local d="$SBX/$1"; : > "$d/gh.log"
  ( cd "$d/w" && PATH="$SBX/bin:$PATH" GH_LOG="$d/gh.log" TAG=v9-1 VERSION=9 GITHUB_REF_NAME=main bash "$SCRIPT" ) >"$d/out" 2>&1
}
origin_pins() { git --git-dir="$SBX/$1/origin.git" show main:installer/src/pins.env; }

# A: no tag -> commit, push, tag, dispatch
setup a ""; run a; rc=$?
[ $rc -eq 0 ] && [ "$(origin_pins a)" = "V=2" ] && git --git-dir="$SBX/a/origin.git" rev-parse -q --verify refs/tags/v9-1 >/dev/null \
  && grep -q 'release-dmg.yml --ref v9-1' "$SBX/a/gh.log" && ok "no tag: pins pushed, tag created, build dispatched" || bad "no tag flow (rc=$rc)"

# B: tag exists with stale pins -> corrected pins still pushed, loud failure, no dispatch (#39)
setup b "V=0"; run b; rc=$?
[ "$(origin_pins b)" = "V=2" ] && ok "existing tag: corrected pins pushed to main" || bad "existing tag: pins NOT pushed ($(origin_pins b))"
[ $rc -ne 0 ] && ok "existing tag with stale pins fails loudly" || bad "existing stale tag exited 0"
[ ! -s "$SBX/b/gh.log" ] && ok "stale tag is not re-dispatched" || bad "stale tag was dispatched"

# C: tag exists and already matches -> nothing to commit beyond pins, re-dispatch only
setup c "V=2"; run c; rc=$?
[ $rc -eq 0 ] && grep -q 'release-dmg.yml --ref v9-1' "$SBX/c/gh.log" && ok "matching tag: re-dispatch only" || bad "matching tag flow (rc=$rc)"

echo "$_T_NAME: $P passed, $F failed"; [ "$F" -eq 0 ]
