set auto_path [linsert $auto_path 0 .]
package require dbus

set server [::dbus::endpoint -server foo unix:path=/tmp/gabbahey]
puts {Created server}

set client [::dbus::endpoint unix:path=/tmp/gabbahey]
puts {Created client}

file detele /tmp/gabbahey

