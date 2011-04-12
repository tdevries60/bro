##! The logging this script does is primarily focused on logging FTP commands
##! along with metadata.  For example, if files are transferred, the argument
##! will take on the full path that the client is at along with the requested 
##! file name.  
##! 
##! TODO:
##!  * Handle encrypted sessions correctly (get an example?)
##!  * Detect client software with CLNT command
##!  * Detect server software with initial 220 message
##!  * Detect client software with password given for anonymous users 
##!    (e.g. cyberduck@example.net)

@load functions
@load notice
@load software
@load ftp/utils-commands

module FTP;

redef enum Log::ID += { FTP };

redef enum Notice::Type += {
	## This indicates that a successful response to a "SITE EXEC" 
	## command/arg pair was seen.
	FTP_Site_Exec_Success,
};

export {
	type Tag: enum {
		UNKNOWN
	};
	
	type State: record {
		ts:               time    &log;
		id:               conn_id &log;
		user:             string  &log &default="<unknown>";
		password:         string  &log &optional;
		command:          string  &log &optional;
		arg:              string  &log &optional;
		mime_type:        string  &log &optional;
		mime_desc:        string  &log &optional;
		file_size:        count   &log &optional;
		reply_code:       count   &log &optional;
		reply_msg:        string  &log &optional;
		tags:             set[Tag] &log;
		
		## By setting the CWD to '/.', we can indicate that unless something
		## more concrete is discovered that the existing but unknown
		## directory is ok to use.
		cwd:                string &default="/.";
		cmdarg:             CmdArg &optional;
		pending_commands:   PendingCmds;
	};
	
	type ExpectedConn: record {
		host:    addr;
		state:   State;
	};
	
	## This record is to hold a parsed FTP reply code.  For example, for the 
	## 201 status code, the digits would be parsed as: x->2, y->0, z=>1.
	type ReplyCode: record {
		x: count;
		y: count;
		z: count;
	};

	# TODO: add this back in some form.  raise a notice again?
	#const excessive_filename_len = 250 &redef;
	#const excessive_filename_trunc_len = 32 &redef;

	## These are user IDs that can be considered "anonymous".
	const guest_ids = { "anonymous", "ftp", "guest" } &redef;
	
	## The list of commands that should have their command/response pairs logged.
	const logged_commands = {
		"APPE", "DELE", "RETR", "STOR", "STOU", "CLNT", "ACCT"
	} &redef;
	
	## This function splits FTP reply codes into the three constituent 
	global parse_ftp_reply_code: function(code: count): ReplyCode;

	global log_ftp: event(rec: State);
}

# Add the state tracking information variable to the connection record
redef record connection += {
	ftp: State &optional;
};

# Configure DPD
const ports = { 21/tcp } &redef;
redef capture_filters += { ["ftp"] = "port 21" };
redef dpd_config += { [ANALYZER_FTP] = [$ports = ports] };

# Establish the variable for tracking expected connections.
global ftp_data_expected: table[addr, port] of ExpectedConn &create_expire=5mins;

event bro_init()
	{
	Log::create_stream(FTP, [$columns=State, $ev=log_ftp]);
	}

# A set of commands where the argument can be expected to refer
# to a file or directory.
const file_cmds = {
	"APPE", "CWD", "DELE", "MKD", "RETR", "RMD", "RNFR", "RNTO",
	"STOR", "STOU", "REST", "SIZE", "MDTM",
};

# Commands that either display or change the current working directory.
const directory_cmds = {
	["CWD",  250],
	["CDUP", 200], # typo in RFC?
	["CDUP", 250], # as found in traces
	["PWD",  257],
	["XPWD", 257],
};

function parse_ftp_reply_code(code: count): ReplyCode
	{
	local a: ReplyCode;

	a$z = code % 10;

	code = code / 10;
	a$y = code % 10;

	code = code / 10;
	a$x = code % 10;

	return a;
	}

