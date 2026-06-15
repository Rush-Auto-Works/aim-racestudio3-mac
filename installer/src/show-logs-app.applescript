-- Show RaceStudio 3 Logs — a standalone app (installed into /Applications/AiM). Gathers the
-- current RaceStudio 3 logs into a dated folder on your Desktop and opens it in Finder, so you can
-- send them to whoever is helping you. The collector script (collect-logs.sh) is embedded in this
-- app's Resources. No setup required — it works even if RaceStudio 3 won't start.

on run
	set sh to scriptPath()
	try
		with timeout of 120 seconds
			do shell script "bash " & quoted form of sh & " 2>&1"
		end timeout
	on error errMsg
		display dialog "Couldn't collect the logs:" & return & return & errMsg buttons {"OK"} default button 1 with title "Show RaceStudio 3 Logs" with icon stop
	end try
end run

on scriptPath()
	return POSIX path of ((path to me as text) & "Contents:Resources:collect-logs.sh")
end scriptPath
