set auto_path [linsert $auto_path 0 .]
package require dbus

set chan [::dbus::connect /var/run/dbus/system_bus_socket -timeout 1000]
puts Connected

proc SockRead chan {
	set data [read $chan]
	if {[eof $chan]} {
		close $chan
		puts Closed
		set ::forever 1
		return
	}
	puts |$data|
}
fileevent $chan readable [list SockRead $chan]

set out [::dbus::MarshalMethodCall /org/Freedesktop/DBus org.Freedesktop.DBus Hello "" {}]
#puts -nonewline $chan [join $out ""]
puts -nonewline $chan "FUCK OFF!!!"
flush $chan
puts Sent

vwait forever

