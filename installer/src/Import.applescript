-- Import RaceStudio 3 Data — a drag-and-drop droplet. Drop an AIM_SPORT (or RaceStudio3 "user")
-- folder, a .zip of one, or loose .xrk session files onto it. Everything funnels through the
-- engine's copy-if-absent MERGE — existing data is NEVER overwritten. Double-clicking it opens a
-- folder picker instead.

on open theItems
	set okCount to 0
	repeat with anItem in theItems
		if importOne(POSIX path of anItem) then set okCount to okCount + 1
	end repeat
	if okCount > 0 then
		display dialog "Import complete — " & okCount & " item(s) merged into your RaceStudio 3 data folder. Nothing existing was overwritten." buttons {"OK"} default button 1 with title "Import RaceStudio 3 Data" with icon note
	end if
end open

on run
	set f to choose folder with prompt "Choose your AIM_SPORT folder, or a RaceStudio3 “user” folder, to import:"
	if importOne(POSIX path of f) then
		display dialog "Import complete — merged into your RaceStudio 3 data folder. Nothing existing was overwritten." buttons {"OK"} default button 1 with title "Import RaceStudio 3 Data" with icon note
	end if
end run

on importOne(p)
	set core to POSIX path of ((path to me as text) & "Contents:Resources:installer-core.sh")
	try
		with timeout of 1800 seconds
			do shell script "UI_MODE=applet bash " & quoted form of core & " --import " & quoted form of p & " 2>&1"
		end timeout
		return true
	on error errMsg
		display dialog "Couldn't import “" & p & "”:" & return & return & errMsg buttons {"OK"} default button 1 with title "Import problem" with icon stop
		return false
	end try
end importOne
