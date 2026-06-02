-- RaceStudio 3 (launcher) — runs the installed launch script, which exports the Wine env and
-- starts RS3 detached (no Terminal, no ~/.wine). launch.sh shows its own "not installed" dialog.
on run
	set lp to (POSIX path of (path to application support folder from user domain)) & "RaceStudio3/bin/launch.sh"
	try
		do shell script "bash " & quoted form of lp
	on error
		display dialog "RaceStudio 3 isn't installed yet. Please run the installer first." buttons {"OK"} default button 1 with icon caution
	end try
end run
