set auto_path [linsert $auto_path 0 .]
package require dbus

set chan [::dbus::connect /var/run/dbus/system_bus_socket -timeout 1000]
#set chan [::dbus::connect /tmp/dbus_test -timeout 1000]
puts Connected

proc SockRead chan {
	puts [info level 0]
	set data [read $chan]
	if {[eof $chan]} {
		close $chan
		puts "Remote disconnect"
		set ::forever 1
		return
	}
	puts [regsub -all {[^\w/ -]} |$data| .]
}
fileevent $chan readable [list SockRead $chan]

dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Hello \
	-ignoreresult \
	-destination org.freedesktop.DBus
puts {Sent Hello}
after 500
dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Foo1 \
	-destination org.freedesktop.DBus \
	-ignoreresult \
	-in iiibu \
	-- 0xAABB 0xCCDD 0xEEFF yes 0xDEADBEEF
after 500
if 0 {
dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Foo2 \
	-destination org.freedesktop.DBus \
	-ignoreresult \
	-in ys(iu)ai \
	-- 0xFF Жоппа {0xDEADBEEF 0xAABBCCDD} {1 2 3 4 5 6 7 8 9 10}
}
dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Foo2 \
	-destination org.freedesktop.DBus \
	-ignoreresult \
	-in ys(iu(sby))aai \
	-- 0xFF Жоппа {0xDEADBEEF 0xAABBCCDD {Превед! no 0xCA}} {
		{1 2 3 4 5 6 7 8 9 10}
		{11 12 13 14}
		{45 66}
	}

vwait forever

