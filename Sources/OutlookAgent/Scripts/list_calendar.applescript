-- list_calendar.applescript START_OFFSET_DAYS END_OFFSET_DAYS
-- Outputs base64(payload). Records sep RS (0x1E), fields sep US (0x1F).
-- Per record: id, calName, subj, startISO, endISO, allDay, location, organizerName, organizerEmail,
--             requiredAttendees (name||addr;;), optionalAttendees, ownResponse, body, hasReminder, isRecurring
on run argv
	set startOffset to 0
	set endOffset to 7
	if (count of argv) ≥ 1 then set startOffset to (item 1 of argv) as integer
	if (count of argv) ≥ 2 then set endOffset to (item 2 of argv) as integer

	set rs to character id 30
	set fs to character id 31
	set raw to ""

	set today to current date
	set today's hours to 0
	set today's minutes to 0
	set today's seconds to 0
	set startD to today + (startOffset * days)
	set endD to today + ((endOffset + 1) * days) - 1  -- inclusive of last day

	tell application "Microsoft Outlook"
		try
			set calsList to calendars
		on error
			return "OA_NO_CALENDARS"
		end try

		repeat with c in calsList
			set calName to ""
			try
				set calName to name of c
			end try
			-- Calendar → owning account (best-effort; bazı versiyonlarda yok)
			set calAcctId to ""
			set calAcctName to ""
			try
				set calAcct to account of c
				try
					set calAcctId to (id of calAcct) as string
				end try
				try
					set calAcctName to (name of calAcct) as string
				end try
			end try
			set hits to {}
			try
				set hits to (every calendar event of c whose start time ≥ startD and start time ≤ endD)
			on error
				try
					-- some accounts disallow `every … whose`; fall back to enumerate
					set allEvts to calendar events of c
					repeat with e in allEvts
						try
							set evST to start time of e
							if evST ≥ startD and evST ≤ endD then set end of hits to e
						end try
					end repeat
				end try
			end try

			repeat with e in hits
				try
					set evId to ""
					try
						set evId to id of e as string
					end try
					if evId is "" then
						-- event without id is not addressable; skip
					else
						set evSubj to ""
						try
							set evSubj to subject of e
						end try
						set evLoc to ""
						try
							set evLoc to location of e
						end try
						set evStart to my isoDate(start time of e)
						set evEnd to ""
						try
							set evEnd to my isoDate(end time of e)
						end try
						set evAllDay to "false"
						try
							if (all day flag of e) then set evAllDay to "true"
						end try
						set evBody to ""
						try
							set evBody to plain text content of e
						end try
						-- reminder/recurring: dictionary terms collide with AS
						-- reserved keywords; not exposed to Swift (defaulted false).
						set evHasReminder to "false"
						set evRecurring to "false"

						-- Organizer
						set orgName to ""
						set orgAddr to ""
						try
							set org to organizer of e
							try
								set orgName to name of org
							end try
							try
								set orgAddr to address of org
							end try
						end try

						-- Attendees
						set reqList to my dumpAttendees(e, true)
						set optList to my dumpAttendees(e, false)

						-- Own response status: derived later in Swift from attendee list
						set ownResp to "none"
						if orgAddr is not "" and orgAddr contains "agora" then
							set ownResp to "organizer"
						end if

						-- sanitize separators
						set evSubj to my zap(evSubj, rs, " ")
						set evSubj to my zap(evSubj, fs, " ")
						set evLoc to my zap(evLoc, rs, " ")
						set evLoc to my zap(evLoc, fs, " ")
						set evBody to my zap(evBody, rs, " ")
						set evBody to my zap(evBody, fs, " ")
						set orgName to my zap(orgName, rs, " ")
						set orgName to my zap(orgName, fs, " ")
						set calName to my zap(calName, rs, " ")
						set calName to my zap(calName, fs, " ")
						set calAcctName to my zap(calAcctName, rs, " ")
						set calAcctName to my zap(calAcctName, fs, " ")

						-- Event-level account (yedek, calendar verisi boşsa)
						set evAcctId to calAcctId
						set evAcctName to calAcctName
						if evAcctId is "" then
							try
								set evAcct to account of e
								try
									set evAcctId to (id of evAcct) as string
								end try
								try
									set evAcctName to (name of evAcct) as string
								end try
							end try
						end if
						set evAcctName to my zap(evAcctName, rs, " ")
						set evAcctName to my zap(evAcctName, fs, " ")

						set raw to raw & evId & fs & calName & fs & evSubj & fs & evStart & fs & evEnd & fs & evAllDay & fs & evLoc & fs & orgName & fs & orgAddr & fs & reqList & fs & optList & fs & ownResp & fs & evBody & fs & evHasReminder & fs & evRecurring & fs & evAcctId & fs & evAcctName & rs
					end if
				end try
			end repeat
		end repeat
	end tell

	set encoded to do shell script "printf %s " & quoted form of raw & " | base64"
	return encoded
end run

-- Returns "name||address;;name||address;;..."
on dumpAttendees(e, isRequired)
	set out to ""
	tell application "Microsoft Outlook"
		try
			if isRequired then
				set people to required attendees of e
			else
				set people to optional attendees of e
			end if
		on error
			return ""
		end try
		repeat with att in people
			set aName to ""
			set aAddr to ""
			set aResp to "none"
			try
				set ea to email address of att
				try
					set aName to name of ea
				end try
				try
					set aAddr to address of ea
				end try
			on error
				try
					set aName to name of att
				end try
				try
					set aAddr to address of att
				end try
			end try
			-- response status of attendee: dictionary term not always parseable;
			-- default to "none" and let downstream code show no badge.
			if aAddr is not "" then
				set out to out & aName & "||" & aAddr & "||" & aResp & ";;"
			end if
		end repeat
	end tell
	return out
end dumpAttendees

on responseString(r)
	-- AppleScript enum constants from Outlook dictionary:
	-- 'rspn' / 'rsac' / 'rstv' / 'rsdl' / etc — but easier to coerce to string
	set s to ""
	try
		set s to r as string
	end try
	if s is "" then return "none"
	if s contains "accept" then return "accepted"
	if s contains "tentat" then return "tentative"
	if s contains "decl" then return "declined"
	if s contains "respond" then return "responded"
	if s contains "organiz" then return "organizer"
	if s contains "none" then return "none"
	return s
end responseString

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
	if theText is missing value then return ""
	set AppleScript's text item delimiters to badChar
	set parts to text items of theText
	set AppleScript's text item delimiters to replacement
	set out to parts as string
	set AppleScript's text item delimiters to ""
	return out
end zap
