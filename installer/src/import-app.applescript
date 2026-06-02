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
	try
		set out to do shell script "UI_MODE=applet " & quoted form of core & " is-installed 2>/dev/null"
		return (out contains "RS3_INSTALLED")
	on error
		return false
	end try
end isInstalled

on corePath()
	return POSIX path of ((path to me as text) & "Contents:Resources:installer-core.sh")
end corePath
