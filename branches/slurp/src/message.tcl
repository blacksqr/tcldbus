# $Id$
# "Objects" representing unmarshaled messages.

namespace eval ::dbus {
	variable msgid 0
}

proc ::dbus::MessageCreate {} {
	variable msgid

	set name [namespace current]::msg$msgid
	variable $name
	array set $name {}

	incr msgid

	set name
}

proc ::dbus::MessageDelete name {
	variable $name
	unset $name
}

