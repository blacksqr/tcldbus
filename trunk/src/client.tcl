# $Id$
# Client connection and authentication.

package require struct::set

namespace eval ::dbus {
	variable default_system_bus_instance unix:path=/var/run/dbus/system_bus_socket

	# TODO list of known mechs should take into account what's provided by
	# the SASL package.
	#variable known_mechs {EXTERNAL ANONYMOUS DBUS_COOKIE_SHA1}
	variable known_mechs {EXTERNAL}

	variable auth_callbacks
	array set auth_callbacks [list \
		EXTERNAL           AuthCallbackExternal \
		ANONYMOUS          AuthCallbackAnonymous \
		DBUS_COOKIE_SHA1   AuthCallbackDBusCookieSHA1 \
	]
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

proc ::dbus::UnixDomainSocket args {
	if {[llength $args] == 0} {
		return -code error "Wrong # args:\
			must be [lindex [info level 0] 0] ?options? path"
	}
	package require ceptcl
	interp alias {} ::dbus::UnixDomainSocket {} cep -domain local
	eval UnixDomainSocket $args
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

proc ::dbus::AuthOnNextCommand {sock cmd} {
	variable $sock; upvar 0 $sock state
	set state(acc) ""
	fileevent $sock readable [MyCmd SafeGetLine $sock $cmd]
}

# This is implementation is quite error-prone and slow,
# and requires availability of the "id" Unix program in
# the PATH.
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
			set sock [UnixDomainSocket -async $path]
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

	if {$timeout > 0} {
		after $timeout [MyCmd ClientOnConnectTimeout $sock]
	}
	fileevent $sock writable [MyCmd ClientOnConnectCompleted $sock $command $mechs]

	vwait [namespace current]::${sock}(code)

	variable $sock; upvar 0 $sock state
	set code $state(code)
	set result $state(result)
	if {[string equal $code ok]} {
		set state(serial) 0
	} else {
		unset state
	}
	return -code $code $result
}

proc ::dbus::ClientOnConnectCompleted {sock command mechs} {
	set err [fconfigure $sock -error]
	if {$err == ""} {
		fileevent $sock writable {}
		ClientAuthenticate $sock $command $mechs
	} else {
		SockRaiseError $sock $err
	}
}

proc ::dbus::ClientOnConnectTimeout sock {
	SockRaiseError $sock "connection timed out"
}

proc ::dbus::ClientAuthenticate {sock command mechs} {
	fconfigure $sock -encoding ascii -translation crlf -buffering none -blocking no
	puts $sock \0AUTH
	AuthOnNextCommand $sock [MyCmd ClientAuthProcessPeerMechs $sock $command $mechs]
}

# TODO algorythms for processing mechs should be more sophisticated:
# we have to honor their priority (both specified by client and
# provided by SASL (SASL lists them sorted in the highest to lowest prio))
proc ::dbus::ClientAuthProcessPeerMechs {sock command mechs line} {
	variable known_mechs

	switch -glob -- $line {
		REJECTED -
		ERROR {
			# Server doesn't give away the list of supported mechs, so we
			# try them one by one:
			if {[llength $mechs] == 0} {
				ClientAuthTryNextMech $sock $known_mechs
			} else {
				ClientAuthTryNextMech $sock [struct::set intersect $mechs $known_mechs]
			}
		}
		REJECTED* {
			set offerred [split [ChopLeft $line "REJECTED "]]
			if {[llength $mechs] == 0} {
				ClientAuthTryNextMech $sock [struct::set intersect $offerred $known_mechs]
			} else {
				ClientAuthTryNextMech $sock [struct::set intersect $offerred $known_mechs $mechs]
			}
		}
		EXTENSION_* {
			puts $sock ERROR
			AuthOnNextCommand $sock [MyCmd ClientAuthProcessPeerMechs $sock $command $mechs]
		}
		default {
			SockRaiseError $sock "Authentication failure: unexpected command\
				in current context"
		}
	}
}

proc ::dbus::ClientAuthTryNextMech {sock mechs} {
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
			ClientAuthWaitFor DATA $sock $ctx $mechs
		} else {
			ClientAuthWaitFor OK $sock $ctx $mechs
		}
	}
}

proc ::dbus::ClientAuthWaitFor {what sock ctx mechs} {
	AuthOnNextCommand $sock [MyCmd ClientAuthProcess$what $sock $ctx $mechs]
}

proc ::dbus::ClientAuthProcessDATA {sock ctx mechs line} {
	switch -glob -- $line {
		DATA* {
			set chall [HexToAscii [ChopLeft $line "DATA "]]
			set more [SASL::step $ctx $chall]
			set resp [AsciiToHex [SASL::step $ctx]]
			append cmd "DATA " $resp
			puts $sock $cmd
			if {$more} {
				ClientAuthWaitFor DATA $sock $ctx $mechs
			} else {
				ClientAuthWaitFor OK $sock $ctx $mechs
			}
		}
		REJECTED* {
			SASL::cleanup $ctx
			ClientAuthTryNextMech $sock $mechs
		}
		ERROR {
			ClientAuthCancelExchange $sock $ctx $mechs
		}
		OK* {
			SASL::cleanup $ctx
			set guid [ChopLeft $line "OK "]
			ClientProcessAuthenticated $sock $guid
		}
		default {
			puts $sock ERROR
			ClientAuthWaitFor DATA $sock $ctx $mechs
		}
	}
}

