package require ceptcl

catch { file delete /tmp/dbus_test }
set s [cep -domain local -server foo /tmp/dbus_test]
proc foo {chan args} {
	fconfigure $chan -buffering none
	puts -nonewline $chan [string repeat x 65536]
	puts -nonewline $chan [string repeat x 65536]
	puts -nonewline $chan [string repeat x 65536]
}

vwait forever
