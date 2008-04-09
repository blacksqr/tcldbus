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
		METHOD_RETURN {
			ProcessMethodReturn $chan $msgid
		}
		SIGNAL {
		}
		UNKNOWN {
		}
	}

	MessageDelete $msgid
}

proc ::dbus::ExpectMethodReturn {chan serial command} {
	variable $chan; upvar 0 $chan state

	set key wait_result,$serial
	set state($key) $command

	if {$timeout > 0} {
		after $timeout [MyCmd ProcessResultWaitingTimedOut $chan $serial]
	}
	return [namespace current]::${chan}($key)
}

proc ::dbus::ProcessMethodReturn {chan msgid} {
	variable $chan; upvar 0 $chan state

	upvar 0 state(wait_result,$serial) command

	if {![info exists command]} return

	after cancel [MyCmd ProcessResultWaitingTimedOut $chan $serial]

	if {$command != ""} {
		variable $msgid; upvar 0 $msgid msg
		upvar 0 msg(params) params

		set cmd $command
		switch -- $msg(type) {
			METHOD_RETURN {
				lappend cmd ok {} $params
			}
			ERROR {
				lappend cmd error DBUS $params
			}
		}
		unset command
		uplevel #0 $cmd
	} else {
		unset command
		# TODO so what?
	}
	puts "at exit, <$chan><$serial>"
}

proc ::dbus::ProcessResultWaitingTimedOut {chan serial} {
	variable $chan; upvar 0 $chan state

	upvar 0 state(wait,$serial) command

	if {$command != ""} {
		lappend cmd $command error {TCLDBUS METHOD_CALL_TIMEOUT} "method call timed out"
		unset command
		uplevel #0 [linsert $cmd end error $s]
	} else {
		unset command
		return -code error $s
	}
}

proc ::dbus::ReleaseMethodReturnWaiters {chan status details} {
	variable $chan; upvar 0 $chan state

	foreach waiter [array names state wait_result,*] {
		SafeCall $waiter $status $details {}
	}
}

