# Paste-into-your-LLM prompt

Copy everything in the box below into Claude Code (or another capable terminal-using AI
assistant) **running on your Mac**. It will install RaceStudio 3 under CrossOver and,
if you want, bulk-import your data from Parallels.

---

```
You are helping me run AiM RaceStudio 3 (a Windows telemetry app) on my Apple Silicon Mac
using CrossOver, with NO Parallels and NO Windows VM. Work step by step, run the commands
yourself, and check results before moving on.

CONTEXT YOU SHOULD VERIFY FIRST (run these, don't assume):
- macOS + chip: `sw_vers` and `uname -m`
- CrossOver installed + version: read /Applications/CrossOver.app/Contents/Info.plist
  (CFBundleShortVersionString). I want v24+, ideally v26+. If it's older, tell me to
  update CrossOver FIRST — old Wine (8 or earlier) makes the installer crash and the UI
  render garbled. The whole job is easy on a current CrossOver and miserable on an old one.
- The RaceStudio 3 installer: latest is at
  https://www.aim-sportline.com/docs/racestudio3/html/release/download-release.html
  (filename like RaceStudio3-64_<ver>.exe). Download it to ~/Downloads if not present.

CROSSOVER CLI YOU'LL USE (note the path):
  CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
  $CX/bin/cxbottle --bottle RaceStudio3 --create --template win10_64
  $CX/bin/cxstart  --bottle RaceStudio3 -- <windows-exe-or-path>
  $CX/bin/wineserver --bottle RaceStudio3 -k     # kill all procs in the bottle
Bottle files live at: ~/Library/Application Support/CrossOver/Bottles/RaceStudio3/drive_c/

INSTALL (the easy path on current CrossOver):
1. Create a Windows 10 bottle named RaceStudio3 (win10_64 template).
2. Run the official installer in it with cxstart. It shows a normal wizard — I'll click
   through it (Next/Install/Finish). Do NOT pass silent flags; let the wizard run.
3. RaceStudio 3 installs to C:\AIM_SPORT\RaceStudio3\ ; main exe is
   64\AiMRS3-64-ReleaseU.exe . Launch it with cxstart to confirm it runs.

If the installer CRASHES with "Unhandled exception 0xe06d7363", the CrossOver is too old.
Tell me to update CrossOver — that is the correct fix, not a workaround.

DATA IMPORT (optional, ask me if I want it):
My existing sessions/configs/profiles may be in a Parallels Windows VM that is RUNNING.
- List VMs: `prlctl list -a`. Run commands inside the guest with:
  `prlctl exec <VM> cmd /c "<command>"`
- RaceStudio 3 user data (configs .zconfig, profiles, database, tracks) is at
  C:\AIM_SPORT\RaceStudio3\user\ in the guest. Logged sessions (.xrk) are under a "data"
  folder that may be redirected to another drive (check E:\data, or the data.lnk shortcut
  in the user folder).
- To copy out of the running VM without suspending it: add a Parallels shared folder
  pointing at a Mac staging dir, then robocopy inside the guest to it:
    prlctl set <VM> --shf-host-add port --path /tmp/rs3stage --mode rw
    prlctl exec <VM> cmd /c "robocopy C:\AIM_SPORT\RaceStudio3\user \\psf\port\user /E /R:1 /W:1"
    prlctl exec <VM> cmd /c "robocopy E:\data \\psf\port\data /E /MAXAGE:20250101 /R:1 /W:1"
- Then close RaceStudio 3 in the bottle and rsync the staged files into the bottle:
    rsync -a /tmp/rs3stage/user/ "<bottle>/drive_c/AIM_SPORT/RaceStudio3/user/"
    # replace the data.lnk shortcut with a real folder so the bottle finds sessions:
    rm -f "<bottle>/.../user/data.lnk"; mkdir -p "<bottle>/.../user/data"
    rsync -a /tmp/rs3stage/data/ "<bottle>/.../user/data/"
- First launch after import is slow for ~1 min (config thumbnail regeneration). Normal.

GOTCHAS:
- WiFi device connection works; USB cable passthrough does not.
- In RaceStudio 3's file dialogs my Mac files are under Z:\Users\<my-username>\ (Z: = the
  Mac filesystem), NOT under the Windows "Documents".
- Commands touching the bottle or network may need to run outside any sandbox.

Start by checking my CrossOver version and whether the installer is downloaded, then tell
me your plan before installing.
```

---

That's it. The assistant should verify your CrossOver version first — if it's old, the
single most effective thing you can do is update CrossOver.
