set auto_path [linsert $auto_path 0 .]
package require dbus

set chan [::dbus::endpoint -bus -timeout 1000 system]
#set chan [::dbus::endpoint -bus -timeout 1000 session]
#set chan [::dbus::endpoint -bus -timeout 1000 unix:path=/tmp/dbus_test]
puts Connected

puts {Sending Hello}
dbus::invoke $chan /org/freedesktop/DBus org.freedesktop.DBus.Hello \
	-destination org.freedesktop.DBus
puts {Hello answered}

puts {Emitting a signal}
dbus::emit $chan /ru/jabber/tkabber/Gobble ru.jabber.tkabber.GobbleWasFizzled \
	-signature ii \
	-- 0xFF 0xAA

puts {Emitting a signal w/o params}
dbus::emit $chan /ru/jabber/tkabber/Gobble ru.jabber.tkabber.GobbleHasBeenMumbled

puts {Emitting a signal to busmaster}
dbus::emit $chan /ru/jabber/tkabber/Gobble ru.jabber.tkabber.GobbleStartedWobbling \
	-destination org.freedesktop.DBus \
	-signature a(u) \
	[list 0xAA 0xBB 0xCC 0xDD 0xEE 0xFF]

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
	-- 0xFF \
		\u0442\u0435\u0441\u0442\u043e\u0432\u0430\u044f\u0020\u0441\u0442\u0440\u043e\u043a\u0430 \
		{0xDEADBEEF 0xAABBCCDD {\u041f\u0440\u0435\u0432\u0435\u0434! no 0xCA}} {
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

