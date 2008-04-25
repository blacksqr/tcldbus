# $Id$
# Client connection and authentication.

namespace eval ::dbus {
	variable default_system_bus_instance unix:path=/var/run/dbus/system_bus_socket

	#variable known_mechs {EXTERNAL ANONYMOUS DBUS_COOKIE_SHA1}
	variable known_mechs {EXTERNAL}

	variable auth_callbacks
	array set auth_callbacks [list \
		EXTERNAL           AuthCallbackExternal \
		ANONYMOUS          AuthCallbackAnonymous \
		DBUS_COOKIE_SHA1   AuthCallbackDBusCookieSHA1 \
	]
}

proc ::dbus::SystemBusName {} {
	global env

	if {[info exists env(DBUS_SYSTEM_BUS_ADDRESS)]} {
		return $env(DBUS_SYSTEM_BUS_ADDRESS)
	} else {
		variable default_system_bus_instance
		return $default_system_bus_instance
	}
}

proc ::dbus::SessionBusName {} {
	global env

	if {[info exists env(DBUS_SESSION_BUS_ADDRESS)]} {
		return $env(DBUS_SESSION_BUS_ADDRESS)
	}

	GetSessionBusXProp
}

proc ::dbus::GetSessionBusXProp {} {
	set prop _DBUS_SESSION_BUS_ADDRESS

	if {[catch [format {exec xprop -root -f %1$s 0t =\$0 %1$s} $prop] out]} {
		return ""
	}
	if {![regexp ^${prop}(\(.+\))?=(.+)\$ $out -> type value]} {
		return ""
	}
	if {![string equal $type STRING]} {
      return ""
    }
    return $value
}

proc ::dbus::EscapeAddressValue addr {
	set bstr [encoding convertto utf-8 $addr]

	set out ""
	foreach c [split $bstr ""] {
		if {[regexp {^[0-9A-Za-z/.\\_-]$} $c]} {
			append out $c
		} else {
			append out % [format %02x [scan $c %c]]
		}
	}

	encoding convertfrom utf-8 $out
}

proc ::dbus::UnescapeAddressValue addr {
	set bstr [encoding convertto utf-8 $addr]

	if {[regexp {[^%0-9A-Za-z/.\\_-]|%(?![[:xdigit:]]{2})} $bstr]} {
		return -code error "Malformed server address value"
	}

	variable prcescmap
	if {![info exists prcescmap]} {
		for {set i 0} {$i <= 0xFF} {incr i} {
			lappend prcescmap %[format %02x $i] [format %c $i]
		}
	}

	encoding convertfrom utf-8 [string map -nocase $prcescmap $bstr]
}

proc ::dbus::ParseServerAddress address {
	set out [list]
	foreach addr [split $address \;] {
		if {$addr == ""} continue

		if {![regexp {^(.+?):(.+)$} $addr -> method tail]} {
			return -code error "Malformed server address"
		}

		set parts [list]
		foreach part [split $tail ,] {
			if {![regexp {^(.+?)=(.+)$} $part -> key val]} {
				return -code error "Malformed server address"
			}
			lappend parts $key [UnescapeAddressValue $val]
		}

		lappend out $method $parts
	}

	set out
}

proc ::dbus::AsciiToHex s {
	binary scan $s H* out
	set out
}

