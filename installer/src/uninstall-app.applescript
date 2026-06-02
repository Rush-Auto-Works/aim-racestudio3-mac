-- Uninstall RaceStudio 3 — a standalone app (installed into ~/Applications/AiM). Stops RaceStudio
-- 3, then removes its engine, the Windows environment, and the AiM helper apps. Your telemetry in
-- ~/Documents/AIM_SPORT is kept unless you ask to remove it too. It runs the self-contained
-- uninstaller the installer generated at ~/Library/Application Support/RaceStudio3/bin/uninstall.sh
-- (which deletes this app itself last, detached, so it can finish cleanly).

on run
	set root to (POSIX path of (path to application support folder from user domain)) & "RaceStudio3"
	set uninst to root & "/bin/uninstall.sh"
	try
		do shell script "test -x " & quoted form of uninst
	on error
		display dialog "RaceStudio 3 doesn't appear to be installed." & return & return & "If a “RaceStudio 3” app is left over, drag it from Applications to the Trash." buttons {"OK"} default button 1 with title "Uninstall RaceStudio 3" with icon caution
		return
	end try

	set b to button returned of (display dialog "Remove RaceStudio 3 from this Mac?" & return & return & "This stops RaceStudio 3 and removes its engine and helper apps. Your telemetry in ~/Documents/AIM_SPORT is kept unless you choose to remove it." buttons {"Cancel", "Remove everything", "Remove (keep my data)"} default button "Remove (keep my data)" with title "Uninstall RaceStudio 3" with icon caution)
	if b is "Cancel" then return

	set extra to ""
	if b is "Remove everything" then
		set c to button returned of (display dialog "Also permanently delete your telemetry in ~/Documents/AIM_SPORT?" & return & return & "This can't be undone." buttons {"Keep my data", "Delete my data"} default button "Keep my data" with title "Delete telemetry?" with icon stop)
		if c is "Delete my data" then set extra to " --remove-data"
	end if

	try
		do shell script "bash " & quoted form of uninst & extra
	on error errMsg
		display dialog "Couldn't finish uninstalling:" & return & return & errMsg buttons {"OK"} default button 1 with title "Uninstall problem" with icon stop
		return
	end try

	set msg to "RaceStudio 3's engine and helper apps were removed."
	if extra is "" then set msg to msg & return & return & "Your telemetry in ~/Documents/AIM_SPORT was kept."
	set msg to msg & return & return & "To finish, drag “RaceStudio 3” from your Applications folder to the Trash."
	display dialog msg buttons {"OK"} default button 1 with title "Uninstalled" with icon note
end run
