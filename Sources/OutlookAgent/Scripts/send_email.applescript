-- send_email.applescript SUBJECT_FILE BODY_FILE TO_LIST [CC_LIST]
-- Creates a NEW outgoing message (fresh — not a reply) and sends it immediately
-- via Outlook for Mac (Classic). TO_LIST and CC_LIST are semicolon-separated
-- email addresses. Returns the Outlook message id on success.
on run argv
	if (count of argv) < 3 then error "usage: SUBJECT_FILE BODY_FILE TO_LIST [CC_LIST]"
	set subjFile to (item 1 of argv) as string
	set bodyFile to (item 2 of argv) as string
	set toListRaw to (item 3 of argv) as string
	set ccListRaw to ""
	if (count of argv) ≥ 4 then set ccListRaw to ((item 4 of argv) as string)

	set subjText to do shell script "/bin/cat " & quoted form of subjFile
	set bodyText to do shell script "/bin/cat " & quoted form of bodyFile

	set toAddrs to my splitSemis(toListRaw)
	set ccAddrs to my splitSemis(ccListRaw)
	if (count of toAddrs) is 0 then error "send_email: en az bir alıcı gerekli"

	tell application "Microsoft Outlook"
		set newMsg to make new outgoing message with properties {subject:subjText, plain text content:bodyText}

		repeat with addr in toAddrs
			set a to (addr as string)
			tell newMsg
				make new to recipient with properties {email address:{address:a}}
			end tell
		end repeat

		repeat with addr in ccAddrs
			set a to (addr as string)
			if a is not "" then
				tell newMsg
					make new cc recipient with properties {email address:{address:a}}
				end tell
			end if
		end repeat

		send newMsg

		set evID to ""
		try
			set evID to ((id of newMsg) as string)
		end try
		return evID
	end tell
end run

on splitSemis(s)
	set out to {}
	if s is missing value or s is "" then return out
	set old to AppleScript's text item delimiters
	set AppleScript's text item delimiters to ";"
	set parts to text items of s
	set AppleScript's text item delimiters to old
	repeat with p in parts
		set t to my trim(p as string)
		if t is not "" then set end of out to t
	end repeat
	return out
end splitSemis

on trim(s)
	if s is missing value then return ""
	set t to s as string
	repeat while t starts with " "
		if (length of t) ≤ 1 then
			set t to ""
			exit repeat
		end if
		set t to text 2 thru -1 of t
	end repeat
	repeat while t ends with " "
		if (length of t) ≤ 1 then
			set t to ""
			exit repeat
		end if
		set t to text 1 thru -2 of t
	end repeat
	return t
end trim
