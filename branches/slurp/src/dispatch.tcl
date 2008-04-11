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
			set details   $msg(params)
		}
		ERROR {
			set status    error
			set errorcode [list DBUS METHOD_CALL $msg(ERROR)]
			if {[llength $msg(params)] > 0
					&& [string equal [lindex $msg(SIGNATURE) 0] STRING]} {
				set details [lindex $msg(params) 0]
			} else {
				set details ""
			}
		}
	}

	unset msg

	ReleaseResultWaiter $chan $serial $status $errorcode $details
}

proc ::dbus::ProcessResultWaitingTimedOut {chan serial} {
	ReleaseResultWaiter $chan $serial error \
		[list {DBUS TIMEOUT ""} "method call timeout"]
}

proc ::dbus::ReleaseResultWaiter {chan serial status errorcode details} {
	variable $chan; upvar 0 $chan state
	upvar 0 state(wait_result,$serial) command

	if {$command != ""} {
		set cmd $command
		lappend cmd $status $errorcode $details
		unset command
		uplevel #0 $cmd
	} else {
		unset command
		return -code $status -errorcode $errorcode $details
	}
}

proc ::dbus::ReleaseMethodReturnWaiters {chan status errorcode details} {
	variable $chan; upvar 0 $chan state

	foreach waiter [array names state wait_result,*] {
		SafeCall $waiter $status $details {}
	}
}

