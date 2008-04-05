# $Id$
# Client connection and authentication.

namespace eval ::dbus {
	variable sysbus /var/run/dbus/system_bus_socket
	#variable known_mechs {EXTERNAL ANONYMOUS DBUS_COOKIE_SHA1}
	variable known_mechs {EXTERNAL}
	variable auth_handlers
	array set auth_handlers [list \
		EXTERNAL           AuthExternal \
		ANONYMOUS          AuthAnonymous \
		DBUS_COOKIE_SHA1   AuthDBusCookieSHA1 \
	]
}

proc ::dbus::AsciiToHex s {
	set out ""
	foreach c [split $s ""] {
		append out [format %02x [scan $c %c]]
	}
	set out
}

proc ::dbus::UnixDomainSocket {path args} {
	package require ceptcl
	interp alias {} ::dbus::UnixDomainSocket {} cep -domain local
	eval UnixDomainSocket $args [list $path]
}

# This is implementation is quite error-prone and slow,
# and requires availability of the "id" Unix program in
# the PATH.
# TODO make an attempt to load Tclx first, use its [id] command,
# if available; fallback to the current method, if not.
proc ::dbus::UnixUID {} {
	exec id -u
}

proc ::dbus::SockRaiseError {sock error} {
	variable $sock; upvar 0 $sock state

	close $sock
	set state(code)   error
	set state(result) $error
}

proc ::dbus::connect {dest args} {
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
			set sock [UnixDomainSocket $dest -async]
		}
		tcp {
			foreach {host port} [split $dest :] break
			if {$host == "" || $port == ""} {
				return -code error "Bad TCP connection endpoint \"$dest\":\
					must be in the form host:port"
			}
			set sock [socket -async $host $port]
		}
		default {
			return -code error "Bad transport \"$transport\":\
				must be unix or tcp"
		}
	}

	variable $sock; upvar 0 $sock state

	if {$timeout > 0} {
		after $timeout [MyCmd ProcessConnectTimeout $sock]
	}
	fileevent $sock writable [MyCmd ProcessConnectCompleted $sock]

	foreach token {command mechanism} {
		set val [set $token]
		if {$val != ""} {
			set state($token) $val
		}
	} 

	vwait [namespace current]::${sock}(code)

	set code $state(code)
	set result $state(result)
	if {[string equal $code ok]} {
		set state(serial) 0
	} else {
		unset state
	}
	return -code $code $result
}

proc ::dbus::ProcessConnectCompleted sock {
	set err [fconfigure $sock -error]
	if {$err == ""} {
		fileevent $sock writable {}
		interp alias {} [namespace current]::$sock {} fileevent $sock readable
		Authenticate $sock
	} else {
		SockRaiseError $sock $err
	}
}

proc ::dbus::ProcessConnectTimeout sock {
	SockRaiseError $sock "connection timed out"
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

