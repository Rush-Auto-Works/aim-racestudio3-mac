-- Import RaceStudio 3 Data — a standalone app (installed into /Applications/AiM). Brings your
-- telemetry in: choose a folder, or drop an AIM_SPORT folder, a RaceStudio3 "user" folder, a
-- .zip of either, or loose .xrk files onto it. Everything is MERGED into your RaceStudio 3 data
-- folder and nothing you already have is overwritten. The install engine (installer-core.sh) is
-- embedded in this app's Resources so it works wherever the app is moved.

on run
	set core to corePath()
	if not isInstalled(core) then
		needSetup()
		return
	end if
	set f to choose folder with prompt "Choose an AIM_SPORT folder, a RaceStudio3 “user” folder, or a folder of .xrk files to import."
	importItems(core, {f})
end run

-- drag-and-drop: accept dropped folders / .zip / .xrk
on open theItems
	set core to corePath()
	if not isInstalled(core) then
		needSetup()
		return
	end if
	importItems(core, theItems)
end open

on importItems(core, theItems)
	set okCount to 0
	repeat with anItem in theItems
		if importOne(core, POSIX path of anItem) then set okCount to okCount + 1
	end repeat
	if okCount > 0 then
		display dialog "Imported " & okCount & " item(s) into your RaceStudio 3 data folder. Nothing existing was overwritten." buttons {"OK"} default button 1 with title "Import complete" with icon note
	end if
end importItems

on importOne(core, p)
	try
		with timeout of 1800 seconds
			do shell script "UI_MODE=applet RS3_SINGLE_APP=1 bash " & quoted form of core & " --import " & quoted form of p & " 2>&1"
		end timeout
		return true
	on error errMsg
		display dialog "Couldn't import “" & p & "”:" & return & return & errMsg buttons {"OK"} default button 1 with title "Import problem" with icon stop
		return false
	end try
end importOne

on needSetup()
	display dialog "RaceStudio 3 isn't set up yet." & return & return & "Open RaceStudio 3 first to finish setup, then import your data." buttons {"OK"} default button 1 with title "Import RaceStudio 3 Data" with icon caution
end needSetup

on isInstalled(core)
	-- Mirror RaceStudio 3.app: importing only needs a set-up prefix, so an OLDER RaceStudio 3 is
	-- fine too. The strict "is-installed" action reports RS3_ABSENT for an outdated build (it
	-- means "satisfies the pin"), which would wrongly refuse the import — ask install-state and
	-- accept anything except a genuinely-absent install.
	try
		set out to do shell script "UI_MODE=applet " & quoted form of core & " install-state 2>/dev/null"
		return (out does not contain "RS3_ABSENT")
	on error
		return false
	end try
end isInstalled

on corePath()
	return POSIX path of ((path to me as text) & "Contents:Resources:installer-core.sh")
end corePath
