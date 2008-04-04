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

# Validates given string of type OBJECT_PATH.
# Returns true iff the string is valid as defined in the D-Bus spec,
# false otherwise.
proc ::dbus::IsValidObjectPath path {
	regexp {^/(?:[A-Za-z\d_]+)?(?:/[A-Za-z\d_]+)*$} $path
}

# Validates given string representing interface name.
# Returns true iff the string is valid as defined in the D-Bus spec,
# false otherwise.
proc ::dbus::IsValidInterfaceName iface {
	regexp {^(?!\d)(?:[A-Za-z\d_]+\.)+[A-Za-z\d_]+$} $iface
}

# Validates given string representing method name.
# Returns true iff the string is valid as defined in the D-Bus spec,
# false otherwise.
proc ::dbus::IsValidMethodname method {
	regexp {^(?!\d)[A-Za-z\d_]+$} $iface
}

# Splits "interfaced method name" into two parts: interface name
# and method name which are stored in variables whose names are
# passed in ifaceVar and methodVar, respectively, in the caller's
# scope.
# This command in fact validates the interfaced method name it's
# passed and returns true only if it is valid.
# TODO this RE doesn't check that the $imethod has at least two dots
# as required by the spec (iface name must be of at least two elements).
# May be it will be simpler to split it at the last ".", then verify
# parts by other commands.
proc ::dbus::SplitMethodName {imethod ifaceVar methodVar} {
	upvar 1 $ifaceVar iface $methodVar method

	regexp {^(?:(?!\d)([A-Za-z\d_]+(?:\.[A-Za-z\d_]+)*)\.)?([A-Za-z\d_]+)$} $imethod -> iface method
}

