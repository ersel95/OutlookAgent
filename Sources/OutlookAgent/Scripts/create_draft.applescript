-- create_draft.applescript MESSAGE_ID BODY_FILE_PATH [REPLY_ALL] [USER_EMAIL]
-- Creates a new outgoing message that replies to the given message.
-- The Outlook "reply" verb was removed in newer dictionary versions; we
-- build the draft manually with `make new outgoing message`.
-- Returns "OK" on success.
on run argv
	if (count of argv) < 2 then error "usage: MESSAGE_ID BODY_FILE [REPLY_ALL] [USER_EMAIL]"
	set mId to (item 1 of argv) as integer
	set bodyPath to (item 2 of argv) as string
	set replyAll to false
	if (count of argv) ≥ 3 then
		if ((item 3 of argv) as string) is "true" then set replyAll to true
	end if
	set userEmail to ""
	if (count of argv) ≥ 4 then set userEmail to ((item 4 of argv) as string)

	set bodyText to do shell script "/bin/cat " & quoted form of bodyPath

	tell application "Microsoft Outlook"
		set origMsg to message id mId

		set origSubj to ""
		try
			set origSubj to subject of origMsg
		end try

		set origPlain to ""
		try
			set origPlain to plain text content of origMsg
		end try

		set origDate to ""
		try
			set origDate to (time received of origMsg) as string
		end try

		set origFromName to ""
		set origFromAddr to ""
		try
			set sndr to sender of origMsg
			try
				set origFromName to name of sndr
			end try
			try
				set origFromAddr to address of sndr
			end try
		end try

		-- "Re:" prefix unless already present
		set newSubj to origSubj
		if not ((origSubj starts with "Re:") or (origSubj starts with "RE:") or (origSubj starts with "re:")) then
			set newSubj to "Re: " & origSubj
		end if

		-- Quoted history (Outlook-style block)
		set sep to "________________________________________"
		set quotedBlock to return & return & sep & return & ¬
			"From: " & origFromName & " <" & origFromAddr & ">" & return & ¬
			"Sent: " & origDate & return & ¬
			"Subject: " & origSubj & return & return & ¬
			origPlain

		set fullBody to bodyText & quotedBlock

		set newMsg to make new outgoing message with properties {subject:newSubj, plain text content:fullBody}

		-- Build de-duplicated email sets (lowercase) so we don't add the user
		-- or the same address twice across To/Cc.
		set userLc to my lc(userEmail)
		set senderLc to my lc(origFromAddr)
		set seenAddrs to {senderLc, userLc}

		-- Primary "To": original sender
		if origFromAddr is not "" then
			tell newMsg
				make new to recipient with properties {email address:{address:origFromAddr, name:origFromName}}
			end tell
		end if

		-- Reply-all: original To → To (minus sender + minus self),
		--           original Cc → Cc (minus self).
		--           Bcc is intentionally never copied (we can't see it on incoming mail).
		if replyAll then
			try
				repeat with r in (to recipients of origMsg)
					try
						set rEA to email address of r
						set rAddr to ""
						set rName to ""
						try
							set rAddr to address of rEA
						end try
						try
							set rName to name of rEA
						end try
						set rLc to my lc(rAddr)
						if rAddr is not "" and seenAddrs does not contain rLc then
							set end of seenAddrs to rLc
							tell newMsg
								make new to recipient with properties {email address:{address:rAddr, name:rName}}
							end tell
						end if
					end try
				end repeat
			end try
			try
				repeat with r in (cc recipients of origMsg)
					try
						set rEA to email address of r
						set rAddr to ""
						set rName to ""
						try
							set rAddr to address of rEA
						end try
						try
							set rName to name of rEA
						end try
						set rLc to my lc(rAddr)
						if rAddr is not "" and seenAddrs does not contain rLc then
							set end of seenAddrs to rLc
							tell newMsg
								make new cc recipient with properties {email address:{address:rAddr, name:rName}}
							end tell
						end if
					end try
				end repeat
			end try
		end if

		open newMsg
		activate
	end tell
	return "OK"
end run

on lc(s)
	if s is missing value then return ""
	try
		return do shell script "printf %s " & quoted form of (s as string) & " | tr '[:upper:]' '[:lower:]'"
	on error
		return s as string
	end try
end lc
