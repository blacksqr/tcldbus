set auto_path [linsert $auto_path 0 .]
package require dbus

set s ""

set mlist {INT32 {} BYTE {} ARRAY {2 STRUCT {STRING {} INT16 {}}}}
set out [::dbus::MarshalListTest $mlist {0xAABBCCDD 0xFF {
	{{"foo" 0xDEAD} {"bar" 0xFAFA}} \
	{{"abba" 0xCC99} {"gabba" 0xBB77}}}}]

set out [::dbus::MarshalMethodCall \
	org.freedesktop.DBus \
	/org/freedesktop.DBus \
	org.freedesktop.DBus \
	Hello \
	"" {}]

set settings [fconfigure stdout]
fconfigure stdout -translation binary
puts -nonewline [join $out ""]
eval fconfigure stdout $settings

