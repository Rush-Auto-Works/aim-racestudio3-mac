---
name: update-racestudio3
description: Check AiM's download page for a newer RaceStudio 3 and release it as a notarized DMG. Use for "/update-racestudio3", "release the latest RS3", or when the weekly-rs3-update run left a tag with no release.
---

# update-racestudio3

Releases the newest AiM RaceStudio 3 through this repo's pipeline. The weekly workflow does steps 1 to 3 on its own; this skill does the same by hand and covers the cases where it stopped halfway.

Read `CLAUDE.md` (Conventions) and `codemaps/build-release.md` first. Tag format is `v<RS3 version>-<pkg rev>`, for example `v3.84.04-1`. The version spells the patch field the way AiM does, two digits (`3.84.04`, never `3.84.4`). `check-rs3-update.sh` builds it from the installer filename's vercode (`38404`) with `%02d`, and `unit-update-pins.sh` fails when `pins.env` disagrees with its own filename. Never type a version or tag by hand: copy `version=` and `tag=` from the script.

## 1. Find the latest version

Source of truth: https://www.aim-sportline.com/docs/racestudio3/html/release/download-release.html

```
bash installer/build/check-rs3-update.sh
```

It prints `pinned` and `latest` to stderr and `updated=true|false`. Quote the version from that output, and cross-check it against the page (the page, the pin and the tag all write `3.84.04`).

## 2. Work out where the release stands

Run each command on its own (`gh` and `git` only leave the sandbox as the whole command):

1. `gh release list --limit 5`
2. `git tag --sort=-v:refname | head -3`
3. `gh run list --workflow release-dmg.yml --limit 5`
4. `gh issue list --search "release-dmg failed" --state open`

| State | Action |
|---|---|
| Pin older than latest, no tag | `bash installer/build/check-rs3-update.sh --apply`, then PR the `pins.env` change (or dispatch `weekly-rs3-update.yml`, which commits, tags and builds) |
| Pin and tag exist, no release, last run failed | Read the failure (below), fix if real, re-run: `gh workflow run release-dmg.yml --ref <tag>` |
| Same RS3 version, installer changed | Bump `RS3_PKG_REV` in `installer/src/pins.env`, add the CHANGELOG entry, tag `v<ver>-<rev>` on main |
| Release already published for the latest | Report that and stop |

Read a failed run with `gh run view <id> --log-failed 2>&1 | grep -v '^$'` (needs `allowed_domains: ["results-receiver.actions.githubusercontent.com", "api.github.com", "github.com"]` in the sandbox). Known cause: `hdiutil convert failed - Resource temporarily unavailable` on the runner. The build script does not stop there, and notarytool then reports a missing DMG as a usage error. A re-run clears it.

## 3. CHANGELOG entry

The release notes come from the `## [<ver>-<rev>]` section of `CHANGELOG.md` at the tag. The auto flow tags before any entry exists, so the notes start as only the install line. Write the entry in the voice of the existing ones: say what AiM changed (summarize https://www.aim-sportline.com/docs/racestudio3/html/release/software-release.html for that version, read past the first page), say the installer, bridge and launcher are unchanged, and never claim a fix the installer did not make.

Land it with a PR (`chore(release): cut v<ver>-<rev> (RaceStudio 3 <ver>)`). When the tag was already built without it, refresh the notes after the build with the same awk the workflow uses, then `gh release edit <tag> --notes-file <file>`.

## 4. Watch the build

The `macos-14` run takes about 15 minutes (sign, notarize four apps, pkg, DMG). Monitor the run id until it completes.

## 5. Verify

1. `gh release view <tag> --json assets,isDraft,isPrerelease` shows a `.dmg` and a `.pkg`, not a draft, not a prerelease.
2. The release is marked Latest (`gh release list`).
3. Close the `release-dmg failed for <tag>` issue with the run URL as evidence.
