-- create_calendar_event.applescript SUBJECT START_ISO END_ISO LOCATION BODY_FILE [ATTENDEES] [TIMEZONE_ID]
-- ATTENDEES: semicolon-separated email addresses
-- ISO format: "yyyy-MM-dd HH:mm:ss" (local time, parsed via AS calendar arithmetic)
-- Creates a calendar event in the user's default Outlook calendar and opens it
-- so the user can review/Send. Returns the new event id (string) on success.
on run argv
	if (count of argv) < 5 then error "usage: SUBJECT START END LOCATION BODY_FILE [ATTENDEES] [TZ]"
	set theSubject to (item 1 of argv) as string
	set startISO to (item 2 of argv) as string
	set endISO to (item 3 of argv) as string
	set theLocation to (item 4 of argv) as string
	set bodyPath to (item 5 of argv) as string
	set attendArg to ""
	if (count of argv) ≥ 6 then set attendArg to (item 6 of argv) as string
	-- TZ id reserved for future use (item 7)

	set bodyText to ""
	try
		set bodyText to do shell script "/bin/cat " & quoted form of bodyPath
	end try

	set startDate to my dateFromISO(startISO)
	set endDate to my dateFromISO(endISO)

	tell application "Microsoft Outlook"
		set newEvt to make new calendar event with properties ¬
			{subject:theSubject, start time:startDate, end time:endDate, ¬
				location:theLocation, content:bodyText}

		-- Add attendees (best-effort; Outlook may reject non-meeting events)
		if attendArg is not "" then
			set AppleScript's text item delimiters to ";"
			set addrs to text items of attendArg
			set AppleScript's text item delimiters to ""
			repeat with a in addrs
				set addr to (a as string)
				if addr is not "" then
					try
						tell newEvt
							make new required attendee with properties ¬
								{email address:{address:addr}}
						end tell
					end try
				end if
			end repeat
		end if

		open newEvt
		activate

		set evId to ""
		try
			set evId to id of newEvt as string
		end try
		if evId is "" then return "OK"
		return evId
	end tell
end run

on dateFromISO(s)
	set d to (current date)
	try
		set d's year to (text 1 thru 4 of s) as integer
		set d's month to (text 6 thru 7 of s) as integer
		set d's day to (text 9 thru 10 of s) as integer
		set d's hours to (text 12 thru 13 of s) as integer
		set d's minutes to (text 15 thru 16 of s) as integer
		set d's seconds to (text 18 thru 19 of s) as integer
	end try
	return d
end dateFromISO
