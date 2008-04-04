# $Id$
# tcldbus main package file.

namespace eval ::dbus {
	set dir [file dirname [info script]]
	source [file join $dir sample.tcl]
	source [file join $dir sigparse.tcl]
	source [file join $dir marshal.tcl]
	unset dir
}

package provide dbus 0.1

