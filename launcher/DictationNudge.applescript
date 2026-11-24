-- Dictation Nudge launcher.
-- Running this app opens the Dictation Nudge card. It does nothing else:
-- /usr/bin/open hands the URL to Hammerspoon (starting it if needed), and
-- the module's URL handler shows the card.
on run
	do shell script "/usr/bin/open 'hammerspoon://dictationNudgeSettings'"
end run
