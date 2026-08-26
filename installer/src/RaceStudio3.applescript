-- RaceStudio 3 — one app that you drag to /Applications.
--   • First launch: sets up a pinned modern Wine + RaceStudio 3 (the 8-phase flow with a live
--     progress bar), then opens RS3. No Terminal, no Parallels, no CrossOver.
--   • Later launches: just opens RaceStudio 3.
--   • Drop an AIM_SPORT folder / .zip / .xrk / .drk onto the app to import data (never overwrites).
-- The Wine engine + Windows prefix live in ~/Library/Application Support/RaceStudio3 (outside the
-- signed app, as required), your data in ~/Documents/AIM_SPORT. Import / Uninstall are standalone
-- apps that ship beside this one in /Applications/AiM (the DMG drops the whole AiM folder in).
-- Uninstall: run "Uninstall RaceStudio 3" — it removes the engine, this app, and the helpers.

property phaseList : {"preflight", "acquire-installer", "download-wine", "make-prefix", "silent-install", "relocate-data", "make-launcher", "done"}
property phaseLabel : {"Checking your Mac", "Downloading RaceStudio 3 (~345 MB — a few minutes)", "Preparing the engine", "Setting up the Windows environment", "Installing RaceStudio 3 (several minutes)", "Securing your data folder", "Finishing setup", "Almost done"}
property phaseTimeout : {180, 2700, 2100, 420, 1500, 900, 180, 90}
property barScale : 100 -- bar runs 0..100 so the subtitle can read "<n>% complete"

on run
	set coreScript to corePath()
	-- NOT named `st`: that is a reserved token in AppleScript (the ordinal suffix, as in "1st"), and
	-- `set st to …` fails to compile with "Expected expression but found st".
	set appState to installState(coreScript)
	if appState is "RS3_INSTALLED" then
		openApp()
	else if appState is "RS3_OUTDATED" then
		doUpdateSetup(coreScript)
	else
		doFirstRunSetup(coreScript)
	end if
end run

-- Open the app: launch RaceStudio 3. Import / Uninstall are standalone apps in /Applications/AiM
-- (Wine owns the macOS menu bar while RS3 runs, and that menu can't host custom items, so the
-- controls live as their own apps — reachable from Finder, Spotlight, and Launchpad).
on openApp()
	launchRS3()
end openApp

-- Drag-and-drop import. If not set up yet, set up first, then import the dropped items.
on open theItems
	set coreScript to corePath()
	if not isInstalled(coreScript) then
		display dialog "Let's finish setting up RaceStudio 3 first — then I'll import what you dropped." buttons {"OK"} default button 1 with title "RaceStudio 3" with icon note
		doFirstRunSetup(coreScript)
	end if
	set okCount to 0
	set dests to {}
	set cfgs to {}
	set dupCfgs to {}
	set extraCount to 0
	repeat with anItem in theItems
		set importResult to importOne(coreScript, POSIX path of anItem)
		if item 1 of importResult is true then
			set okCount to okCount + 1
			if item 2 of importResult is not "" and dests does not contain item 2 of importResult then
				set end of dests to item 2 of importResult
			end if
			repeat with c in item 3 of importResult
				if cfgs does not contain (c as text) then set end of cfgs to (c as text)
			end repeat
			repeat with c in item 4 of importResult
				if dupCfgs does not contain (c as text) then set end of dupCfgs to (c as text)
			end repeat
			set extraCount to extraCount + (item 5 of importResult)
		end if
	end repeat
	if okCount > 0 then
		-- Everything the drop produced was already there, so do not open with "Imported N item(s)".
		-- Only for a SINGLE dropped item: a folder merge emits neither IMPORT_DEST nor
		-- IMPORT_CONFIG, so on a mixed drop an empty dests list does not mean nothing landed.
		if (count of theItems) = 1 and (count of cfgs) = 0 and (count of dests) = 0 and extraCount = 0 and (count of dupCfgs) > 0 then
			set msg to "Nothing new to import."
		else
			set msg to "Imported " & okCount & " item(s) into your RaceStudio 3 data folder. Nothing existing was overwritten."
		end if
		-- A configuration is done: RS3 lists the cfgs/ folders it finds on disk, so it only has to
		-- be restarted. Sessions are the opposite — RS3 never scans the data folder, and they
		-- appear only once imported through its own UI. Say whichever applies, or both.
		if (count of cfgs) > 0 then
			set cfgText to ""
			repeat with c in cfgs
				set cfgText to cfgText & return & "• " & c
			end repeat
			set msg to msg & return & return & "Configurations added:" & cfgText & return & return & "Quit and reopen RaceStudio 3 to see them under Configurations."
		end if
		if (count of dupCfgs) > 0 then
			set dupText to ""
			repeat with c in dupCfgs
				set dupText to dupText & return & "• " & c
			end repeat
			set msg to msg & return & return & "Already in RaceStudio 3, not copied again:" & dupText
		end if
		if extraCount > 0 then
			set msg to msg & return & return & "Added " & extraCount & " shared resource file(s) the configuration needs (icons, masks)."
		end if
		if (count of dests) > 0 then
			set destText to ""
			repeat with d in dests
				set destText to destText & return & d
			end repeat
			set msg to msg & return & return & "RaceStudio 3 won't show your sessions until you import them:" & return & "Open RaceStudio 3 → cogwheel (bottom-left) → Import → Import Folder, then pick:" & destText & return & return & "(Or Import File(s) for individual sessions.)"
		end if
		display dialog msg buttons {"OK"} default button 1 with title "Import complete" with icon note
	end if
