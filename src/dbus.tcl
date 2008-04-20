# $Id$
# tcldbus main package file.

namespace eval ::dbus {
	set dir [file dirname [info script]]
	source [file join $dir utils.tcl]
	source [file join $dir sasl.tcl]
	source [file join $dir client.tcl]
	source [file join $dir sigparse.tcl]
	source [file join $dir marshal.tcl]
	source [file join $dir unmarshal.tcl]
	source [file join $dir message.tcl]
	source [file join $dir dispatch.tcl]
	source [file join $dir iface.tcl]
	unset dir
}

package provide dbus 0.1

