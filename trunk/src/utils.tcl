# $Id$
# Utility procs

proc ::dbus::Pop {varname {nth 0}} {
	upvar $varname args
	set r [lindex $args $nth]
	set args [lreplace $args $nth $nth]
	return $r
}

proc ::dbus::MyCmd args {
	lset args 0 [uplevel 1 namespace current]::[lindex $args 0]
}

# Returns a string with that many characters contained in $sub
# removed from the start of the string $s
proc ::dbus::ChopLeft {s sub} {
  string range $s [string length $sub] end
}

# Returns a list which is an intersection of lists given as
# arguments (i.e. a list of elements found in each given list).
# Courtesy of Richard Suchenwirth (http://wiki.tcl.tk/43)
proc ::dbus::LIntersect args {
	set res [list]
	foreach element [lindex $args 0] {
		set found 1
		foreach list [lrange $args 1 end] {
			if {[lsearch -exact $list $element] < 0} {
				set found 0; break
			}
		}
		if {$found} {lappend res $element}
	}
	set res
}

# Splits "interfaced method name" into two parts: interface name
# and method name which are stored in variables whose names are
# passed in ifaceVar and methodVar, respectively, in the caller's
# scope.
# This command in fact validates the interfaced method name it's
# passed and returns true only if it is valid.
proc ::dbus::SplitMethodName {imethod ifaceVar methodVar} {
	upvar 1 $ifaceVar iface $methodVar method

	regexp {^(?:([\w\d]+(?:\.[\w\d]+)*)\.)?([\w\d]+)$} $imethod -> iface method
}