end open

on doFirstRunSetup(coreScript)
	set b to button returned of (display dialog "Welcome to RaceStudio 3 for Mac." & return & return & "The first time you open it, I'll set everything up — no Windows, no Parallels." & return & return & "• Takes about 10 minutes and needs an internet connection." & return & "• Your data goes in your Documents folder." & return & "• Connect AiM devices over Wi-Fi (USB isn't supported)." buttons {"Quit", "Set Up"} default button "Set Up" with title "RaceStudio 3" with icon note)
	if b is "Quit" then return

	runAllPhases(coreScript)

	set b to button returned of (display dialog "RaceStudio 3 is ready! 🎉" & return & return & "• It's in your Applications folder for next time." & return & "• “Import RaceStudio 3 Data” and “Uninstall RaceStudio 3” are in Applications ▸ AiM." & return & "• Connect AiM devices over Wi-Fi (USB isn't supported under Wine)." & return & "• If macOS asks “Wine wants to access Documents”, click Allow." buttons {"Done", "Open RaceStudio 3"} default button "Open RaceStudio 3" with title "All set" with icon note)
	if b is "Open RaceStudio 3" then openApp()
end doFirstRunSetup

-- This app ships a newer RaceStudio 3 than the one already set up. Same phases as a first run —
-- everything already done verifies and skips — but the copy has to say "update", not "welcome",
-- and it has to be honest that it's a full download.
on doUpdateSetup(coreScript)
	set b to button returned of (display dialog "This version of the app installs a newer RaceStudio 3." & return & return & "• It downloads about 350 MB and takes several minutes." & return & "• Your settings and telemetry are not touched." & return & "• Quit RaceStudio 3 first if it's open." buttons {"Not Now", "Update"} default button "Update" with title "Update RaceStudio 3" with icon note)
	if b is "Not Now" then
		openApp()
		return
	end if

	runAllPhases(coreScript)

	set b to button returned of (display dialog "RaceStudio 3 is up to date." buttons {"Done", "Open RaceStudio 3"} default button "Open RaceStudio 3" with title "Update complete" with icon note)
	if b is "Open RaceStudio 3" then openApp()
end doUpdateSetup

on runAllPhases(coreScript)
	set total to count of phaseList
	set progress total steps to barScale
	set progress additional description to "0% complete"
	repeat with i from 1 to total
		set progress description to "Step " & i & " of " & total & ": " & (item i of phaseLabel) & "…"
		runPhase(coreScript, item i of phaseList, item i of phaseTimeout, i, total)
	end repeat
	set progress completed steps to barScale
	set progress additional description to "100% complete"
