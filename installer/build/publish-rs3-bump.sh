#!/bin/bash
# publish-rs3-bump.sh — commit a rewritten pins.env to the branch, then tag and dispatch the build.
# Called by weekly-rs3-update.yml after check-rs3-update.sh --apply has rewritten pins.env.
#
# Env: TAG (v<ver>-1)  VERSION  GITHUB_REF_NAME (branch to push; default main)
#      GH_TOKEN for `gh workflow run`.
#
# The corrected pins are ALWAYS committed and pushed first, whether or not the tag exists. Issue #39:
# the old flow exited on an existing tag before `git commit`, so a bad tag (a bump whose build
# failed) discarded every corrected pins.env and could never self-heal.
#
# Then, if the tag does not exist, tag HEAD and dispatch. If it exists:
#   - its pins.env matches the working copy: re-dispatch the build on that tag;
#   - it differs: the tag points at stale pins and a re-dispatch would rebuild them. The corrected
#     pins are already on the branch, so fail loudly and name the move; the updater does not
#     force-move a tag that may already be published.
set -euo pipefail

PINS=installer/src/pins.env
BRANCH="${GITHUB_REF_NAME:-main}"
: "${TAG:?TAG is required}" "${VERSION:?VERSION is required}"

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if ! git diff --quiet -- "$PINS"; then
  git add "$PINS"
  git commit -m "chore(pins): bump RaceStudio 3 to $VERSION (auto)"
  git push origin "HEAD:${BRANCH}"
else
  echo "pins.env already matches the branch; nothing to commit."
fi

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" || true
  if git show "$TAG:$PINS" 2>/dev/null | cmp -s - "$PINS"; then
    echo "Tag $TAG already exists with matching pins - re-dispatching release build only."
    gh workflow run release-dmg.yml --ref "$TAG"
    exit 0
  fi
  echo "::error::Tag $TAG exists but its pins.env differs from the corrected pins now on $BRANCH." >&2
  echo "Re-dispatching would rebuild the stale pins. If no release was published for $TAG, move it:" >&2
  echo "  git tag -fa $TAG -m 'RaceStudio 3 $VERSION' origin/$BRANCH && git push -f origin $TAG" >&2
  exit 1
fi

git tag -a "$TAG" -m "RaceStudio 3 $VERSION (auto)"
git push origin "$TAG"
gh workflow run release-dmg.yml --ref "$TAG"
echo "Bumped to $VERSION, tagged $TAG, dispatched release-dmg."
