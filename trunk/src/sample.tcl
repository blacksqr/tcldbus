
namespace eval ::dbus {
	variable sysbus /var/run/dbus/system_bus_socket
	#variable known_mechs {EXTERNAL DBUS_COOKIE_SHA1}
	variable known_mechs {EXTERNAL}
	variable auth_handlers
	array set auth_handlers [list \
		EXTERNAL           AuthExternal \
		DBUS_COOKIE_SHA1   AuthDBusCookieSHA1 \
	]
}

proc ::dbus::Pop {varname {nth 0}} {
	upvar $varname args
	set r [lindex $args $nth]
	set args [lreplace $args $nth $nth]
	return $r
}

proc ::dbus::MyCmd args {
	lset args 0 [uplevel 1 namespace current]::[lindex $args 0]
}

# Returns a string with that many characters contained in $sub
# removed from the start of the string $s
proc ::dbus::ChopLeft {s sub} {
  string range $s [string length $sub] end
}

# Returns a list which is an intersection of lists given as
# arguments (i.e. a list of elements found in each given list).
# Courtesy of Richard Suchenwirth (http://wiki.tcl.tk/43)
proc ::dbus::LIntersect args {
	set res [list]
	foreach element [lindex $args 0] {
		set found 1
		foreach list [lrange $args 1 end] {
			if {[lsearch -exact $list $element] < 0} {
				set found 0; break
			}
		}
		if {$found} {lappend res $element}
	}
	set res
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
	set cmd [list return -code $state(code) $state(result)]
	unset state
	eval $cmd
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
	puts $sock "AUTH EXTERNAL [AsciiToHex 1000]"
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

if 0 {
set s [::dbus::connect $::dbus::sysbus -timeout 1000]
#set s [::dbus::connect /var/run/kaboom]
#set s [::dbus::connect jabber.007spb.ru:80 -transport tcp]
#set s [::dbus::connect jabber.007spb.ru:80 -transport tcp -timeout 500]
proc SockRead s {
	set data [read $s]
	if {[eof $s]} {
		close $s
		set ::forever 1
	} else {
		puts $data
	}
}
fileevent $s readable [list SockRead $s]
vwait forever

exit 0
}

