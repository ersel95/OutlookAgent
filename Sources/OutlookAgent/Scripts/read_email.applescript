-- read_email.applescript MESSAGE_ID
-- Outputs base64(payload). Fields separated by US (0x1F):
-- id, isRead, date, fromName, fromAddr, toAddrs (semicolon-joined), ccAddrs, subject, fullPlainText, hasAttachments, attachmentNames, conversationId
on run argv
	if (count of argv) < 1 then error "missing id"
	set mId to (item 1 of argv) as integer
	set fs to character id 31

	tell application "Microsoft Outlook"
		set m to message id mId
		set fromName to ""
		set fromAddr to ""
		try
			set sndr to sender of m
			try
				set fromName to name of sndr
			end try
			try
				set fromAddr to address of sndr
			end try
		end try

		set toList to ""
		try
			repeat with r in (to recipients of m)
				try
					set toList to toList & (address of (email address of r)) & ";"
				end try
			end repeat
		end try

		set ccList to ""
		try
			repeat with r in (cc recipients of m)
				try
					set ccList to ccList & (address of (email address of r)) & ";"
				end try
			end repeat
		end try

		set subj to ""
		try
			set subj to subject of m
		end try

		set body to ""
		try
			set body to plain text content of m
		end try

		set attachNames to ""
		set attachCount to 0
		try
			set attachCount to count of attachments of m
			repeat with a in attachments of m
				try
					set attachNames to attachNames & (name of a) & ";"
				end try
			end repeat
		end try
		set hasAttach to "false"
		if attachCount > 0 then set hasAttach to "true"

		set d to my isoDate(time received of m)
		set isRead to (is read of m) as string

		set convId to ""
		try
			set convId to (id of conversation of m) as string
		on error
			try
				set convId to (conversation id of m) as string
			end try
		end try

		set imgPaths to my dumpImageAttachments(m, mId as string)

		set raw to (mId as string) & fs & isRead & fs & d & fs & fromName & fs & fromAddr & fs & toList & fs & ccList & fs & subj & fs & body & fs & hasAttach & fs & attachNames & fs & convId & fs & imgPaths
	end tell

	set encoded to do shell script "printf %s " & quoted form of raw & " | base64"
	return encoded
end run

on dumpImageAttachments(m, msgId)
	set cacheBase to (do shell script "echo $HOME") & "/Library/Caches/OutlookAgent/attachments"
	set msgDir to cacheBase & "/" & msgId
	do shell script "mkdir -p " & quoted form of msgDir
	set pathMap to ""
	set imgExts to {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}
	tell application "Microsoft Outlook"
		try
			repeat with a in attachments of m
				try
					set aname to name of a
					set lower to do shell script "printf %s " & quoted form of aname & " | tr '[:upper:]' '[:lower:]'"
					set isImg to false
					repeat with ext in imgExts
						if lower ends with (ext as string) then
							set isImg to true
							exit repeat
						end if
					end repeat
					if isImg then
						set targetPath to msgDir & "/" & aname
						set existsCheck to do shell script "[ -s " & quoted form of targetPath & " ] && echo y || echo n"
						if existsCheck is "n" then
							try
								save a in (POSIX file targetPath)
							end try
						end if
						set pathMap to pathMap & aname & "::" & targetPath & "||"
					end if
				end try
			end repeat
		end try
	end tell
	return pathMap
end dumpImageAttachments

on isoDate(d)
	set yy to (year of d) as integer
	set mm to (month of d) as integer
	set dd to (day of d) as integer
	set hr to (hours of d) as integer
	set mn to (minutes of d) as integer
	set sc to (seconds of d) as integer
	return (yy as string) & "-" & my pad2(mm) & "-" & my pad2(dd) & " " & my pad2(hr) & ":" & my pad2(mn) & ":" & my pad2(sc)
end isoDate

on pad2(n)
	if n < 10 then return "0" & (n as string)
	return (n as string)
end pad2
