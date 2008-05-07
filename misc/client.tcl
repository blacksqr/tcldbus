package require ceptcl

set s [cep -domain local /tmp/dbus_test]
fconfigure $s -translation binary -buffering none -blocking no
proc foo chan {
	set n [gets $chan]
	if {$n < 0} {
		close $chan
		puts "unexpected remote disconnect"
	}
}
fileevent $s readable [list foo $s]
puts $s hey!

vwait forever
