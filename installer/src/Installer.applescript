-- Install RaceStudio 3 — the friendly face over installer-core.sh.
-- AppleScript is the parent; it runs the embedded bash engine via `do shell script` (hidden,
-- NO Terminal) one phase at a time, renders all dialogs + the native progress bar, and handles
-- the core's machine-readable signals (NEEDS_ROSETTA / NEEDS_CHOICE / NEEDS_CONFIRM / NEEDS_INSTALLER).

property phaseList : {"preflight", "acquire-installer", "download-wine", "make-prefix", "silent-install", "relocate-data", "make-launcher", "done"}
property phaseLabel : {"Checking your Mac", "Getting the installer", "Downloading the engine (Wine)", "Setting up the Windows environment", "Installing RaceStudio 3", "Securing your data folder", "Creating your RaceStudio 3 app", "Finishing up"}
property phaseTimeout : {180, 2700, 2100, 420, 1500, 900, 180, 90}

on run
	set coreScript to corePath()

	-- Welcome
	set b to button returned of (display dialog "This installs RaceStudio 3 on your Mac using free software — no Windows, no Parallels." & return & return & "• Takes about 10 minutes and needs an internet connection." & return & "• Your files go in your Documents folder; an app appears in Applications." & return & "• Connect AiM devices over Wi-Fi (USB isn't supported)." buttons {"Quit", "Install"} default button "Install" with title "Install RaceStudio 3" with icon note)
	if b is "Quit" then return

	set total to count of phaseList
	repeat with i from 1 to total
		set progress total steps to total
		set progress completed steps to (i - 1)
		set progress description to "Step " & i & " of " & total & ": " & (item i of phaseLabel) & "…"
		runPhase(coreScript, item i of phaseList, item i of phaseTimeout)
	end repeat
	set progress completed steps to total

	-- Done
	set b to button returned of (display dialog "RaceStudio 3 is installed! 🎉" & return & return & "• Open it from Applications → “RaceStudio 3”." & return & "• Connect AiM devices over Wi-Fi (USB isn't supported under Wine)." & return & "• If macOS asks “Wine wants to access Documents”, click Allow." buttons {"Done", "Launch RaceStudio 3"} default button "Launch RaceStudio 3" with title "All set" with icon note)
	if b is "Launch RaceStudio 3" then
		try
			do shell script "open " & quoted form of ((POSIX path of (path to applications folder from user domain)) & "RaceStudio 3.app")
		end try
	end if
end run

-- Run one phase, retrying the SAME phase after collecting any decision, until it advances (exit 0).
on runPhase(coreScript, ph, tmo)
	repeat
		set out to runCore(coreScript, ph, tmo)
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

on runCore(coreScript, ph, tmo)
	set extraEnv to ""
	if ph is "make-launcher" then
		set appsRes to POSIX path of ((path to me as text) & "Contents:Resources:apps:")
		set extraEnv to "LAUNCHER_APP_SRC=" & quoted form of (appsRes & "RaceStudio 3.app") & " UNINSTALL_APP_SRC=" & quoted form of (appsRes & "Uninstall RaceStudio 3.app") & " "
	end if
	set cmd to extraEnv & "UI_MODE=applet " & quoted form of coreScript & " " & ph & " 2>&1; echo RC:$?"
	set out to ""
	try
		with timeout of tmo seconds
			set out to do shell script cmd
		end timeout
	on error errMsg number errNum
		set out to errMsg & return & "RC:" & errNum
	end try
	return out
end runCore

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
		-- generic yes/no confirm
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
	set b to button returned of (display dialog "Something went wrong during installation." & return & return & firstError(out) buttons {"Show Log", "OK"} default button "OK" with title "Installation problem" with icon stop)
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
