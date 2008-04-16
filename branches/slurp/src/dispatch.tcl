# $Id$
# Dispatching of unmarshaled incoming messages.

namespace eval ::dbus {
	variable reply_waiters
}

proc ::dbus::DispatchIncomingMessage {chan msgid} {
	variable $msgid; upvar 0 $msgid msg

	puts [info level 0]

	switch -- $msg(type) {
		METHOD_CALL {
		}
		METHOD_REPLY -
		ERROR {
			ProcessMethodReply $chan $msgid
		}
		SIGNAL {
		}
		UNKNOWN {
		}
	}

	MessageDelete $msgid
}

proc ::dbus::ExpectMethodReply {chan serial timeout command} {
	variable reply_waiters

	set rvpoint reply_waiters($chan,$serial)
	set $rvpoint $command

	if {$timeout > 0} {
		after $timeout [MyCmd ProcessReplyWaitingTimedOut $chan $serial]
	}
	return [namespace current]::$rvpoint
}

proc ::dbus::ProcessMethodReply {chan msgid} {
	variable reply_waiters
	variable $msgid; upvar 0 $msgid msg

	puts [info level 0]

	set serial $msg(serial)
	set rvpoint reply_waiters($chan,$serial)
	if {![info exists $rvpoint]} return

	after cancel [MyCmd ProcessReplyWaitingTimedOut $chan $serial]

	switch -- $msg(type) {
		METHOD_REPLY {
			set status    ok
			set errorcode NONE
			set result    $msg(params)
		}
		ERROR {
			set status    error
			set errorcode [list DBUS METHOD_CALL $msg(ERROR_NAME)]
			if {[llength $msg(params)] > 0
					&& [string equal [lindex $msg(SIGNATURE) 0] STRING]} {
				set result [lindex $msg(params) 0]
			} else {
				set result $msg(ERROR_NAME)
			}
		}
	}

	unset msg

	ReleaseReplyWaiter [namespace current]::$rvpoint $status $errorcode $result
}

proc ::dbus::ProcessReplyWaitingTimedOut {chan serial} {
	variable reply_waiters

	set reason "method call timed out"
	ReleaseReplyWaiter [namespace current]::reply_waiters($chan,$serial) \
		error [list DBUS TIMEOUT $reason] $reason
}

proc ::dbus::ReleaseReplyWaiter {rvpoint status errorcode result} {
	puts [info level 0]

	if {[set $rvpoint] != ""} {
		set cmd [set $rvpoint]
		lappend cmd $status $errorcode $result
		unset $rvpoint
		uplevel #0 $cmd
	} else {
		set $rvpoint [list $status $errorcode $result]
	}
}

proc ::dbus::ReleaseReplyWaiters {chan status errorcode result} {
	variable reply_waiters

	puts [info level 0]

	foreach key [array names reply_waiters $chan,*] {
		#SafeCall ReleaseReplyWaiter $state($token) $status $errorcode $result
		ReleaseReplyWaiter [namespace current]::reply_waiters($key) \
			$status $errorcode $result
	}
}