end runAllPhases

-- Launch RS3 by exec'ing the Wine bundled INSIDE this app, so macOS resolves Wine's main bundle
-- to RaceStudio 3.app and the menu bar reads "RaceStudio 3" (not "Wine"). Runs detached.
on launchRS3()
	ensureBridge()
	set wb to wineBin()
	set res to (POSIX path of (path to me)) & "Contents/Resources"
	set root to (POSIX path of (path to application support folder from user domain)) & "RaceStudio3"
	-- Pre-launch hygiene, ONLY when RS3 itself isn't running (re-opening the app while RS3 is
	-- up must never kill the live session):
	--  1. wineserver -k clears STALE Wine sessions (crash/force-quit leftovers hold the prefix
	--     lock and make the next launch hang at graphics init — on-device finding 2026-06-08).
	--  2. Refresh the prefix's copied ws2_32.dll, wlanapi.dll AND gdiplus.dll from the bundle if
	--     they differ. Wine copies builtins into the prefix at CREATION time only, so an upgraded
	--     app left the OLD unpatched DLLs in system32/syswow64 and the WiFi redirect/synthetic-
	--     interface never ran (2026-06-09 / 2026-06-11). RS3 loads from the prefix copy, so it
	--     must be refreshed. gdiplus.dll (the flatten-loop guard, added 2026-07-21 for #29/#30)
	--     is the same "builtin DLL copied at prefix creation" shape, so it rides the same loop.
	--  3. Force VLC's software (wingdi) video output for the lap-compare videos. RS3 plays them
	--     through an embedded libVLC; under Wine on Apple Silicon, wined3d can't create a D3D11
	--     device, so VLC's direct3d11 vout never opens, the direct3d9 vout shrinks the 2nd compare
	--     video on a shared fake device, and the OpenGL vout corrupts the frame — only wingdi (GDI)
	--     renders correctly at the right size. Disable the GPU vout plugins so VLC falls to wingdi
	--     (idempotent; re-applies after an RS3 in-app update re-adds them). 2026-06-13.
	--  4. Delete Wine's default `z: -> /` drive. Z: hands RS3 the entire Mac as a fixed disk, and
	--     RS3 recursively walks every fixed drive after a config clone/import — a directory-symlink
	--     cycle anywhere on the Mac (e.g. calibre.app's nested Qt helper bundle) then hangs it
	--     forever. Re-applied each launch so an already-installed prefix migrates without a
	--     reinstall; only removed when it resolves to "/", so a deliberate z: mapping survives.
	--     Full reasoning in drop_host_root_drive (lib/wine.sh). 2026-07-31, issue #32.
	set hygiene to "if ! pgrep -f 'AiMRS3-64' >/dev/null 2>&1; then " & ¬
		quoted form of (res & "/wine/bin/wineserver") & " -k 2>/dev/null; " & ¬
		quoted form of (res & "/wine/bin/wineserver") & " -w 2>/dev/null; " & ¬
		"for p in 'x86_64-windows system32' 'i386-windows syswow64'; do set -- $p; " & ¬
		"for dll in ws2_32 wlanapi gdiplus; do " & ¬
		"s=" & quoted form of (res & "/wine/lib/wine") & "/$1/$dll.dll; " & ¬
		"d=" & quoted form of (root & "/prefix/drive_c/windows") & "/$2/$dll.dll; " & ¬
		"if [ -f \"$s\" ] && [ -f \"$d\" ] && ! cmp -s \"$s\" \"$d\"; then cp -f \"$s\" \"$d\"; fi; done; done; " & ¬
		"dd=" & quoted form of (root & "/prefix/dosdevices") & "; " & ¬
		"if [ -L \"$dd/z:\" ] && [ \"$(readlink \"$dd/z:\")\" = / ]; then rm -f \"$dd/z:\" \"$dd/z::\" 2>/dev/null; fi; " & ¬
		"vp=" & quoted form of (root & "/prefix/drive_c/AIM_SPORT/RaceStudio3/64/plugins") & "; " & ¬
		"if [ -d \"$vp\" ]; then for vplug in libdirect3d11_plugin libdirect3d9_plugin libgl_plugin libglwin32_plugin libwgl_plugin; do " & ¬
		"[ -f \"$vp/$vplug.dll\" ] && mv -f \"$vp/$vplug.dll\" \"$vp/$vplug.dll.disabled\"; done; rm -f \"$vp/plugins.dat\" 2>/dev/null; fi; fi; "
	-- Build the launch command. The trailing bridge loop keeps THIS launcher applet (and its Dock
	-- icon) alive until the wine GUI window is actually on screen, so the Dock icon never blinks out
	-- mid-launch (which reads as a crash). wine boots in the background and takes ~3-4s (RS3 +
	-- MoltenVK init) to show a window.
	-- Signal: the GUI process advertises our patched CFBundleName "RaceStudio 3" (same display name
	-- as this applet) and winemac force-activates it when its window appears. So bridge until the
	-- FRONTMOST app is named *RaceStudio* with an ASN different from this launcher's own — i.e. the
	-- RS3 GUI window became active (the visible moment), not merely registered (~1s before its tile
	-- draws) and not this still-frontmost launcher. Matching *RaceStudio* (not a generic *wine*)
	-- keeps it specific to RS3, so an unrelated Wine app already running can't trip the wait early.
	-- Bounded ~8s (32 * 0.25) so a focus-steal can never hang the applet. The trailing pgrep makes
	-- the launch's exit status reflect whether RS3 actually came up (the nohup'd wine is detached, so
	-- without this the script would always exit 0 and the on-error dialog below could never fire).
	-- 5. CEF web maps (track-view satellite background): RS3 embeds Chromium 66; under Wine its GPU
	--    compositor can't present frames to the winemac window, so the web-maps panel renders WHITE
	--    (the renderer produces the map — tiles download, JS runs — but the surface never draws).
	--    --disable-gpu-compositing disables only the GPU compositing step (compositing runs in
	--    software), so the frames present and the satellite map shows. 2026-08-02, issue #37.
	set bridgeWait to "self_asn=\"$(/usr/bin/lsappinfo front)\"; for _i in $(seq 1 32); do f=\"$(/usr/bin/lsappinfo front)\"; if [ \"$f\" != \"$self_asn\" ]; then case \"$(/usr/bin/lsappinfo info -only name \"$f\" 2>/dev/null)\" in *RaceStudio*) break ;; esac; fi; /bin/sleep 0.25; done; /usr/bin/pgrep -f AiMRS3-64 >/dev/null 2>&1 || exit 1"
	set sh to "export WINEPREFIX=" & quoted form of (root & "/prefix") & " WINEARCH=win64 WINEDEBUG=-all; " & ¬
		"export WINEDLLOVERRIDES=" & quoted form of "mscoree=d;mshtml=d" & "; " & ¬
		"export XDG_CACHE_HOME=" & quoted form of (root & "/cache") & " XDG_CONFIG_HOME=" & quoted form of (root & "/xdg-config") & " XDG_DATA_HOME=" & quoted form of (root & "/xdg-data") & "; " & ¬
		"mkdir -p " & quoted form of (root & "/logs") & "; " & hygiene & ¬
		"nohup arch -x86_64 " & quoted form of wb & " 'C:\\AIM_SPORT\\RaceStudio3\\64\\AiMRS3-64-ReleaseU.exe' --disable-gpu-compositing >> " & quoted form of (root & "/logs/run.log") & " 2>&1 & " & bridgeWait
	try
		do shell script sh
	on error
		display dialog "Couldn't start RaceStudio 3. Try opening this app again to repair the setup." buttons {"OK"} default button 1 with icon caution
	end try
end launchRS3

on wineBin()
	return (POSIX path of (path to me)) & "Contents/Resources/wine/bin/wine"
end wineBin

-- Ensure the root aim-bridge daemon is registered + running before RS3 scans for devices.
-- Only on macOS 15+ (where the Local Network gate blocks the Wine guest); older macOS reaches
-- AiM devices natively. Best-effort: never block RS3 from launching, and on first run guide the
-- user to enable it (one-time Login Items toggle). If they skip it, Wi-Fi just won't find devices
-- and SD/USB import remains available — same as before the bridge existed.
on ensureBridge()
	try
		set vmajor to (do shell script "sw_vers -productVersion | cut -d. -f1") as integer
	on error
		return
	end try
	if vmajor < 15 then return
	set ctlBin to (POSIX path of (path to me)) & "Contents/MacOS/aim-bridge-ctl"
	-- Control tool missing → nothing we can do; launch straight into RS3.
	try
		do shell script "test -x " & quoted form of ctlBin
	on error
		return
	end try
	-- Read the daemon state. aim-bridge-ctl exits NON-ZERO for every non-enabled state
	-- (notFound=1, requiresApproval=3) and `do shell script` raises an AppleScript error on ANY
	-- non-zero exit — so we MUST swallow the exit code (|| true), otherwise the setup dialog below
	-- is unreachable on first run (the bug that left users with no Wi-Fi prompt and no devices).
	-- Already approved + running? Launch straight into RS3.
	set brState to ""
	try
		set brState to do shell script quoted form of ctlBin & " status 2>/dev/null || true"
	end try
	if brState is "enabled" then return
	-- Not enabled yet. PRIME the user BEFORE triggering macOS's background-activity prompt, so the
	-- system dialog ("“RaceStudio 3” can run in the background…") isn't a surprise. Let them opt out.
	set b to button returned of (display dialog "To connect AiM devices over Wi-Fi on this version of macOS, RaceStudio 3 uses a small background helper." & return & return & "macOS will now ask to allow “RaceStudio 3” to run in the background — click Allow. You can change this any time in System Settings ▸ General ▸ Login Items & Extensions." & return & return & "Prefer not to? Skip this — you can still import data from an SD card or USB." buttons {"Skip", "Set Up Wi-Fi"} default button "Set Up Wi-Fi" with title "Allow Wi-Fi access" with icon note)
	if b is "Skip" then return
	-- This is what raises the macOS approval prompt. Like `status`, `register` echoes the resulting
	-- state and exits non-zero for it (requiresApproval=3) — swallow the exit code so the follow-up
	-- dialog below is reachable instead of being skipped by `do shell script`'s error-on-nonzero.
	set brStatus to ""
	try
		set brStatus to do shell script quoted form of ctlBin & " register 2>/dev/null || true"
	end try
	-- Still pending (they haven't clicked Allow, or need the Settings toggle) → open the exact pane.
	if brStatus is "requiresApproval" then
		set b2 to button returned of (display dialog "Almost there — turn on “RaceStudio 3” under Login Items & Extensions (Allow in the Background) to finish enabling Wi-Fi." buttons {"Open Login Items", "Later"} default button "Open Login Items" with title "Allow Wi-Fi access" with icon caution)
		if b2 is "Open Login Items" then
			try
				do shell script "open 'x-apple.systempreferences:com.apple.LoginItems-Settings'"
			end try
		end if
	end if
end ensureBridge

on installState(coreScript)
	try
		set out to do shell script "UI_MODE=applet " & quoted form of coreScript & " install-state 2>/dev/null"
		if out contains "RS3_INSTALLED" then return "RS3_INSTALLED"
		if out contains "RS3_OUTDATED" then return "RS3_OUTDATED"
		return "RS3_ABSENT"
	on error
		return "RS3_ABSENT"
	end try
end installState

-- Drag-and-drop import only needs a set-up prefix; importing into an older RaceStudio 3 is fine,
-- so an upgrade is deliberately NOT forced here.
on isInstalled(coreScript)
	return (installState(coreScript) is not "RS3_ABSENT")
end isInstalled

on importOne(coreScript, p)
	try
		with timeout of 1800 seconds
			set out to do shell script "UI_MODE=applet RS3_SINGLE_APP=1 bash " & quoted form of coreScript & " --import " & quoted form of p & " 2>&1"
		end timeout
		-- capture the staged destination from the engine's machine-readable
		-- "IMPORT_DEST: <path>" line (see ui_import_dest in lib/ui.sh). Nothing else
		-- in the output is a reliable path — do NOT parse the human STATUS lines.
		set dest to ""
		set cfgNames to {}
		set dupNames to {}
		set extras to 0
		repeat with aLine in paragraphs of out
			if aLine starts with "IMPORT_DEST: " then
				set dest to (characters 14 thru -1 of aLine) as text
			else if aLine starts with "IMPORT_CONFIG: " then
				set end of cfgNames to ((characters 16 thru -1 of aLine) as text)
			else if aLine starts with "IMPORT_CONFIG_DUP: " then
				set end of dupNames to ((characters 20 thru -1 of aLine) as text)
			else if aLine starts with "IMPORT_EXTRAS: " then
				set extras to extras + (((characters 16 thru -1 of aLine) as text) as integer)
			end if
		end repeat
		return {true, dest, cfgNames, dupNames, extras}
	on error errMsg
		display dialog "Couldn't import “" & p & "”:" & return & return & errMsg buttons {"OK"} default button 1 with title "Import problem" with icon stop
		return {false, "", {}, {}, 0}
	end try
end importOne

-- ---- install engine (shared with the old standalone installer) --------------------------
on runPhase(coreScript, ph, tmo, stepIndex, total)
	repeat
		set out to runCoreAsync(coreScript, ph, tmo, stepIndex, total)
		set rc to rcOf(out)
		if rc is 0 then
			return
		else if rc is 11 then
			installRosetta()
		else if rc is 10 then
			handleNeeds(coreScript, out)
		else
			showError(out)
			error number -128
		end if
	end repeat
end runPhase

-- Run the phase DETACHED and poll, so the progress bar animates (a synchronous do shell script
-- blocks the applet's main thread and the bar would look frozen during long downloads).
on runCoreAsync(coreScript, ph, tmo, stepIndex, total)
	set base to do shell script "mktemp /tmp/rs3phase.XXXXXX"
	set outF to base & ".out"
	set rcF to base & ".rc"
	-- Import / Uninstall ship as sibling apps in the same /Applications/AiM folder (placed by the
	-- DMG drag), so there's nothing for make-launcher to copy out.
	set cmd to "( RS3_SINGLE_APP=1 RS3_WINE_BIN=" & quoted form of wineBin() & " UI_MODE=applet " & quoted form of coreScript & " " & ph & " >" & quoted form of outF & " 2>&1; echo $? >" & quoted form of rcF & " ) </dev/null >/dev/null 2>&1 &"
	do shell script cmd

	set baseUnits to ((stepIndex - 1) / total) * barScale
	set sliceUnits to (1 / total) * barScale
	set waited to 0
	set creep to 0.0
	repeat
		if (do shell script "if [ -f " & quoted form of rcF & " ]; then echo y; else echo n; fi") is "y" then exit repeat
		if waited ≥ tmo then exit repeat
		if creep < 0.92 then set creep to creep + 0.03
		try
			set cs to (round (baseUnits + sliceUnits * creep))
			set progress completed steps to cs
			set progress additional description to (cs as string) & "% complete"
		end try
		delay 1
		set waited to waited + 1
	end repeat

	set out to ""
	try
		set out to do shell script "cat " & quoted form of outF
	end try
	set rc to 124
	try
		set rc to (do shell script "cat " & quoted form of rcF) as integer
	end try
	try
		set cs to (round (baseUnits + sliceUnits))
		set progress completed steps to cs
		set progress additional description to (cs as string) & "% complete"
	end try
	do shell script "rm -f " & quoted form of outF & " " & quoted form of rcF & " " & quoted form of base
	return out & return & "RC:" & rc
end runCoreAsync

on handleNeeds(coreScript, out)
	if out contains "NEEDS_CHOICE: icloud_location" then
		set home_ to POSIX path of (path to home folder)
		set b to button returned of (display dialog "Your Documents folder syncs to iCloud. iCloud can move telemetry off this Mac to save space, which can break RaceStudio 3's live database." & return & return & "Where should RaceStudio 3 keep its data?" buttons {"Keep in Documents", "Use a safe local folder"} default button "Use a safe local folder" with title "Where to store data" with icon caution)
		if b is "Keep in Documents" then
			setConfig(coreScript, "DATA_DIR", home_ & "Documents/AIM_SPORT")
		else
			setConfig(coreScript, "DATA_DIR", home_ & "AIM_SPORT")
		end if
	else if out contains "NEEDS_INSTALLER" then
		-- The core names the exact file it needs. Say it out loud: the file is now checked, so
		-- picking the wrong one just brings this dialog back, and a user who isn't told which
		-- file to pick has no way out of that loop.
		set wantFile to ""
		try
			-- Backslashes are DOUBLED because this is an AppleScript string literal: `\(` is not a
			-- valid AppleScript escape and makes the whole file fail to compile. `\\(` is what
			-- puts a literal `\(` in front of sed. Matched unanchored, because `do shell script`
			-- hands back CR-separated lines and the core prints PROGRESS:/WARN: before this one,
			-- so a `^`-anchored pattern never fires.
			set wantFile to do shell script "printf '%s' " & quoted form of out & " | sed -n 's|.*NEEDS_INSTALLER: \\([A-Za-z0-9._-]*\\).*|\\1|p' | head -1"
		end try
		if wantFile is "" then set wantFile to "RaceStudio3-64_….exe"
		display dialog "I couldn't download the RaceStudio 3 installer automatically. I'll open AiM's download page — save “" & wantFile & "”, then choose it on the next screen." buttons {"Open AiM page"} default button 1 with title "Get the installer" with icon note
		try
			do shell script "open 'https://www.aim-sportline.com/docs/racestudio3/html/release/download-release.html'"
		end try
		set f to choose file with prompt "Select “" & wantFile & "”"
		set fp to POSIX path of f
		set cache to (POSIX path of (path to application support folder from user domain)) & "RaceStudio3/installer/"
		set dest to cache & (do shell script "basename " & quoted form of fp)
		do shell script "mkdir -p " & quoted form of cache & " && ditto " & quoted form of fp & " " & quoted form of dest
		setConfig(coreScript, "INSTALLER_EXE", dest)
	else if out contains "NEEDS_CONFIRM: " then
		set b to button returned of (display dialog "Please confirm to continue." buttons {"Cancel", "Continue"} default button "Continue" with icon caution)
		if b is "Cancel" then error number -128
	else
		showError(out)
		error number -128
	end if
end handleNeeds

on installRosetta()
	try
		with timeout of 900 seconds
			do shell script "softwareupdate --install-rosetta --agree-to-license" with administrator privileges
		end timeout
	on error
		display dialog "RaceStudio 3 needs Rosetta 2 (Apple's Intel translation layer), which wasn't installed." & return & return & "You can install it later by opening Terminal and running:" & return & "softwareupdate --install-rosetta" buttons {"OK"} default button 1 with title "Rosetta 2 required" with icon stop
		error number -128
	end try
end installRosetta

on showError(out)
	set logp to (POSIX path of (path to application support folder from user domain)) & "RaceStudio3/logs/install.log"
	set b to button returned of (display dialog "Something went wrong during setup." & return & return & firstError(out) buttons {"Show Log", "OK"} default button "OK" with title "Setup problem" with icon stop)
	if b is "Show Log" then
		try
			do shell script "open " & quoted form of logp
		end try
	end if
end showError

-- helpers ---------------------------------------------------------------------------------
on corePath()
	return POSIX path of ((path to me as text) & "Contents:Resources:installer-core.sh")
end corePath

on setConfig(coreScript, k, v)
	do shell script "UI_MODE=applet " & quoted form of coreScript & " set-config " & quoted form of k & " " & quoted form of v
end setConfig

on rcOf(out)
	set ls to paragraphs of out
	repeat with k from (count ls) to 1 by -1
		set ln to item k of ls
		if ln starts with "RC:" then
			try
				return (text 4 thru -1 of ln) as integer
			end try
		end if
	end repeat
	return 1
end rcOf

on firstError(out)
	repeat with ln in paragraphs of out
		if (ln as text) starts with "ERROR: " then return text 8 thru -1 of (ln as text)
	end repeat
	return "See the log for details."
end firstError
