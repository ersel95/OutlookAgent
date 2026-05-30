-- delete_email.applescript MESSAGE_ID
-- Moves the message to Deleted Items (Outlook's default delete behavior).
on run argv
	if (count of argv) < 1 then error "missing id"
	set mId to (item 1 of argv) as integer
	tell application "Microsoft Outlook"
		set m to message id mId
		delete m
	end tell
	return "OK"
end run
