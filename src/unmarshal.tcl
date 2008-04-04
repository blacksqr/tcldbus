# $Id$

proc ::dbus::ReadNextMessage chan {
	variable $chan; upvar 0 $chan state

	set state(acc) ""
	set state(len) 0
	set state(wants) 12

	$chan [MyCmd ReadHeaderPrologue $chan]
}

proc ::dbus::ReadHeaderPrologue chan {
	variable $chan; upvar 0 $chan state
	upvar 0 state(acc) acc state(wants) wants state(len) len

	if {![eof $chan]} {
		close $chan
		return
	}

	append acc [read $chan $wants]
	set len [string length $acc]
	# TODO it's an error, wants should be computed dynamically.
	if {$len < $wants} {
		set wants [expr {$wants - $len}]
		return
	}

	binary scan acccii $acc bytesex type flags proto msglen serial

	set acc ""
	$chan [MyCmd ReadHeaderFields $chan]
}

proc ::dbus::ReadHeaderFields chan {
	variable $chan; upvar 0 $chan state
	upvar 0 state(acc) acc state(wants) wants state(len) len

	if {![eof $chan]} {
		close $chan
		return
	}
}

