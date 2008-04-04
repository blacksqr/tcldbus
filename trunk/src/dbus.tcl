# $Id$
# tcldbus main package file.

namespace eval ::dbus {
	set dir [file dirname [info script]]
	source [file join $dir sigparse.tcl]
	unset dir
}

package provide dbus 0.1

