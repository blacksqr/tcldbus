set auto_path [linsert $auto_path 0 .]
package require dbus

set s ""
if 0 {
::dbus::MarshalByte s 64
::dbus::MarshalString s AжопаA
::dbus::MarshalDouble s 8.93e-2
::dbus::MarshalBasicArray s INT32 {1 2 3 4}
::dbus::MarshalArray s {INT32 2 {
	{0x01 0x02 0x03 0x04}
	{0x11 0x12 0x13 0x14}
	{0x21 0x22 0x23 0x24}
	{0x31 0x32 0x33 0x34}
}}
::dbus::MarshalArray s {STRUCT 1 {{INT32 0xAA STRING GabbaHey!}}}
}

#set in  {BYTE 64 INT32 0xDEADBEEF INT16 0xAABB}
#set in  {BYTE 64 STRUCT {STRING ABCDE UINT32 0xDEADBEEF}}
if 0 {
set in  {ARRAY {1 STRUCT {
	{STRING ABCDE UINT16 0xDEAD}
	{STRING FGHIJ UINT16 0xAABB}
}}}
set out [::dbus::MarshalListTest $in]
}
set out [::dbus::MarshalMethodCall /org/Freedesktop/DBus Hello "" {}]

set settings [fconfigure stdout]
fconfigure stdout -translation binary
puts -nonewline [join $out ""]
eval fconfigure stdout $settings

