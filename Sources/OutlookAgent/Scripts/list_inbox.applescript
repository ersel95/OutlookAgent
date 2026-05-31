-- list_inbox.applescript [LIMIT] [UNREAD_ONLY] [ACCOUNT_ID]
-- Outputs base64(payload). Each record: id, isRead, isoDate, fromName, fromAddr,
--                                       subject, preview, hasAttachments,
--                                       accountId, accountName
--
-- ACCOUNT_ID:
--   - boş ("") veya "all": tüm hesapların inbox'ları (Outlook'un global `inbox`
--     unified collection'ı kullanılır; her mail'in account property'sinden id
--     türetilir → Swift filtreler).
--   - belirli bir id: yalnızca o account'un inbox'ı (id eşleşmeyenler atlanır).
on run argv
	set theLimit to 30
	set unreadOnly to false
	set acctFilter to ""
	if (count of argv) ≥ 1 then set theLimit to (item 1 of argv) as integer
	if (count of argv) ≥ 2 then
		if ((item 2 of argv) as string) is "true" then set unreadOnly to true
	end if
	if (count of argv) ≥ 3 then set acctFilter to ((item 3 of argv) as string)
	if acctFilter is "all" then set acctFilter to ""

	set rs to character id 30
	set fs to character id 31
	set raw to ""

	tell application "Microsoft Outlook"
		set inb to inbox
		set total to count of messages of inb
		if total ≤ 0 then
			return "OA_EMPTY_INBOX"
		end if
		-- Account filtre varsa daha fazla mail tara (filtrelemeden sonra azalabilir)
		set fetchCount to theLimit
		if acctFilter is not "" then
			set fetchCount to (theLimit * 4)
			if fetchCount > total then set fetchCount to total
		else
			if fetchCount > total then set fetchCount to total
		end if
		set msgs to messages 1 thru fetchCount of inb
		set emitted to 0
		repeat with m in msgs
			try
				if (emitted ≥ theLimit) then exit repeat
				if unreadOnly and (is read of m) then
					-- skip
				else
					-- Account info
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

					if acctFilter is not "" and mAcctId is not acctFilter then
						-- account filter active, skip non-matching
					else
						set mId to id of m as string
						set mRead to (is read of m) as string
						set mTime to my isoDate(time received of m)
						set mSubj to ""
						try
							set mSubj to subject of m
						end try
						set mFromName to ""
						set mFromAddr to ""
						try
							set sndr to sender of m
							try
								set mFromName to name of sndr
							end try
							try
								set mFromAddr to address of sndr
							end try
						end try
						set mPreview to ""
						try
							set fullText to plain text content of m
							if (length of fullText) > 400 then
								set mPreview to text 1 thru 400 of fullText
							else
								set mPreview to fullText
							end if
						end try
						set mAttach to "false"
						try
							if (count of attachments of m) > 0 then set mAttach to "true"
						end try

						set mSubj to my zap(mSubj, rs, " ")
						set mSubj to my zap(mSubj, fs, " ")
						set mPreview to my zap(mPreview, rs, " ")
						set mPreview to my zap(mPreview, fs, " ")
						set mFromName to my zap(mFromName, rs, " ")
						set mFromName to my zap(mFromName, fs, " ")
						set mAcctName to my zap(mAcctName, rs, " ")
						set mAcctName to my zap(mAcctName, fs, " ")

						set raw to raw & mId & fs & mRead & fs & mTime & fs & mFromName & fs & mFromAddr & fs & mSubj & fs & mPreview & fs & mAttach & fs & mAcctId & fs & mAcctName & rs
						set emitted to emitted + 1
					end if
				end if
			end try
		end repeat
	end tell

	set encoded to do shell script "printf %s " & quoted form of raw & " | base64"
	return encoded
end run

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
