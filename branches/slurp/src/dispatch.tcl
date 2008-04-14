# $Id$
# Dispatching of unmarshaled messages.

namespace eval ::dbus {
}

proc ::dbus::DispatchIncomingMessage {chan msgid} {
	variable $chan;  upvar 0 $chan  state
	variable $msgid; upvar 0 $msgid msg

	switch -- $msg(type) {
		METHOD_CALL {
		}
		METHOD_RETURN -
		ERROR {
			ProcessMethodReturn $chan $msgid
		}
		SIGNAL {
		}
		UNKNOWN {
		}
	}

	MessageDelete $msgid
}

proc ::dbus::ExpectMethodReturn {chan serial timeout command} {
	variable $chan; upvar 0 $chan state

	set key wait_result,$serial
	set state($key) $command

	if {$timeout > 0} {
		after $timeout [MyCmd ProcessResultWaitingTimedOut $chan $serial]
	}
	return [namespace current]::${chan}($key)
}

proc ::dbus::ProcessMethodReturn {chan msgid} {
	variable $chan;  upvar 0 $chan  state
	variable $msgid; upvar 0 $msgid msg

	set serial $msg(serial)
	upvar 0 state(wait_result,$serial) command

	if {![info exists command]} return

	after cancel [MyCmd ProcessResultWaitingTimedOut $chan $serial]

	switch -- $msg(type) {
		METHOD_RETURN {
			set status    ok
			set errorcode ""
			set result    $msg(params)
		}
		ERROR {
			set status    error
			set errorcode [list DBUS METHOD_CALL $msg(ERROR)]
			if {[llength $msg(params)] > 0
					&& [string equal [lindex $msg(SIGNATURE) 0] STRING]} {
				set result [lindex $msg(params) 0]
			} else {
				set result ""
			}
		}
	}

	unset msg

	ReleaseResultWaiter $state(wait_result,$serial) $status $errorcode $result
}

proc ::dbus::ProcessResultWaitingTimedOut {chan serial} {
	variable $chan; upvar 0 $chan state

	set reason "method call timed out"
	ReleaseResultWaiter $state(wait_result,$serial) error \
		[list DBUS TIMEOUT $reason] $reason
}

proc ::dbus::ReleaseResultWaiter {command status errorcode result} {
	if {$command != ""} {
		set cmd $command
		lappend cmd $status $errorcode $result
		unset command
		uplevel #0 $cmd
	} else {
		unset command
		global errorInfo
		return -code $status -errorcode $errorcode -errorinfo $errorInfo $result
	}
}

proc ::dbus::ReleaseResultWaiters {chan status errorcode result} {
	variable $chan; upvar 0 $chan state

	puts [info level 0]

	foreach token [array names state wait_result,*] {
		#SafeCall ReleaseResultWaiter $state($token) $status $errorcode $result
		ReleaseResultWaiter $state($token) $status $errorcode $result
	}
}

