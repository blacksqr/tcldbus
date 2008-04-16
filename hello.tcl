set auto_path [linsert $auto_path 0 .]
package require dbus

set chan [::dbus::connect /var/run/dbus/system_bus_socket -timeout 1000]
#set chan [::dbus::connect /tmp/dbus_test -timeout 1000]
puts Connected

puts {Sending Hello}
dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Hello \
	-destination org.freedesktop.DBus
puts {Hello answered}

puts {Sending async #1}
dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Foo1 \
	-destination org.freedesktop.DBus \
	-ignoreresult \
	-in iiibu \
	-- 0xAABB 0xCCDD 0xEEFF yes 0xDEADBEEF

puts {Sending async #2}
namespace eval ::whatever::complex::nested::stuff {
	proc crack_async_res {a b status code result} {
		puts "At [info level]: [info level 0]"
	}
}
dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Foo2 \
	-destination org.freedesktop.DBus \
	-command [list ::whatever::complex::nested::stuff::crack_async_res foo bar] \
	-in ys(iu(sby))aai \
	-- 0xFF Жоппа {0xDEADBEEF 0xAABBCCDD {Превед! no 0xCA}} {
		{1 2 3 4 5 6 7 8 9 10}
		{11 12 13 14}
		{45 66}
	}

puts {Sending blob}
set failed [catch {
dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Foo3 \
	-destination org.freedesktop.DBus \
	-in s \
	-- [string repeat x [expr {8 * 1024 * 1024}]]
} err]
puts {Blob answered}
if {$failed} {
	puts "Method call failed with: $err\nCode: $::errorCode\n:Info: $::errorInfo"
}

puts {Waiting forever...}
vwait forever

