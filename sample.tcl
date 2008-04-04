package require ceptcl

set path /var/run/dbus/system_bus_socket

proc SockRead s {
	if {[gets $s line] < 0} {
		close $s
		set ::forever 1
		return
	}

	puts $line
}

set s [cep -domain local $path]
fconfigure $s -translation binary -buffering none -blocking no
fileevent $s readable [list SockRead $s]

proc tohex int {
	set out ""
	foreach c [split $int ""] {
		append out [format %02x [scan $c %c]]
	}
	set out
}

puts -nonewline $s \0AUTH\r\n
after 1000 [list \
	puts -nonewline $s "AUTH EXTERNAL [tohex 1000]\r\n"]
after 2000 [list \
	puts -nonewline $s "BEGIN\r\n"]


vwait forever
