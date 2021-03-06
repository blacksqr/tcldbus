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
	expr {
		[string length $iface] <= 255
		&&
		[regexp {^(?:(?!\d)[A-Za-z\d_]+\.)+(?!\d)[A-Za-z\d_]+$} $iface]
	}
}

# Validates given string representing interface/object's member name.
# Returns true iff the string is valid as defined in the D-Bus spec,
# false otherwise.
proc ::dbus::IsValidMemberName method {
	expr {
		[string length $method] <= 255
		&&
		[regexp {^(?!\d)[A-Za-z\d_]+$} $method]
	}
}

proc ::dbus::IsValidSerial serial {
	expr {$serial != 0}
}

proc ::dbus::IsValidBusName name {
	expr {
		[string length $name] <= 255
		&&
		[regexp {^:(?:[A-Za-z\d_-]+\.)+[A-Za-z\d_-]+$|^(?:(?!\d)[A-Za-z\d_-]+\.)+(?!\d)[A-Za-z\d_-]+$} $name]
	}
}

# Splits "interface member name" into two parts: interface name
# and member name which are stored in variables whose names are
# passed in ifaceVar and memberVar, respectively, in the caller's
# scope.
# This command in fact validates the interface member name it's
# passed and returns true only if it is valid.
# TODO this RE doesn't check that the $imember has at least two dots
# as required by the spec (iface name must be of at least two elements).
# May be it will be simpler to split it at the last ".", then verify
# parts by other commands.
proc ::dbus::SplitMemberName {imember ifaceVar memberVar} {
	upvar 1 $ifaceVar iface $memberVar member

	expr {
		[string length $imember] <= 255 * 2 + 1
		&&
		[regexp {^(?:(?!\d)([A-Za-z\d_]+(?:\.[A-Za-z\d_]+)*)\.)?([A-Za-z\d_]+)$} $imember -> iface member]
	}
}

# Concatenates elements of $args and evaluates the result as a script.
# If the script returns TCL_ERROR code, its error is scheduled to be
# raised on idle condition and the procedure returns without error anyway.
# Can be used to evaluate a series of scripts which must be evaluated all
# regardless of possible errors in them while these errors, if any,
# should be reported.
proc ::dbus::SafeCall args {
	if {[catch $args error] == 1} {
		global errorInfo errorCode
		after idle [list return -code error \
			-errorinfo $errorInfo -errorcode $errorCode $error]
	}
}

