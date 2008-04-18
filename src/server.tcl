# $Id$
# Server part: managing of client connections and client authentication.

namespace eval ::dbus {
if 0 {
	#variable known_mechs {EXTERNAL ANONYMOUS DBUS_COOKIE_SHA1}
	variable known_mechs {EXTERNAL}
	variable auth_handlers
	array set auth_handlers [list \
		EXTERNAL           AuthExternal \
		ANONYMOUS          AuthAnonymous \
		DBUS_COOKIE_SHA1   AuthDBusCookieSHA1 \
	]
}
}

proc ::dbus::SockRaiseError {sock error} {
	variable $sock; upvar 0 $sock state

	close $sock
	set state(code)   error
	set state(result) $error
}

proc ::dbus::listen {on args} {
	set command ""
	set timeout 0
	set transport unix
	set mechanism ""

	while {[string match -* [set opt [Pop args]]]} {
		switch -- $opt {
			-command { set command [Pop args] }
			-timeout { set timeout [Pop args] }
			-transport { set transport [Pop args] }
			-mechanism { set mechanism [Pop args] }
			default {
				return -code error "Bad option \"$opt\":\
					must be one of -command, -timeout or -transport"
			}
		}
	}

	switch -- $transport {
		unix {
			set sock [UnixDomainSocket $on -server Accept]
		}
		tcp {
			foreach {host port} [split $on :] break
			if {$host == "" || $port == ""} {
				return -code error "Bad TCP connection endpoint \"$dest\":\
					must be in the form host:port"
			}
			set sock [socket -server Accept $host $port]
		}
		default {
			return -code error "Bad transport \"$transport\":\
				must be unix or tcp"
		}
	}

	set sock
}

proc ::dbus::Accept {sock name auth} {
	fconfigure $sock -encoding ascii -translation crlf -buffering none -blocking no
	AuthWaitNext $sock [MyCmd SrvAuthProcessFirstCommand $sock]
}

proc ::dbus::SrvAuthProcessFirstCommand {sock line} {
	if {![string equal [string index $line 0] \0]} {
		close $sock
		return
	}

	SrvAuthProcessTopLevelCommand $sock [string range $line 1 end]
}

proc ::dbus::SrvAuthProcessTopLevelCommand {sock line} {
	variable known_mechs

	switch -glob -- $line {
		AUTH {
			puts $sock "REJECTED [join $known_mechs]"
		}
		{AUTH *} {
			foreach {AUTH mech initresp} [split $line] break
			if {[lsearch -exact $known_mechs $mech] < 0} {
				# TODO we should record we once seen an auth attempt
				# with unsupported mech and fail the next time it
				# occurs; this will prevent dumb clients from creating
				# an endless loop with us.
				puts $sock "REJECTED [join $known_mechs]"
				return
			} else {
				# TODO perform one auth step...
			}
		}
		EXTENSION_* { # ignore
		}
		default {
			close $sock
			return
		}
	}
}

proc ::dbus::Authenticate {sock {mech ""}} {
	fconfigure $sock -encoding ascii -translation crlf -buffering none -blocking no
	if {$mech == ""} {
		puts $sock \0AUTH
		AuthWaitNext $sock [MyCmd AuthProcessPeerMechs $sock]
	} else {
		puts -nonewline $sock \0
		AuthTryNextMech $sock $mech
	}
}

proc ::dbus::AuthWaitNext {sock cmd} {
	variable $sock; upvar 0 $sock state
	set state(acc) ""
	$sock [MyCmd SafeGetLine $sock $cmd]
}

proc ::dbus::SafeGetLine {sock cmd} {
	set data [read $sock]
	if {[eof $sock]} {
		SockRaiseError $sock "unexpected remote disconnect"
	}

	variable $sock; upvar 0 $sock state
	upvar 0 state(acc) line

	set ix [string first \n $data]
	if {$ix < 0} {
		if {[string length $line] + [string length $data] > 8192} {
			SockRaiseError $sock "input data packet exceeds hard limit"
		} else {
			append line $data
		}
	} else {
		incr ix -1
		append line [string range $data 0 $ix]
		eval [linsert $cmd end $line]
		incr ix 2
		set line [string range $data $ix end]
	}
}

proc ::dbus::AuthProcessPeerMechs {sock line} {
	switch -glob -- $line {
		REJECTED* {
			variable known_mechs
			set mechs [split [ChopLeft $line "REJECTED "]]
			AuthTryNextMech $sock [LIntersect $mechs $known_mechs]
		}
		ERROR {
			puts $sock CANCEL
			SockRaiseError $sock "Authentication failure: the peer rejected\
				to list supported authentication mechanisms"
		}
		EXTENSION_* return
		default {
			SockRaiseError $sock "Authentication failure: unexpected response\
				in current context"
		}
	}
}

proc ::dbus::AuthTryNextMech {sock mechs} {
	if {[llength $mechs] == 0} {
		SockRaiseError $sock "Authentication failure: no authentication\
			mechanisms left"
	} else {
		variable auth_handlers
		set mech [Pop mechs]
		eval [linsert $auth_handlers($mech) end $sock $mechs]
	}
}

proc ::dbus::AuthExternal {sock mechs} {
	puts $sock "AUTH EXTERNAL [AsciiToHex [UnixUID]]"
	AuthWaitNext $sock [MyCmd AuthExtProcessOK $sock $mechs]
}

proc ::dbus::AuthExtProcessOK {sock mechs line} {
	switch -glob -- $line {
		OK* {
			set guid [ChopLeft $line "OK "]
			ProcessAuthenticated $sock $guid
		}
		REJECTED* {
			AuthTryNextMech $sock $mechs
		}
		EXTENSION_* return
		default {
			SockRaiseError $sock "Authentication failure: unexpected response\
				in current context"
		}
	}
}

proc ::dbus::ProcessAuthenticated {sock guid} {
	variable $sock; upvar 0 $sock state

	after cancel [MyCmd ProcessConnectTimeout $sock]

	puts $sock BEGIN
	fconfigure $sock -translation binary
	$sock [MyCmd ReadMessages $sock]

	set state(code)   ok
	set state(result) $sock
	set state(guid)   $guid

	puts "Auth OK, GUID: $guid"
if 0 {
	if {[info exists state(command)]} {
		set cmd $state(command)
		unset state
		uplevel #0 [list $cmd $code $result]
	} else {
		set state(code)   $code
		set state(result) $result
	}
}
}

proc ::dbus::NextSerial chan {
	variable $chan;
	upvar 0 ${chan}(serial) serial

	incr serial
	if {($serial & 0xFFFFFFFF) == 0} {
		set serial 1
	}

	set serial
}