function set_ftp_session(c: connection)
	{
	if ( ! c?$ftp )
		{
		local s: State;
		s$ts=network_time();
		s$id=c$id;
		c$ftp=s;
		
		# Add a shim command so the server can respond with some init response.
		add_pending_cmd(c$ftp$pending_commands, "<init>", "");
		}
	}

function ftp_message(s: State)
	{
	# If it either has a tag associated with it (something detected)
	# or it's a deliberately logged command.
	if ( |s$tags| > 0 || (s?$cmdarg && s$cmdarg$cmd in logged_commands) )
		{
		if ( s?$password && to_lower(s$user) !in guest_ids )
			s$password = "<hidden>";
		
		local arg = s$cmdarg$arg;
		if ( s$cmdarg$cmd in file_cmds )
			arg = fmt("ftp://%s%s", s$id$resp_h, absolute_path(s$cwd, arg));
		
		s$ts=s$cmdarg$ts;
		s$command=s$cmdarg$cmd;
		s$arg=arg;
		
		# TODO: does the framework do this atomicly or do I need the copy?
		Log::write(FTP, copy(s));
		}
	
	# The MIME and file_size fields are specific to file transfer commands 
	# and may not be used in all commands so they need reset to "blank" 
	# values after logging.
	# TODO: change these to blank or remove the field when moving to the new
	#       logging framework
	s$mime_type="\\N";
	s$mime_desc="\\N";
	s$file_size=0;
	s$tags=set();
	}

event ftp_request(c: connection, command: string, arg: string) &priority=5
	{
	# TODO: find out if this issue is fixed with DPD
	# Command may contain garbage, e.g. if we're parsing something
	# which isn't ftp. Ignore this.
	#if ( is_string_binary(command) ) return;

	local id = c$id;
	set_ftp_session(c);

	# Write out the previous command when a new command is seen.
	# The downside here is that commands definitely aren't logged until the
	# next command is issued or the control session ends.  In practicality
	# this isn't an issue, but I suppose it could be a delay tactic for
	# attackers.
	if ( c$ftp?$cmdarg && c$ftp?$reply_code )
		{
		remove_pending_cmd(c$ftp$pending_commands, c$ftp$cmdarg);
		ftp_message(c$ftp);
		}
		
	# Queue up the new command and argument
	add_pending_cmd(c$ftp$pending_commands, command, arg);
	
	if ( command == "USER" )
		c$ftp$user = arg;
	
	else if ( command == "PASS" )
		c$ftp$password = arg;
	
	else if ( command == "PORT" || command == "EPRT" )
		{
		local data = (command == "PORT") ?
				parse_ftp_port(arg) : parse_eftp_port(arg);

		if ( data$valid )
			{
			local expected = [$host=id$resp_h, $state=c$ftp];
			ftp_data_expected[data$h, data$p] = expected;
			expect_connection(id$resp_h, data$h, data$p, ANALYZER_FILE, 5mins);
			}
		else
			{
			# TODO: raise a notice?  does anyone care?
			}
		}
	}


