-- mark_read.applescript MESSAGE_ID [READ_STATE]
on run argv
	if (count of argv) < 1 then error "missing id"
	set mId to (item 1 of argv) as integer
	set newState to true
	if (count of argv) ≥ 2 then
		if ((item 2 of argv) as string) is "false" then set newState to false
	end if
	tell application "Microsoft Outlook"
		set m to message id mId
		set is read of m to newState
	end tell
	return "OK"
end run
