-- list_accounts.applescript
-- Outputs base64(payload). Records sep RS (0x1E), fields sep FS (0x1F).
-- Per record: accountId, accountType (exchange|imap|pop), accountName, primaryEmail
--
-- Outlook for Mac (Classic) dictionary; exchange / imap / pop accounts ayrı
-- collection olarak iterate edilir. Bazı property'ler (email address vs.) Outlook
-- sürümleri arasında değişir; her erişim try ile sarılır.
on run argv
	set rs to character id 30
	set fs to character id 31
	set raw to ""

	tell application "Microsoft Outlook"
		-- Exchange
		try
			set xs to exchange accounts
			repeat with a in xs
				set raw to raw & my dumpAccount(a, "exchange", fs, rs)
			end repeat
		end try
		-- IMAP
		try
			set is_ to imap accounts
			repeat with a in is_
				set raw to raw & my dumpAccount(a, "imap", fs, rs)
			end repeat
		end try
		-- POP
		try
			set ps to pop accounts
			repeat with a in ps
				set raw to raw & my dumpAccount(a, "pop", fs, rs)
			end repeat
		end try
	end tell

	set encoded to do shell script "printf %s " & quoted form of raw & " | base64"
	return encoded
end run

on dumpAccount(a, kindStr, fs, rs)
	set rs2 to rs
	set fs2 to fs
	set acctId to ""
	set acctName to ""
	set primary to ""

	tell application "Microsoft Outlook"
		try
			set acctId to (id of a) as string
		end try
		try
			set acctName to (name of a) as string
		end try
		-- Primary email — exchange accounts have `email address`,
		-- IMAP/POP also typically expose `email address`. Some versions
		-- expose only `user name` or `account name`.
		try
			set primary to (email address of a) as string
		end try
		if primary is "" then
			try
				set primary to (user name of a) as string
			end try
		end if
		if primary is "" then
			-- Some dictionaries expose `email addresses` (list)
			try
				set emList to email addresses of a
				if (count of emList) ≥ 1 then
					set primary to (item 1 of emList) as string
				end if
			end try
		end if
	end tell

	if acctId is "" then return ""

	set acctName to my zap(acctName, rs2, " ")
	set acctName to my zap(acctName, fs2, " ")
	set primary to my zap(primary, rs2, " ")
	set primary to my zap(primary, fs2, " ")

	return acctId & fs2 & kindStr & fs2 & acctName & fs2 & primary & rs2
end dumpAccount

on zap(theText, badChar, replacement)
	if theText is missing value then return ""
	set AppleScript's text item delimiters to badChar
	set parts to text items of theText
	set AppleScript's text item delimiters to replacement
	set out to parts as string
	set AppleScript's text item delimiters to ""
	return out
end zap
