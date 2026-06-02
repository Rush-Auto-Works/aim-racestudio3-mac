# Old CrossOver / old Wine workarounds (you probably don't need these)

**If you can update CrossOver to 24+ (26+ ideal), do that and skip this entire page.**
On Wine 10 the official RaceStudio 3 installer just works and the UI renders cleanly.
Everything below is the archaeology of getting it working on **CrossOver 23.7.1 (Wine 8)**,
kept for people who genuinely can't update, and as a reference for the failure modes.

The RaceStudio 3 installer is an **Advanced Installer (Caphyon) self-extractor** wrapping
an **MSI**, with a Chromium-based **Enhanced UI**. The app itself is native + CEF
(`libcef.dll`), not .NET — but the *installer* needs .NET. On old Wine, four separate
things break.

## 1. Installer needs real .NET Framework 4.8 (Wine Mono isn't enough)
Symptom: installer dies instantly with `Unhandled exception 0xe06d7363` (a Microsoft
C++/.NET exception). Wine Mono can't host the installer's CLR.

Install real .NET 4.8 with winetricks — but see the shim below, because winetricks does
not get along with CrossOver's wrapper `wine`.

## 2. winetricks vs CrossOver's wrapper `wine` — the `cxwine` shim
CrossOver's `$CX/bin/wine` is a wrapper that (a) **ignores `WINEPREFIX`** (it targets a
bottle via `--bottle`/`CX_BOTTLE`), so winetricks' `wine cmd /c echo %AppData%` returns
empty and winetricks aborts; and (b) **doesn't resolve a relative exe path** against the
Unix cwd, so `cd cache && wine installer.exe` fails with `cannot execute`.

Fix — a shim used as `$WINE` that injects `--bottle` and absolutizes file args:

```sh
cat > /tmp/cxwine <<'EOF'
#!/bin/sh
CXWINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
newargs=""
for a in "$@"; do
  case "$a" in /*) ;; *) [ -e "$a" ] && a="$PWD/$a";; esac
  newargs="$newargs
$a"
done
IFS='
'; set -f; set -- $newargs; set +f
exec "$CXWINE" --bottle RaceStudio3 "$@"
EOF
chmod +x /tmp/cxwine; cp /tmp/cxwine /tmp/cxwine64
```

Then point winetricks at it. The chained `dotnet48` verb still dies at its `wineserver -w`
barrier under CrossOver, so install 4.0 via the verb, then run the **4.8 (`ndp48`)
installer directly** in **win7 mode** (Win10 mode makes ndp48 think it's already part of
the OS and skip):

```sh
export WINE=/tmp/cxwine WINE64=/tmp/cxwine64 WINESERVER="$CX/bin/wineserver"
export WINEPREFIX="$HOME/Library/Application Support/CrossOver/Bottles/RaceStudio3"
export PATH="$CX/bin:$PATH"
/tmp/cxwine winecfg -v win7
$CX/bin/cxstart --bottle RaceStudio3 -- \
  "$HOME/.cache/winetricks/dotnet48/ndp48-x86-x64-allos-enu.exe" /q /norestart
```
Verify: registry `NDP\v4\Full` gets a `Release` dword (`0x80eb1` = 528049 = .NET 4.8).

## 3. Enhanced UI crashes → install with `/exenoui`
Even with .NET, the Advanced Installer **Enhanced UI** (a separate modern UI process)
crashes on old Wine (`0xe06d7363`). Bypass it: run the installer with `/exenoui /qn`,
which hands the embedded MSI straight to `msiexec`.

## 4. The MSI's deferred file-copy hangs → extract & deploy manually
The killer: under Wine 8 the MSI's elevated `msiexec` server stalls at 0% CPU at the
deferred file-copy (right after an Advanced Installer custom action,
`AI_DETECT_WINTHEME`, which itself hangs unless you're in **win7 mode** so its
`VersionNT >= 603` condition is false). The app files never get copied.

But the bootstrapper *does* extract the full, self-contained app tree to
**`C:\AIM_SPORT\RaceStudio3\`** (~785 MB) before the copy hangs. Since the app is
xcopy-deployable, just take that tree:

```sh
# run the bootstrapper silently; it extracts the tree, then hangs on the copy (fine):
$CX/bin/cxstart --bottle RaceStudio3 -- "$HOME/Downloads/RaceStudio3-64_xxx.exe" /exenoui /qn
# wait for the ~98% CPU extraction burst to finish, then:
$CX/bin/wineserver --bottle RaceStudio3 -k
# the app now lives at C:\AIM_SPORT\RaceStudio3\ ; set the bottle back to win10:
/tmp/cxwine winecfg -v win10
# launch it directly:
$CX/bin/cxstart --bottle RaceStudio3 -- 'C:\AIM_SPORT\RaceStudio3\64\AiMRS3-64-ReleaseU.exe'
```

## 5. Garbled red text in the UI (old Wine)
CEF GPU-compositing glitch on old Wine. `corefonts` helps a little; the real fix is —
again — updating CrossOver. Do **not** use `--disable-gpu` (it launches RS3 with no window).

---

### Moral
All five of these vanish on CrossOver 26 / Wine 10. The single highest-leverage action for
RaceStudio-3-on-Mac is **using a current CrossOver**. This page exists so the failure
signatures are searchable, not because you should follow it.
