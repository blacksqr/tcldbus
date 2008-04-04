proc accept {chan args} {
	puts "accepted connection from [fconfigure $chan -sockname]"
}

proc ChanRead chan {
	if {[eof $chan]} {
		return -code error "Unexpected remote disconnect"
	}

	variable $chan; upvar 0 $chan state
	$state(consumer) $chan
}

proc ChanSetConsumer {chan cmd} {
	variable $chan; upvar 0 $chan state

	set state(consumer) $cmd
}

set chan [socket -server accept 0]
puts [fconfigure $chan -sockname]
fconfigure $chan -blocking no -buffering none -translation binary
fileevent $chan readable [list ChanRead $chan]

vwait forever

