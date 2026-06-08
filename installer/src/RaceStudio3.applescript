-- RaceStudio 3 — one app that you drag to /Applications.
--   • First launch: sets up a pinned modern Wine + RaceStudio 3 (the 8-phase flow with a live
--     progress bar), then opens RS3. No Terminal, no Parallels, no CrossOver.
--   • Later launches: just opens RaceStudio 3.
--   • Drop an AIM_SPORT folder / .zip / .xrk onto the app to import data (never overwrites).
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
	if isInstalled(coreScript) then
		openApp()
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
	repeat with anItem in theItems
		if importOne(coreScript, POSIX path of anItem) then set okCount to okCount + 1
	end repeat
	if okCount > 0 then
		display dialog "Imported " & okCount & " item(s) into your RaceStudio 3 data folder. Nothing existing was overwritten." buttons {"OK"} default button 1 with title "Import complete" with icon note
	end if
end open

on doFirstRunSetup(coreScript)
	set b to button returned of (display dialog "Welcome to RaceStudio 3 for Mac." & return & return & "The first time you open it, I'll set everything up — no Windows, no Parallels." & return & return & "• Takes about 10 minutes and needs an internet connection." & return & "• Your data goes in your Documents folder." & return & "• Connect AiM devices over Wi-Fi (USB isn't supported)." buttons {"Quit", "Set Up"} default button "Set Up" with title "RaceStudio 3" with icon note)
	if b is "Quit" then return

	set total to count of phaseList
	set progress total steps to barScale
	set progress additional description to "0% complete"
	repeat with i from 1 to total
		set progress description to "Step " & i & " of " & total & ": " & (item i of phaseLabel) & "…"
		runPhase(coreScript, item i of phaseList, item i of phaseTimeout, i, total)
	end repeat
	set progress completed steps to barScale
	set progress additional description to "100% complete"

	set b to button returned of (display dialog "RaceStudio 3 is ready! 🎉" & return & return & "• It's in your Applications folder for next time." & return & "• “Import RaceStudio 3 Data” and “Uninstall RaceStudio 3” are in Applications ▸ AiM." & return & "• Connect AiM devices over Wi-Fi (USB isn't supported under Wine)." & return & "• If macOS asks “Wine wants to access Documents”, click Allow." buttons {"Done", "Open RaceStudio 3"} default button "Open RaceStudio 3" with title "All set" with icon note)
	if b is "Open RaceStudio 3" then openApp()
end doFirstRunSetup

-- Launch RS3 by exec'ing the Wine bundled INSIDE this app, so macOS resolves Wine's main bundle
-- to RaceStudio 3.app and the menu bar reads "RaceStudio 3" (not "Wine"). Runs detached.
on launchRS3()
	ensureBridge()
	set wb to wineBin()
	set root to (POSIX path of (path to application support folder from user domain)) & "RaceStudio3"
	set sh to "export WINEPREFIX=" & quoted form of (root & "/prefix") & " WINEARCH=win64 WINEDEBUG=-all; " & ¬
		"export WINEDLLOVERRIDES=" & quoted form of "mscoree=d;mshtml=d" & "; " & ¬
		"export XDG_CACHE_HOME=" & quoted form of (root & "/cache") & " XDG_CONFIG_HOME=" & quoted form of (root & "/xdg-config") & " XDG_DATA_HOME=" & quoted form of (root & "/xdg-data") & "; " & ¬
		"mkdir -p " & quoted form of (root & "/logs") & "; " & ¬
		"nohup arch -x86_64 " & quoted form of wb & " 'C:\\AIM_SPORT\\RaceStudio3\\64\\AiMRS3-64-ReleaseU.exe' >> " & quoted form of (root & "/logs/run.log") & " 2>&1 & "
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
	-- Already approved + running? Nothing to do — launch straight into RS3.
	try
		if (do shell script quoted form of ctlBin & " status 2>/dev/null") is "enabled" then return
	on error
		return -- control tool missing/failed: don't nag, just launch RS3
	end try
	-- Not enabled yet. PRIME the user BEFORE triggering macOS's background-activity prompt, so the
	-- system dialog ("“RaceStudio 3” can run in the background…") isn't a surprise. Let them opt out.
	set b to button returned of (display dialog "To connect AiM devices over Wi-Fi on this version of macOS, RaceStudio 3 uses a small background helper." & return & return & "macOS will now ask to allow “RaceStudio 3” to run in the background — click Allow. You can change this any time in System Settings ▸ General ▸ Login Items & Extensions." & return & return & "Prefer not to? Skip this — you can still import data from an SD card or USB." buttons {"Skip", "Set Up Wi-Fi"} default button "Set Up Wi-Fi" with title "Allow Wi-Fi access" with icon note)
	if b is "Skip" then return
	-- This is what raises the macOS approval prompt.
	set brStatus to ""
	try
		set brStatus to do shell script quoted form of ctlBin & " register 2>/dev/null"
	on error
		return
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

on isInstalled(coreScript)
	try
		set out to do shell script "UI_MODE=applet " & quoted form of coreScript & " is-installed 2>/dev/null"
		return (out contains "RS3_INSTALLED")
	on error
		return false
	end try
end isInstalled

on importOne(coreScript, p)
	try
		with timeout of 1800 seconds
			do shell script "UI_MODE=applet RS3_SINGLE_APP=1 bash " & quoted form of coreScript & " --import " & quoted form of p & " 2>&1"
		end timeout
		return true
	on error errMsg
		display dialog "Couldn't import “" & p & "”:" & return & return & errMsg buttons {"OK"} default button 1 with title "Import problem" with icon stop
		return false
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
		display dialog "I couldn't download the RaceStudio 3 installer automatically. I'll open AiM's download page — save the installer, then choose it on the next screen." buttons {"Open AiM page"} default button 1 with title "Get the installer" with icon note
		try
			do shell script "open 'https://www.aim-sportline.com/docs/racestudio3/html/release/download-release.html'"
		end try
		set f to choose file with prompt "Select the RaceStudio3 installer you downloaded (RaceStudio3-64_….exe)"
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
