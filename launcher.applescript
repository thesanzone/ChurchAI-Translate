-- Source for "Church AI Translation.app". To rebuild the app after editing:
--   osacompile -o "Church AI Translation.app" launcher.applescript
--   codesign --force --deep -s - "Church AI Translation.app"
--
-- If everything is installed, opens the translator window directly (no Terminal).
-- Otherwise opens Terminal and runs first-time setup.

set appPath to POSIX path of (path to me)
set scriptDir to do shell script "dirname " & quoted form of appPath
set py to scriptDir & "/venv/bin/python3"

set isReady to true
try
	do shell script quoted form of py & " -c \"import importlib.util as u, sys; sys.exit(0 if all(u.find_spec(m) for m in ['PySide6','sounddevice','faster_whisper','transformers','piper']) else 1)\""
on error
	set isReady to false
end try

if isReady then
	do shell script "mkdir -p ~/ChurchAI/logs; cd " & quoted form of scriptDir & " && nohup ./start_translation.sh > ~/ChurchAI/logs/app.log 2>&1 &"
else
	tell application "Terminal"
		activate
		do script "cd " & quoted form of scriptDir & " && ./start_translation.sh"
	end tell
end if
