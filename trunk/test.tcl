set auto_path [linsert $auto_path 0 .]
package require dbus

set s ""
::dbus::MarshalByte s 64
if 0 {
::dbus::MarshalString s AжопаA
::dbus::MarshalDouble s 8.93e-2
::dbus::MarshalBasicArray s INT32 {1 2 3 4}
}
if 0 {
::dbus::MarshalArray s {INT32 2 {
	{0x01 0x02 0x03 0x04}
	{0x11 0x12 0x13 0x14}
	{0x21 0x22 0x23 0x24}
	{0x31 0x32 0x33 0x34}
}}
}
::dbus::MarshalArray s {STRUCT 1 {{INT32 0xAA STRING GabbaHey!}}}
puts |$s|

