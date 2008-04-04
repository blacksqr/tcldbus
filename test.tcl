set auto_path [linsert $auto_path 0 .]
package require dbus

set s ""
::dbus::MarshalByte s 64
if 0 {
::dbus::MarshalString s Foo
::dbus::MarshalDouble s 8.93e-2
}
::dbus::MarshalArray s INT16 {1 2 3 4}
#::dbus::MarshalArray s INT32 {1 2 3 4}
puts |$s|

