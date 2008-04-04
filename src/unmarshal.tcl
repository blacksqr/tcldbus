# $Id$
# Unmarshaling messages from D-Bus input stream

proc ::dbus::StreamTearDown {chan reason} {
	variable $chan; upvar 0 $chan state
	upvar 0 state(command) command

	close $chan

	if {[info exists command]} {
		set cmd [list $command $chan receive error $reason]
	} else {
		set cmd [MyCmd streamerror $chan receive error $reason]
	}
	unset state
	uplevel #0 $cmd

	# This catch-all command is needed in case the user redefined
	# ::dbus::streamerror so that it does not raise an error
	return -code error $reason
}

proc ::dbus::StreamTestEOF chan {
	if {[eof $chan]} {
		StreamTearDown $chan "unexpected remote disconnect"
	}
}

proc ::dbus::MalformedStream {chan reason} {
	append s "Malformed incoming D-Bus stream: " $reason
	StreamTearDown $char $s
}

proc ::dbus::streamerror {chan mode status message} {
	return -code $reason "Processing incoming D-Bus stream from $chan"
}

proc ::dbus::PadSize {len n} {
	set x [expr {$len % $n}]
	if {$x} {
		expr {$n - $x}
	} else {
		return 0
	}
}

proc ::dbus::ReadNextMessage chan {
	variable $chan; upvar 0 $chan state

	set state(acc) ""
	set state(len) 0
	set state(exp) 16

	$chan [MyCmd ReadHeaderPrologue $chan]
}

proc ::dbus::ReadHeaderPrologue chan {
	variable $chan; upvar 0 $chan state
	upvar 0 state(acc) acc state(exp) exp state(len) len
	variable proto_major

	StreamTestEOF $chan

	append acc [read $chan [expr {$exp - $len}]]
	set len [string length $acc]
	if {$len < $exp} return

	binary scan $acc accc bytesex type flags proto
	if {$proto > $proto_major} {
		MalformedStream $chan "unsupported protocol version"
	}
	if {$type < 1 || $type > 4} {
		MalformedStream $chan "unknown message type"
	}
	switch -- $bytesex {
		l { set LE 1; set fmt @4iii }
		B { set LE 0; set fmt @4III }
		default {
			MalformedStream $chan "invalid bytesex specifier"
		}
	}

	binary scan $acc $fmt bodysize serial exp
	set exp [expr {$exp & 0xFFFFFFFF}]
	if {$exp > 0x1000000} {
		MalformedStream $chan "array length exceeds limit"
	}
	set full [expr {($bodysize & 0xFFFFFFFF) + $exp}]
	if {$full + [PadSize $full 8] > 0x4000000} {
		MalformedStream $chan "message length exceeds limit"
	}

	set acc ""
	$chan [MyCmd UnmarshalArray $chan {1 STRUCT {BYTE {} VARIANT {}}} ProcessHeaderFields]
}

proc ::dbus::UnmarshalArray {chan desc next} {
	variable $chan; upvar 0 $chan state
	upvar 0 state(acc) acc state(exp) exp state(len) len \
		state(

	StreamTestEOF $chan
}

proc ::dbus::ReadHeaderFields chan {
	variable $chan; upvar 0 $chan state
	upvar 0 state(acc) acc state(exp) exp state(len) len

	StreamTestEOF $chan

	error "NOT IMPLEMENTED"
}