proc ::dbus::HexToAscii s {
	binary format H* $s
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

proc ::dbus::ClientEndpoint {dests bus command mechs async timeout} {
	# TODO implement iteration over all dests
	foreach {transport spec} $dests break

	switch -- $transport {
		unix {
			array set params $spec
			if {[info exists params(path)]} {
				set path $params(path)
			} elseif {[info exists params(abstract)]} {
				set path $params(abstract)
			} else {
				return -code error "Required address component missing: path or abstract"
			}
			set sock [UnixDomainSocket $path -async]
		}
		tcp {
			array set params $spec
			foreach param {host port} {
				if {![info exists $param]} {
					return -code error "Required address component missing: $param"
				}
			}
			set sock [socket -async $params(host) $params(port)]
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

	foreach token {command mechs} {
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
		AuthOnNextCommand $sock [MyCmd AuthProcessPeerMechs $sock]
	} else {
		puts -nonewline $sock \0
		AuthTryNextMech $sock $mech
	}
}

proc ::dbus::AuthOnNextCommand {sock cmd} {
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
	variable known_mechs

	switch -glob -- $line {
		REJECTED -
		ERROR {
			# Server doesn't give away the list of supported mechs, so we
			# try them one by one:
			AuthTryNextMech $sock $known_mechs
		}
		REJECTED* {
			set mechs [split [ChopLeft $line "REJECTED "]]
			AuthTryNextMech $sock [LIntersect $mechs $known_mechs]
		}
		EXTENSION_* {
			puts $sock ERROR
			AuthOnNextCommand $sock [MyCmd AuthProcessPeerMechs $sock]
		}
		default {
			SockRaiseError $sock "Authentication failure: unexpected command\
				in current context"
		}
	}
}

proc ::dbus::AuthTryNextMech {sock mechs} {
	if {[llength $mechs] == 0} {
		SockRaiseError $sock "Authentication failure: no authentication\
			mechanisms left"
	} else {
		variable auth_callbacks
		set mech [Pop mechs]
		set ctx  [SASL::new -mechanism $mech \
			-callback [MyCmd $auth_callbacks($mech) $sock]]
		set more [SASL::step $ctx ""]
		set resp [AsciiToHex [SASL::response $ctx]]
		append cmd "AUTH " $mech
		if {$resp != ""} { append cmd " " $resp }
		puts $sock $cmd
		if {$more} {
			AuthWaitFor DATA $sock $ctx $mechs
		} else {
			AuthWaitFor OK $sock $ctx $mechs
		}
	}
}

proc ::dbus::AuthWaitFor {what sock ctx mechs} {
	AuthOnNextCommand $sock [MyCmd AuthProcess$what $sock $ctx $mechs]
}

proc ::dbus::AuthProcessDATA {sock ctx mechs line} {
	switch -glob -- $line {
		DATA* {
			set chall [HexToAscii [ChopLeft $line "DATA "]]
			set more [SASL::step $ctx $chall]
			set resp [AsciiToHex [SASL::step $ctx]]
			append cmd "DATA " $resp
			puts $sock $cmd
			if {$more} {
				AuthWaitFor DATA $sock $ctx $mechs
			} else {
				AuthWaitFor OK $sock $ctx $mechs
			}
		}
		REJECTED* {
			SASL::cleanup $ctx
			AuthTryNextMech $sock $mechs
		}
		ERROR {
			AuthCancelExchange $sock $ctx $mechs
		}
		OK* {
			SASL::cleanup $ctx
			set guid [ChopLeft $line "OK "]
			ProcessAuthenticated $sock $guid
		}
		default {
			puts $sock ERROR
			AuthWaitFor DATA $sock $ctx $mechs
		}
	}
}

proc ::dbus::AuthProcessOK {sock ctx mechs line} {
	switch -glob -- $line {
		OK* {
			SASL::cleanup $ctx
			set guid [ChopLeft $line "OK "]
			ProcessAuthenticated $sock $guid
		}
		REJECTED* {
			SASL::cleanup $ctx
			AuthTryNextMech $sock $mechs
		}
		DATA* -
		ERROR* {
			AuthCancelExchange $sock $ctx $mechs
		}
		default {
			puts $sock ERROR
			AuthWaitFor OK $sock $ctx $mechs
		}
	}
}

proc ::dbus::AuthProcessREJECTED {sock ctx mechs line} {
	switch -glob -- $line {
		REJECTED* {
			SASL::cleanup $ctx
			AuthTryNextMech $sock $mechs
		}
		default {
			SockRaiseError $sock "Authentication failure: unexpected command\
				in current context"
		}
	}
}

proc ::dbus::AuthCancelExchange {sock ctx mechs} {
	puts $sock CANCEL
	AuthWaitFor REJECTED $sock $ctx $mechs
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

proc ::dbus::AuthCallbackExternal {sock command challenge args} {
	if {![string equal $command initial]} {
		return -code error "Unknown SASL EXTERNAL client callback command: \"$command\""
	}

	UnixUID
}

