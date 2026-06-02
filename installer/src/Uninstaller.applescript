-- Uninstall RaceStudio 3 — calls the installed engine's uninstall script (resolves paths first,
-- deletes last, self-deletes detached). Asks separately before removing the user's data.
on run
	set b to button returned of (display dialog "Remove RaceStudio 3 from this Mac?" & return & return & "This deletes the RaceStudio 3 app and the Wine engine. Your telemetry data is kept unless you choose to remove it below." buttons {"Cancel", "Remove"} default button "Cancel" with title "Uninstall RaceStudio 3" with icon caution)
	if b is "Cancel" then return

	set rmData to button returned of (display dialog "Also delete your data folder (configs, profiles, and .xrk sessions)?" buttons {"Keep my data", "Delete everything"} default button "Keep my data" with title "Your data" with icon caution)

	set us to (POSIX path of (path to application support folder from user domain)) & "RaceStudio3/bin/uninstall.sh"
	set flag to ""
	if rmData is "Delete everything" then set flag to " --remove-data"
	try
		do shell script "bash " & quoted form of us & flag
	on error errMsg
		display dialog "Couldn't complete uninstall: " & errMsg buttons {"OK"} default button 1 with icon stop
		return
	end try
	display dialog "RaceStudio 3 has been removed." & return & (my keptNote(rmData)) buttons {"OK"} default button 1 with title "Done" with icon note
end run

on keptNote(rmData)
	if rmData is "Delete everything" then return "Your data folder was also deleted."
	return "Your data folder was kept."
end keptNote
