-- Import RaceStudio 3 Data — a standalone app (installed into /Applications/AiM). Brings your
-- telemetry in: choose a folder, or drop an AIM_SPORT folder, a RaceStudio3 "user" folder, a
-- .zip of either, loose .xrk/.drk session files, or a .zconf2 configuration export onto it.
-- Everything is MERGED into your RaceStudio 3 data folder and nothing you already have is
-- overwritten. The install engine (installer-core.sh) is embedded in this app's Resources so it
-- works wherever the app is moved.

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
	set dests to {}
	set cfgs to {}
	set dupCfgs to {}
	repeat with anItem in theItems
		set importResult to importOne(core, POSIX path of anItem)
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
		end if
	end repeat
	if okCount > 0 then
		-- Everything the drop produced was already there, so do not open with "Imported N item(s)".
		-- Only for a SINGLE dropped item: a folder merge emits neither IMPORT_DEST nor
		-- IMPORT_CONFIG, so on a mixed drop an empty dests list does not mean nothing landed.
		if (count of theItems) = 1 and (count of cfgs) = 0 and (count of dests) = 0 and (count of dupCfgs) > 0 then
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
		if (count of dests) > 0 then
			set destText to ""
			repeat with d in dests
				set destText to destText & return & d
			end repeat
			set msg to msg & return & return & "RaceStudio 3 won't show your sessions until you import them:" & return & "Open RaceStudio 3 → cogwheel (bottom-left) → Import → Import Folder, then pick:" & destText & return & return & "(Or Import File(s) for individual sessions.)"
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
		set cfgNames to {}
		set dupNames to {}
		repeat with aLine in paragraphs of out
			if aLine starts with "IMPORT_DEST: " then
				set dest to (characters 14 thru -1 of aLine) as text
			else if aLine starts with "IMPORT_CONFIG: " then
				set end of cfgNames to ((characters 16 thru -1 of aLine) as text)
			else if aLine starts with "IMPORT_CONFIG_DUP: " then
				set end of dupNames to ((characters 20 thru -1 of aLine) as text)
			end if
		end repeat
		return {true, dest, cfgNames, dupNames}
	on error errMsg
		display dialog "Couldn't import “" & p & "”:" & return & return & errMsg buttons {"OK"} default button 1 with title "Import problem" with icon stop
		return {false, "", {}, {}}
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
