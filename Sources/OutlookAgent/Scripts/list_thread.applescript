-- list_thread.applescript CONVERSATION_ID [SUBJECT_KEY]
-- Walks every mail folder of the default Outlook account and collects messages
-- that share the conversation id, OR (fallback) match the normalized subject.
-- Output: base64(records). Records sep RS (0x1E), fields sep US (0x1F).
-- Per record: id, folder, isoDate, fromName, fromAddr, toAddrs, ccAddrs, subject, body, isRead, hasAttachments, attachmentNames
on run argv
	if (count of argv) < 1 then error "missing conversation id"
	set convId to 0
	try
		set convId to (item 1 of argv) as integer
	end try
	set subjectKey to ""
	if (count of argv) ≥ 2 then set subjectKey to (item 2 of argv) as string

	set rs to character id 30
	set fs to character id 31
	set raw to ""
	set seenIds to {}

	tell application "Microsoft Outlook"
		set acc to default account
		set folderList to mail folders of acc

		-- Pass 1: by conversation id (fast, exact)
		if convId is not 0 then
			repeat with f in folderList
				try
					set hits to (messages of f whose conversation id is convId)
					repeat with m in hits
						set mid to id of m as string
						if seenIds does not contain mid then
							set end of seenIds to mid
							set raw to raw & my emit(m, name of f, fs) & rs
						end if
					end repeat
				end try
			end repeat
		end if

		-- Pass 2: by normalized subject (fallback for messages where
		-- conversation id is missing, e.g. some Sent Items)
		if subjectKey is not "" then
			repeat with f in folderList
				try
					set fname to name of f
					-- Skip noisy folders (deleted, junk) for subject-fallback
					if fname does not contain "Silinmiş" and fname does not contain "Deleted" ¬
						and fname does not contain "Gereksiz" and fname does not contain "Junk" then
						set candidates to (messages of f whose subject contains subjectKey)
						repeat with m in candidates
							set mid to id of m as string
							if seenIds does not contain mid then
								-- Stricter check: subject normalize equals
								set msubj to ""
								try
									set msubj to subject of m
								end try
								if my normalizeSubject(msubj) is subjectKey then
									set end of seenIds to mid
									set raw to raw & my emit(m, fname, fs) & rs
								end if
							end if
						end repeat
					end if
				end try
			end repeat
		end if
	end tell

	set encoded to do shell script "printf %s " & quoted form of raw & " | base64"
	return encoded
end run

-- ---------- helpers ----------

on emit(m, fname, fs)
	tell application "Microsoft Outlook"
		set mId to id of m as string
		set d to my isoDate(time received of m)
		set isRead to (is read of m) as string

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

		set rsChar to character id 30
		set fromName to my zap(fromName, rsChar, " ")
		set fromName to my zap(fromName, fs, " ")
		set subj to my zap(subj, rsChar, " ")
		set subj to my zap(subj, fs, " ")

		set imgPaths to my dumpImageAttachments(m, mId)

		set mAcctId to ""
		set mAcctName to ""
		try
			set mAcct to account of m
			try
				set mAcctId to (id of mAcct) as string
			end try
			try
				set mAcctName to (name of mAcct) as string
			end try
		end try
		set mAcctName to my zap(mAcctName, rsChar, " ")
		set mAcctName to my zap(mAcctName, fs, " ")

		return mId & fs & fname & fs & d & fs & fromName & fs & fromAddr & fs & toList & fs & ccList & fs & subj & fs & body & fs & isRead & fs & hasAttach & fs & attachNames & fs & imgPaths & fs & mAcctId & fs & mAcctName
	end tell
end emit

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

on normalizeSubject(s)
	set t to my trim(s)
	-- strip leading "Re:", "Fwd:", "Fw:", "Yanıtla:", "İlet:" (case insensitive, repeat)
	set lcPrefixes to {"re:", "re :", "fw:", "fwd:", "yanıtla:", "ilet:", "ilt:", "iletilen:"}
	repeat
		set lower to my lc(t)
		set stripped to false
		repeat with p in lcPrefixes
			if lower starts with (p as string) then
				set t to text ((length of (p as string)) + 1) thru -1 of t
				set t to my trim(t)
				set stripped to true
				exit repeat
			end if
		end repeat
		if not stripped then exit repeat
	end repeat
	return my lc(t)
end normalizeSubject

on lc(s)
	return do shell script "printf %s " & quoted form of s & " | tr '[:upper:]' '[:lower:]'"
end lc

on trim(s)
	if s is missing value then return ""
	set s to s as string
	repeat while s starts with " " or s starts with tab
		if (length of s) ≤ 1 then return ""
		set s to text 2 thru -1 of s
	end repeat
	repeat while s ends with " " or s ends with tab
		if (length of s) ≤ 1 then return ""
		set s to text 1 thru -2 of s
	end repeat
	return s
end trim

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

on zap(theText, badChar, replacement)
	set AppleScript's text item delimiters to badChar
	set parts to text items of theText
	set AppleScript's text item delimiters to replacement
	set out to parts as string
	set AppleScript's text item delimiters to ""
	return out
end zap
