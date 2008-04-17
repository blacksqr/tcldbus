# $Id$
# Low-level logical (script) interface to D-Bus.

proc ::dbus::invoke {chan object imethod args} {
	set dest ""
	set insig ""
	set outsig ""
	set command ""
	set ignore 0
	set noautostart 0
	set timeout 0

	while {[string match -* [lindex $args 0]]} {
		set opt [Pop args]
		switch -- $opt {
			-destination  { set dest [Pop args] }
			-in           { set insig [Pop args] }
			-out          { set outsig [Pop args] }
			-command      { set command [Pop args] }
			-ignoreresult { set ignore 1 }
			-noautostart  { set noautostart 2 }
			-timeout      { set timeout [Pop args] }
			--            { break }
			default {
				return -code error "Bad option \"$opt\":\
					must be one of -destination, -in, -out, -command, -ignoreresult,\
					-noautostart or -timeout"
			}
		}
	}

	if {$ignore && ($outsig != "" || $command != "")} {
		return -code error "-ignoreresult contradicts -out and -command"
	}

	if {![SplitMemberName $imethod iface member]} {
		return -code error "Malformed interfaced method name: \"$imethod\""
	}

	if {[catch {SigParseCached $insig} mlist]} {
		return -code error "Bad input signature: $mlist"
	}
	if {[catch {SigParseCached $outsig} err]} {
		return -code error "Bad output signature: $err"
	}

	set flags [expr {$ignore | $noautostart}]
	set serial [NextSerial $chan]

	foreach chunk [MarshalMessage \
			1 $flags $serial $dest $object $iface $member $insig $mlist $args] {
		puts -nonewline $chan $chunk
	}

	if {$ignore} return

	if {$command != ""} {
		ExpectMethodReply $chan $serial $timeout $command
		return
	} else {
		set rvpoint [ExpectMethodReply $chan $serial $timeout ""]
		puts "waiting on <$rvpoint>..."
		vwait $rvpoint
		puts "Got answer: [set $rvpoint]"
		foreach {status code result} [set $rvpoint] break
		unset $rvpoint
		return -code $status -errorcode $code $result
	}
}

proc ::dbus::reply {chan replyserial args} {
	set dest ""
	set obj ""
	set sig ""
	set ignore 0
	set noautostart 0

	while {[string match -* [lindex $args 0]]} {
		set opt [Pop args]
		switch -- $opt {
			-destination  { set dest [Pop args] }
			-object       { set obj  [Pop args] }
			-signature    { set sig  [Pop args] }
			-ignoreresult { set ignore 1 }
			-noautostart  { set noautostart 2 }
			--            { break }
			default {
				return -code error "Bad option \"$opt\":\
					must be one of -destination, -object, -signature,\
					-ignoreresult or -noautostart"
			}
		}
	}

	if {[catch {SigParseCached $sig} mlist]} {
		return -code error "Bad signature: $mlist"
	}

	set flags [expr {$ignore | $noautostart}]
	set serial [NextSerial $chan]

	# TODO there's no way to pass REPLY_SERIAL to this method...
	foreach chunk [MarshalMessage \
			2 $flags $serial $dest $object $iface $member $sig $mlist $args] {
		puts -nonewline $chan $chunk
	}
}

proc ::dbus::emit {chan object imethod args} {
	set dest ""
	set sig ""
	set ignore 0
	set noautostart 0

	while {[string match -* [lindex $args 0]]} {
		set opt [Pop args]
		switch -- $opt {
			-destination  { set dest [Pop args] }
			-signature    { set sig  [Pop args] }
			-ignoreresult { set ignore 1 }
			-noautostart  { set noautostart 2 }
			--            { break }
			default {
				return -code error "Bad option \"$opt\":\
					must be one of -destination, -signature, -ignoreresult\
					or -noautostart"
			}
		}
	}

	if {![SplitMemberName $imethod iface member]} {
		return -code error "Malformed interfaced method name: \"$imethod\""
	}
	if {$iface == ""} {
		return -code error "No interface name provided"
	}

	if {[catch {SigParseCached $sig} mlist]} {
		return -code error "Bad signature: $mlist"
	}

	set flags [expr {$ignore | $noautostart}]
	set serial [NextSerial $chan]

	foreach chunk [MarshalMessage \
			4 $flags $serial $dest $object $iface $member $sig $mlist $args] {
		puts -nonewline $chan $chunk
	}
}

proc ::dbus::trap {chan imethod command args} {
	set src ""
	set sig ""
	set obj ""

	while {[llength $args] > 0} {
		set opt [Pop args]
		switch -- $opt {
			-source    { set src [Pop args] }
			-signature { set sig [Pop args] }
			-object    { set obj [Pop args] }
			default {
				return -code error "Bad option \"$opt\":\
					must be one of -source, -signature or -object"
			}
		}
	}

	if {![SplitMemberName $imethod iface member]} {
		return -code error "Malformed interfaced method name: \"$imethod\""
	}

	if {[catch {SigParseCached $sig} mlist]} {
		return -code error "Bad input signature: $mlist"
	}

	# TODO register the trap
}

proc ::dbus::remoteproc {name imethod signature args} {
	if {![string match ::* $name]} {
		set ns [uplevel 1 namespace current]
		if {![string equal $ns ::]} {
			append ns ::
		}
		set name $ns$name
	}

	if {[info commands $name] != ""} {
		return -code error  "Command name \"$name\" already exists"
	}

	if {![SplitMethodName $imethod iface method]} {
		return -code error "Bad method name \"$imethod\""
	}
	SigParseCached $signature ;# validate and cache

	set dest ""
	set obj  ""
	foreach {opt val} $args {
		switch -- $opt {
			-destination { set dest $val }
			-object      { set obj  $val }
			default      {
				return -code error "Bad option \"$opt\":\
					must be one of -destination or -object"
			}
		}
	}

	set params chan
	if {$dest == ""} {
		lappend params destination
		set dest \$destination
	}
	if {$obj  == ""} {
		lappend params object
		set obj \$object
	}
	lappend params args

	if 0 {
	proc $name $params [string map [list \
			@dest      $dest \
			@obj       $obj \
			@iface     $iface \
			@method    $method \
			@signature $signature] {
		::dbus::Invoke $chan @dest @obj @iface @method @signature $args
	}]
	}

	append body ::dbus::Invoke " " \$chan
	foreach item {dest obj iface method signature} {
		if {[set $item] != ""} {
			append body " " [set $item]
		} else {
			append body " " {{}}
		}
	}
	append body " " \$args

	proc $name $params $body
}

