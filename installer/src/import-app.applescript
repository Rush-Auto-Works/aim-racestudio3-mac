-- Import RaceStudio 3 Data — a standalone app (installed into /Applications/AiM). Brings your
-- telemetry in: choose a folder, or drop an AIM_SPORT folder, a RaceStudio3 "user" folder, a
-- .zip of either, or loose .xrk/.drk session files onto it. Everything is MERGED into your
-- RaceStudio 3 data folder and nothing you already have is overwritten. The install engine
-- (installer-core.sh) is embedded in this app's Resources so it works wherever the app is moved.

on run
	set core to corePath()
	if not isInstalled(core) then
		needSetup()
		return
	end if
	set f to choose folder with prompt "Choose an AIM_SPORT folder, a RaceStudio3 “user” folder, or a folder of .xrk/.drk files to import."
	importItems(core, {f})
end run

-- drag-and-drop: accept dropped folders / .zip / .xrk / .drk
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
	set dest to ""
	repeat with anItem in theItems
		set importResult to importOne(core, POSIX path of anItem)
		if item 1 of importResult is true then
			set okCount to okCount + 1
			if dest is "" and item 2 of importResult is not "" then set dest to item 2 of importResult
		end if
	end repeat
	if okCount > 0 then
		-- RS3 does not scan the data folder on its own: sessions only appear once imported
		-- through RS3's own UI (cogwheel → Import → Import Folder/File(s)). Point the user at
		-- where the files were staged so they can do that final step.
		if dest is not "" then
			set msg to "Imported " & okCount & " item(s) into your RaceStudio 3 data folder. Nothing existing was overwritten." & return & return & "RaceStudio 3 won't show these until you import them:" & return & "Open RaceStudio 3 → cogwheel (bottom-left) → Import → Import Folder, then pick:" & return & return & dest & return & return & "(Or Import File(s) for individual sessions.)"
		else
			set msg to "Imported " & okCount & " item(s) into your RaceStudio 3 data folder. Nothing existing was overwritten."
		end if
		display dialog msg buttons {"OK"} default button 1 with title "Import complete" with icon note
	end if
end importItems

on importOne(core, p)
	try
		with timeout of 1800 seconds
			set out to do shell script "UI_MODE=applet RS3_SINGLE_APP=1 bash " & quoted form of core & " --import " & quoted form of p & " 2>&1"
		end timeout
		-- capture the staged destination from the engine's machine-readable
		-- "IMPORT_DEST: <path>" line (see ui_import_dest in lib/ui.sh). Nothing else
		-- in the output is a reliable path — do NOT parse the human STATUS lines.
		set dest to ""
		repeat with aLine in paragraphs of out
			if aLine starts with "IMPORT_DEST: " then
				set dest to (characters 14 thru -1 of aLine) as text
			end if
		end repeat
		return {true, dest}
	on error errMsg
		display dialog "Couldn't import “" & p & "”:" & return & return & errMsg buttons {"OK"} default button 1 with title "Import problem" with icon stop
		return {false, ""}
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
