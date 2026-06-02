# Build prompt — Free-Wine RaceStudio 3 installer (paste after /clear)

Copy everything in the box into a fresh Claude Code session **on this Mac**, in the repo
`~/git/rush/aim-racestudio3-mac`.

---

```
Build the free-Wine one-click installer for AiM RaceStudio 3 on macOS, per the two plan
documents in this repo. Work on this Mac (Apple Silicon, macOS 26). Repo:
~/git/rush/aim-racestudio3-mac  (public: github.com/Rush-Auto-Works/aim-racestudio3-mac).

FIRST, read these in full — they are the spec and already incorporate a 5-reviewer design
debate (do not re-litigate; implement them):
  - docs/installer-design.md          (design v2, post-review)
  - docs/installer-implementation.md  (concrete build plan, file layout, function contracts)
Also skim docs/free-wine.md and docs/old-crossover-workarounds.md for context, and
scripts/port-data-from-parallels.sh (the installer reuses it for optional data import).

NON-NEGOTIABLE NORTH STAR: the audience is NON-TECHNICAL racers. Ease is everything. The
deliverable is a **codesigned + notarized + stapled AppleScript-applet .app** (the user has an
Apple Developer account) — double-click, NO Gatekeeper prompt, native macOS dialogs + staged
progress, NO scary Terminal. The applet is the parent and runs the bash engine via
`do shell script` (hidden). Never lose user data. (Keep an unsigned .command in-repo as a
source-available fallback only.)

The docs already encode a 3-round reviewer debate. Two areas got the most scrutiny — implement
them EXACTLY as written, do not simplify:
- `data_relocate_safe()` is specified as an explicit, crash-atomic, resumable STATE MACHINE in
  the implementation doc (DST made complete via copy-if-absent MERGE and verified BEFORE SRC is
  touched; symlink swapped via atomic rename; only disposable defaults ever deleted; full resume
  ladder). Build it verbatim — this is the #1 data-loss surface.
- Success = exe exists + valid header + silent-install OK. Do NOT live-launch RS3 to "test" it
  (CEF takes 10-30s under Rosetta -> false-fail + can corrupt the now-symlinked data).

VERIFIED FACTS (proven already this session — rely on them, don't re-derive):
- RaceStudio 3 is x86-64; needs Rosetta 2 on Apple Silicon. App is native + CEF (not .NET).
- Rendering is clean on Wine >=10, garbled on <=8. D3DMetal is irrelevant.
- Pinned, VERIFIED Wine: Gcenx wine-staging-11.9-osx64.tar.xz
  (github.com/Gcenx/macOS_Wine_builds/releases). Tarball -> "Wine Staging.app"; the binary is
  .../Contents/Resources/wine/bin/wine (it's `wine`, not `wine64`, on Wine 11 — but GLOB for
  it, don't hardcode; the path has changed across versions).
- The AiM installer runs FULLY SILENT on Wine 11 (verified end-to-end):
  `wine "RaceStudio3-64_<ver>.exe" /exenoui /qn` -> complete install to
  C:\AIM_SPORT\RaceStudio3 (main exe 64\AiMRS3-64-ReleaseU.exe, ~785 MB), Start Menu shortcut
  created, no crash, no clicks. Pinned verified RS3 = 3.83.20
  (RaceStudio3-64_38320_000000_000000_20260528_145224.exe, 345795344 bytes; AiM page:
  aim-sportline.com/docs/racestudio3/html/release/download-release.html).
- A working reference Wine-11 prefix already exists at ~/.rs3-w11-test (RS3 installed there
  silently) and the extracted tarball at /tmp/claude/wine11 — use them to sanity-check, but the
  installer must set everything up fresh and self-contained.
- RS3 user data lives at C:\AIM_SPORT\RaceStudio3\user\ (configs .zconfig, profiles, the big
  track database, sessions under data/). In RS3 file dialogs, the Mac FS is drive Z:
  (Z:\Users\<name>\).

LAYOUT (native): launcher ~/Applications/RaceStudio 3.app ; engine+prefix+logs+state in
~/Library/Application Support/RaceStudio3/ ; user data in ~/Documents/AIM_SPORT/ (iCloud-aware —
see design §Data Safety). Uninstall via ~/Applications/Uninstall RaceStudio 3.app.

HARD REQUIREMENTS the reviewers insisted on (all in the design doc — implement every one):
- PIN the verified Wine + RS3 versions as defaults; `--latest` is opt-in and flagged unverified.
- NO blanket `set -e` around Wine (it returns nonzero for diagnostics); per-call postcondition
  checks; watchdog for timeouts (macOS has no `timeout`).
- macOS-native tools only: no jq/gh/Homebrew/GNU; parse JSON with /usr/bin/python3 or plutil.
- Success = main exe exists AND launches — NOT the Start Menu shortcut.
- Downloads: HTTPS-only, *.partial -> size-verify -> atomic mv; fall back on ANY non-200 (GitHub
  403 rate-limit). Validate scraped version/asset strings against strict regexes (don't just
  quote — constrain); array argv, never built command strings, no eval.
- Rosetta: admin osascript install; handle Cancel / standard-user / failure / Intel with clear
  hard-stops before any Wine call.
- DATA SAFETY (the #1 risk): ~/Documents/AIM_SPORT often ALREADY has the migrating user's real
  telemetry. NEVER clobber. Treat existing as authoritative / back up aside; relocate
  copy->verify->symlink->delete (crash-atomic, resumable); detect iCloud Desktop&Documents sync
  and warn/offer a non-synced location; handle the TCC "Wine wants to access Documents" prompt.
- Real per-step ledger in .../state/ (postcondition checks), `--repair`, `--reinstall`
  (never deletes Documents data without explicit confirm), and `--dry-run` (no net/no writes, CI-able).
- WINEDLLOVERRIDES="mscoree=d;mshtml=d" + WINEARCH=win64 so wineboot doesn't hang on Mono/Gecko.
- Launcher/uninstaller: absolute paths (a .app's CWD isn't its dir), export WINEPREFIX so no
  ~/.wine is ever created, run RS3 detached, don't self-delete mid-run.

BUILD ORDER (prove the engine before the GUI):
1. Implement installer/src/installer-core.sh + lib/ with --dry-run and all robustness. Get
   `installer-core.sh --dry-run` green (no network, no stray writes).
2. Run the core end-to-end on a CLEAN setup (real Wine download + silent RS3 install + relocate);
   confirm RS3 launches and renders clean and reads data from ~/Documents/AIM_SPORT.
3. Test the dangerous paths BEFORE any GUI: migrating-user data preserved; interrupt mid-download
   / mid-prefix / mid-relocation -> resume with NO data loss; uninstall; no-network/403/truncated/
   Rosetta-cancel.
4. Build the AppleScript applets (Install/Uninstall .app) + the launcher .app + an
   **Import RaceStudio 3 Data.app droplet** (`on open` accepts a dragged AIM_SPORT/user folder,
   a .zip, or loose .xrk; merges via the SAME copy-if-absent engine as data_relocate_safe — never
   overwrite). Also wire the installer's optional import step (auto-from-Parallels via
   scripts/port-data-from-parallels.sh + a "choose folder" picker). Codesign + notarize + staple
   every .app. Native dialogs + staged progress; the heavy logic stays in the tested core script.
5. Update README with a "Free, no-CrossOver install" section: download -> right-click->Open
   (one-time Gatekeeper), then double-click; plus the USB-no/WiFi-yes and iCloud caveats.

Use TodoWrite to track the phases. Test each phase before moving on (the design/impl docs have
the test plan). Commit per phase with conventional-commit messages; push to the existing repo.
Before claiming a phase works, SHOW the evidence (command output), per verification discipline.
When you hit the Gatekeeper/quarantine reality or the iCloud decision, follow the design doc's
resolution — don't invent a new approach.

Start by reading the two plan docs and the reuse script, then give me a short phase-1 plan and
begin.
```

---

That's the whole prompt. It is self-contained: the plan docs carry the design + the reviewer-
hardened requirements, and the verified facts are inline so a fresh session needs no prior context.
