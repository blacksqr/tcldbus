set auto_path [linsert $auto_path 0 .]
package require dbus

if 1 {
set chan [::dbus::connect /var/run/dbus/system_bus_socket -timeout 1000]
puts Connected

proc SockRead chan {
	puts [info level 0]
	set data [read $chan]
	puts |$data|
	if {[eof $chan]} {
		close $chan
		puts Closed
		set ::forever 1
		return
	}
}
fileevent $chan readable [list SockRead $chan]
}

set out [::dbus::MarshalMethodCall \
	org.freedesktop.DBus \
	/org/freedesktop/DBus \
	org.freedesktop.DBus \
	Hello \
	"" {}]
if 1 {
set data [join $out ""]
fconfigure $chan -translation binary
puts -nonewline $chan $data
set fd [open dump.bin w]
fconfigure $fd -translation binary
puts -nonewline $fd $data
close $fd
puts Sent

vwait forever
} else {
	fconfigure stdout -translation binary
	puts -nonewline stdout [join $out ""]
}

