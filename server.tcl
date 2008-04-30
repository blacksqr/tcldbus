set auto_path [linsert $auto_path 0 .]
package require dbus

if 0 {
set server [::dbus::endpoint -server unix:path=/tmp/gabbahey]
puts {Created server}

set client [::dbus::endpoint unix:path=/tmp/gabbahey]
puts {Created client}

file delete /tmp/gabbahey
}

set server [::dbus::endpoint -server tcp:host=localhost,port=0]
set sport  [lindex [fconfigure $server -sockname] 2]
puts "Created server $server on $sport"

set client [::dbus::endpoint tcp:host=localhost,port=$sport]
puts "Created client $client"

::dbus::invoke $client /my/cool/object com.googlecode.tcldbus.SomeMethod \
	-in si -- "Foo bar" 0xAABBCCDD

vwait forever