event ftp_reply(c: connection, code: count, msg: string, cont_resp: bool) &priority=5
	{
	# TODO: figure out what to do with continued FTP response (not used much)
	if ( cont_resp ) return;

	local id = c$id;
	set_ftp_session(c);
	
	c$ftp$cmdarg = get_pending_cmd(c$ftp$pending_commands, code, msg);
	
	c$ftp$reply_code = code;
	c$ftp$reply_msg = msg;
	
	# TODO: do some sort of generic clear text login processing here.
	local response_xyz = parse_ftp_reply_code(code);
	#if ( response_xyz$x == 2 &&  # successful
	#     session$cmdarg$cmd == "PASS" )
	#	do_ftp_login(c, session);

	if ( code == 150 && c$ftp$cmdarg$cmd == "RETR" )
		{
		local parts = split_all(msg, /\([0-9]+[[:blank:]]+/);
		if ( |parts| >= 3 )
			c$ftp$file_size = to_count(gsub(parts[2], /[^0-9]/, ""));
		}
	else if ( code == 213 && c$ftp$cmdarg$cmd == "SIZE" )
		{
		# NOTE: This isn't exactly the right thing to do here since the size
		#       on a different file could be checked, but the file size will
		#       be overwritten by the server response to the RETR command
		#       if that's given as well which would be more correct.
		c$ftp$file_size = to_count(msg);
		}
		
	# If a successful SITE EXEC command is executed, raise a notice.
	else if ( response_xyz$x == 2 &&
	          c$ftp$cmdarg$cmd == "SITE" && 
	          /[Ee][Xx][Ee][Cc]/ in c$ftp$cmdarg$arg )
		{
		NOTICE([$note=FTP_Site_Exec_Success, $conn=c,
		        $msg=fmt("%s %s", c$ftp$cmdarg$cmd, c$ftp$cmdarg$arg)]);
		}

	# PASV and EPSV processing
	else if ( (code == 227 || code == 229) &&
	     (c$ftp$cmdarg$cmd == "PASV" || c$ftp$cmdarg$cmd == "EPSV") )
		{
		local data = (code == 227) ? parse_ftp_pasv(msg) : parse_ftp_epsv(msg);
		
		if ( data$valid )
			{
			if ( code == 229 && data$h == 0.0.0.0 )
				data$h = id$resp_h;
			
			local expected = [$host=id$orig_h, $state=c$ftp];
			ftp_data_expected[data$h, data$p] = expected;
			expect_connection(id$orig_h, data$h, data$p, ANALYZER_FILE, 5mins);
			}
		else
			{
			# TODO: do something if there was a problem parsing the PASV message?
			}
		}

	if ( [c$ftp$cmdarg$cmd, code] in directory_cmds )
		{
		if ( c$ftp$cmdarg$cmd == "CWD" )
			c$ftp$cwd = build_full_path(c$ftp$cwd, c$ftp$cmdarg$arg);

		else if ( c$ftp$cmdarg$cmd == "CDUP" )
			c$ftp$cwd = cat(c$ftp$cwd, "/..");

		else if ( c$ftp$cmdarg$cmd == "PWD" || c$ftp$cmdarg$cmd == "XPWD" )
			c$ftp$cwd = extract_directory(msg);
		}
	
	# In case there are multiple commands queued, go ahead and remove the
	# command here and log because we can't do the normal processing pipeline 
	# to wait for a new command before logging the command/response pair.
	if ( |c$ftp$pending_commands| > 1 )
		{
		remove_pending_cmd(c$ftp$pending_commands, c$ftp$cmdarg);
		ftp_message(c$ftp);
		}
	}

# Use state remove event to cover connections terminated by RST.
event connection_state_remove(c: connection) &priority=-5
	{
	local id = c$id;
	if ( ! c?$ftp ) return;

	# NOTE: Only dealing with a single pending command here.
	#       Extra pending commands are ignored for now.
	if ( |c$ftp$pending_commands| > 0 )
		{
		c$ftp$cmdarg = pop_pending_cmd(c$ftp$pending_commands, 0, "<finish>");
		ftp_message(c$ftp);
		}
	}
	
#event expected_connection_seen(c: connection, a: count) &priority=1
#	{
#	local id = c$id;
#	if ( [id$resp_h, id$resp_p] in ftp_data_expected )
#		add c$service["ftp-data"];
#	}

#event file_transferred(c: connection, prefix: string, descr: string,
#			mime_type: string) &priority=1
#	{
#	local id = c$id;
#	if ( [id$resp_h, id$resp_p] in ftp_data_expected )
#		{
#		local expected = ftp_data_expected[id$resp_h, id$resp_p];
#		local s = expected$session;
#		s$mime_type = mime_type;
#		s$mime_desc = descr;
#		
#		# TODO: not sure if it's ok to delete this here, but it should
#		#       always be called since the file analyzer is always attached
#		#       to ftp-data sessions.
#		delete ftp_data_expected[id$resp_h, id$resp_p];
#		}
#	}