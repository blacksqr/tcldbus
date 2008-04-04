
namespace eval ::dbus {
	variable sysbus /var/run/dbus/system_bus_socket
}

proc ::dbus::Pop {varname {nth 0}} {
	upvar $varname args
	set r [lindex $args $nth]
	set args [lreplace $args $nth $nth]
	return $r
}

proc ::dbus::UnixDomainSocket {path args} {
	package require ceptcl
	interp alias {} ::dbus::UnixDomainSocket {} cep -domain local
	eval UnixDomainSocket $args [list $path]
}

proc ::dbus::connect {dest args} {
	set command ""
	set timeout 0
	set transport unix

	while {[string match -* [set opt [Pop args]]]} {
		switch -- $opt {
			-command { set command [Pop args] }
			-timeout { set timeout [Pop args] }
			-transport { set transport [Pop args] }
			default {
				return -code error "Bad option \"$opt\":\
					must be one of -command, -timeout or -transport"
			}
		}
	}

	switch -- $transport {
		unix {
			set sock [UnixDomainSocket $dest -async]
		}
		tcp {
			foreach {host port} [split $dest :] break
			if {$host == "" || $port == ""} {
				return -code error "Bad TCP connection endpoint \"$dest\":\
					must be in the form host:port"
			}
			set sock [socket -async $host $port]
		}
		default {
			return -code error "Bad transport \"$transport\":\
				must be unix or tcp"
		}
	}

	variable $sock; upvar 0 $sock state

	if {$timeout > 0} {
		after $timeout [list [namespace current]::ProcessConnectTimeout $sock]
	}
	fileevent $sock writable [list ::dbus::ProcessConnectCompleted $sock]

	if {$command != ""} {
		set state(command) $command
		return $sock
	} 

	vwait [namespace current]::${sock}(code)
	set cmd [list return -code $state(code) $state(result)]
	unset state
	eval $cmd
}

proc ::dbus::ProcessConnectCompleted sock {
	variable $sock; upvar 0 $sock state

	after cancel [list [namespace current]::ProcessConnectTimeout $sock]
	fileevent $sock writable {}

	set err [fconfigure $sock -error]
	if {$err == ""} {
		set code   ok
		set result $sock
	} else {
		close $sock
		set code   error
		set result $err
	}

	if {[info exists state(command)]} {
		set cmd $state(command)
		unset state
		uplevel #0 [list $cmd $code $result]
	} else {
		set state(code)   $code
		set state(result) $result
	}
}

proc ::dbus::ProcessConnectTimeout sock {
	variable $sock; upvar 0 $sock state

	close $sock
	set state(code)   error
	set state(result) "connection timed out"
}

#set s [::dbus::connect $::dbus::sysbus -timeout 1000]
#set s [::dbus::connect /var/run/kaboom]
set s [::dbus::connect jabber.007spb.ru:80 -transport tcp]
fconfigure $s -translation binary -buffering none -blocking no
exit 0

proc SockRead s {
	if {[gets $s line] < 0} {
		close $s
		set ::forever 1
		return
	}

	puts $line
}

vwait forever
