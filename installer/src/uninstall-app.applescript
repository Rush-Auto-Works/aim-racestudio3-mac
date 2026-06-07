-- Uninstall RaceStudio 3 — a standalone app (installed into /Applications/AiM). Stops RaceStudio
-- 3, then removes everything in /Applications/AiM (the app, the engine, the Windows environment,
-- and the helper apps). Your telemetry folder (chosen at install — ~/AIM_SPORT or
-- ~/Documents/AIM_SPORT) is kept unless you ask to remove it too. It runs the self-contained
-- uninstaller the installer generated at ~/Library/Application Support/RaceStudio3/bin/uninstall.sh
-- (which deletes this app itself last, detached, so it can finish cleanly).

-- tildify(p): show an absolute path under the home folder as ~/… (purely cosmetic).
on tildify(p)
	set homeP to text 1 thru -2 of (POSIX path of (path to home folder)) -- strip trailing "/"
	if p starts with (homeP & "/") then return "~" & (text ((count homeP) + 1) thru -1 of p)
	return p
end tildify

on run
	set root to (POSIX path of (path to application support folder from user domain)) & "RaceStudio3"
	set uninst to root & "/bin/uninstall.sh"
	try
		do shell script "test -x " & quoted form of uninst
	on error
		display dialog "RaceStudio 3 doesn't appear to be installed." & return & return & "If a “RaceStudio 3” app is left over, drag it from Applications to the Trash." buttons {"OK"} default button 1 with title "Uninstall RaceStudio 3" with icon caution
		return
	end try

	-- Read the real telemetry folder the installer recorded (DATA="…" in uninstall.sh), so the
	-- dialogs name the actual location instead of guessing ~/Documents/AIM_SPORT.
	set dataDir to ""
	try
		set dataDir to do shell script "grep '^DATA=' " & quoted form of uninst & " | head -1 | sed 's/^DATA=\"//; s/\"$//'"
	end try
	if dataDir is "" then set dataDir to (POSIX path of (path to home folder)) & "AIM_SPORT"
	set dataDisp to tildify(dataDir)

	set b to button returned of (display dialog "Remove RaceStudio 3 from this Mac?" & return & return & "This stops RaceStudio 3 and removes everything in /Applications/AiM (the app, the engine, and the helpers). Your telemetry in " & dataDisp & " is kept unless you choose to remove it." buttons {"Cancel", "Remove everything", "Remove (keep my data)"} default button "Remove (keep my data)" with title "Uninstall RaceStudio 3" with icon caution)
	if b is "Cancel" then return

	-- Unregister the WiFi bridge daemon in the USER context (SMAppService records are per-user),
	-- BEFORE the root step deletes RaceStudio 3.app — otherwise a stale "RaceStudio 3" entry can
	-- linger in Login Items pointing at a deleted app. Best-effort; uninstall.sh also boots it out
	-- as root. The control tool lives in the sibling RaceStudio 3.app.
	try
		set parentP to do shell script "dirname " & quoted form of (text 1 thru -2 of (POSIX path of (path to me)))
		set rs3ctl to parentP & "/RaceStudio 3.app/Contents/MacOS/aim-bridge-ctl"
		do shell script "test -x " & quoted form of rs3ctl & " && " & quoted form of rs3ctl & " unregister >/dev/null 2>&1 || true"
	end try

	set extra to ""
	if b is "Remove everything" then
		set c to button returned of (display dialog "Also permanently delete your telemetry in " & dataDisp & "?" & return & return & "This can't be undone." buttons {"Keep my data", "Delete my data"} default button "Keep my data" with title "Delete telemetry?" with icon stop)
		if c is "Delete my data" then set extra to " --remove-data"
	end if

	-- If we live in /Applications/AiM, deleting our sibling .app bundles needs root: since macOS 13
	-- the App Management privacy gate blocks an unprivileged process from removing apps in
	-- /Applications (the rm fails with "Operation not permitted", silently). Run as root there so the
	-- whole folder — apps, engine, bottle — actually goes. The ~/Applications fallback needs no prompt.
	set needAdmin to ((POSIX path of (path to me)) starts with "/Applications/")
	try
		if needAdmin then
			do shell script "bash " & quoted form of uninst & extra with administrator privileges
		else
			do shell script "bash " & quoted form of uninst & extra
		end if
	on error errMsg number errNum
		if errNum is -128 then return -- user cancelled the admin prompt
		display dialog "Couldn't finish uninstalling:" & return & return & errMsg buttons {"OK"} default button 1 with title "Uninstall problem" with icon stop
		return
	end try

	set msg to "RaceStudio 3 has been removed — the app, the engine, and the helper apps are gone."
	if extra is "" then set msg to msg & return & return & "Your telemetry in " & dataDisp & " was kept."
	display dialog msg buttons {"OK"} default button 1 with title "Uninstalled" with icon note
end run