proc ::dbus::ClientAuthProcessOK {sock ctx mechs line} {
	switch -glob -- $line {
		OK* {
			SASL::cleanup $ctx
			set guid [ChopLeft $line "OK "]
			ClientProcessAuthenticated $sock $guid
		}
		REJECTED* {
			SASL::cleanup $ctx
			ClientAuthTryNextMech $sock $mechs
		}
		DATA* -
		ERROR* {
			ClientAuthCancelExchange $sock $ctx $mechs
		}
		default {
			puts $sock ERROR
			AuthWaitFor OK $sock $ctx $mechs
		}
	}
}

proc ::dbus::ClientAuthProcessREJECTED {sock ctx mechs line} {
	switch -glob -- $line {
		REJECTED* {
			SASL::cleanup $ctx
			ClientAuthTryNextMech $sock $mechs
		}
		default {
			SockRaiseError $sock "Authentication failure: unexpected command\
				in current context"
		}
	}
}

proc ::dbus::ClientAuthCancelExchange {sock ctx mechs} {
	puts $sock CANCEL
	AuthWaitFor REJECTED $sock $ctx $mechs
}

proc ::dbus::ClientProcessAuthenticated {sock guid} {
	variable $sock; upvar 0 $sock state

	after cancel [MyCmd ProcessConnectTimeout $sock]

	puts $sock BEGIN
	fconfigure $sock -translation binary
	fileevent $sock readable [MyCmd ReadMessages $sock]

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

### Server part:

proc ::dbus::ServerEndpoint {dests bus command mechs} {
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
			set sock [UnixDomainSocket -server [MyCmd ServerAuthenticate $command $mechs] $path]
		}
		tcp {
			array set params $spec
			foreach param {host port} {
				if {![info exists $param]} {
					return -code error "Required address component missing: $param"
				}
			}
			set sock [socket -server [MyCmd ServerAuthenticate $command $mechs] $params(host) $params(port)]
		}
		default {
			return -code error "Bad transport \"$transport\":\
				must be unix or tcp"
		}
	}

	set sock
}

proc ::dbus::ServerAuthWaitFor {what sock ctx mechs} {
	AuthOnNextCommand $sock [MyCmd ServerAuthProcess$what $sock $ctx $mechs]
}

proc ::dbus::ServerAuthenticate {command mechs sock args} {
	variable known_mechs

	fconfigure $sock -encoding ascii -translation crlf -buffering none -blocking no

	if {[llength $mechs] > 0} {
		set mechs [struct::set intersect $mechs $known_mechs]
	} else {
		set mechs $known_mechs
	}
	if {[llength $mechs] == 0} {
		close $sock
		# TODO we should call $command here
	} else {
		AuthOnNextCommand $sock [MyCmd ServerProcessInitialCommand $sock $command $mechs]
	}
}

proc ::dbus::ServerProcessInitialCommand {sock command mechs line} {
	if {![string match \0* $line]} {
		close $sock
		return
	}

	ServerProcessAUTH $sock $command $mechs [string range $line 1 end]
}

proc ::dbus::ServerProcessAUTH {sock command mechs line} {
	switch -glob -- $line {
		{AUTH *} {
			variable auth_callbacks
			foreach {mech iresp} [split [ChopLeft $line "AUTH "]] break
			if {[lsearch -exact $mechs $mech] < 0} {
				puts $sock "REJECTED [join $mechs]"
				ServerWaitFor AUTH $sock $command $mechs
			} else {
				set ctx  [SASL::new -type server -mechanism $mech \
					-callback [MyCmd $auth_callbacks($mech) $sock]]
				set more [SASL::step $ctx $iresp]
				if {$more} {
					set resp [AsciiToHex [SASL::response $ctx]]
					append cmd "DATA " $mech
					if {$resp != ""} { append cmd " " $resp }
					puts $sock $cmd
					ServerAuthWaitFor DATA $sock $ctx $command $mechs
				} else {
					SASL::cleanup $ctx
					puts $sock OK	
					ServerAuthWaitFor BEGIN $sock $command $mechs
				}
			}
		}
		BEGIN {
			close $sock
		}
		default {
			puts $sock "REJECTED [join $mechs]"
			ServerWaitFor AUTH $sock $command $mechs
		}
	}
}

proc ::dbus::ServerProcessDATA {sock ctx command mechs line} {
	switch -glob -- $line {
		DATA* {
		}
		BEGIN {
			close $sock
			SASL::cleanup $ctx
			ServerAuthWaitFor AUTH $sock $command $mechs
		}
		CANCEL -
		ERROR {
			SASL::cleanup $ctx
			puts $sock "REJECTED [join $mechs]"
			ServerAuthWaitFor AUTH $sock $command $mechs
		}
		default {
			puts $sock ERROR
			ServerAuthWaitFor DATA $sock $ctx $command $mechs
		}
	}
}

proc ::dbus::ServerProcessBEGIN {sock command mechs line} {
	switch -glob -- $line {
		BEGIN {
			fconfigure $sock -translation binary
			fileevent $sock readable [MyCmd ReadMessages $sock]
		}
		CANCEL -
		ERROR {
			puts $sock "REJECTED [join $mechs]"
			ServerAuthWaitFor AUTH $sock $command $mechs
		}
		default {
			puts $sock ERROR
			ServerAuthWaitFor BEGIN $sock $command $mechs
		}
	}
}

#### Auth handlers

# TODO we should call $command in both cases so that the user code
# could override the default behaviour. The command should have
# some mechanism to tell us whether is ignored this invocation
# or handled it (look for what tls does).
proc ::dbus::AuthCallbackExternal {sock command challenge args} {
	switch -- $command {
		initial { # client part
			return [UnixUID]
		}
		authenticate { # server part
			set supplied [HexToAscii $challenge]
			set real [lindex [fconfigure $sock -peereid] 0]
			return [expr {$real == $supplied}]
		}
		default {
			return -code error "Unknown SASL EXTERNAL client callback command: \"$command\""
		}
	}
}

