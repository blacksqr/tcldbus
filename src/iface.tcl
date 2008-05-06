# $Id$
# Low-level logical (script) interface to D-Bus.

proc ::dbus::endpoint args {
	if {[llength $args] < 1} {
		return -code error "wrong # args: should be\
			\"[lindex [info level 0] 0] ?options? address\""
	}

	set address [Pop args end]

	set bus 0
	set master 0
	set async ""
	set timeout 0
	set command ""
	set mechs [list]

	while {[llength $args] > 0} {
		set opt [Pop args]
		switch -- $opt {
			-bus     { set bus 1 }
			-server  { set master 1 }
			-async   { set async   [Pop args] }
			-timeout { set timeout [Pop args] }
			-command { set command [Pop args] }
			-mechanisms { set mechs [Pop args] }
			default {
				return -code error "Bad option \"$opt\":\
					must be one of -bus, -server, -async, -timeout,\
					-command or -mechanisms"
			}
		}
	}

	if {$master && $async != ""} {
		return -code error "Cannot use -async with -server"
	}

	if {$bus && !$master} {
		switch -- [string tolower $address] {
			system - systembus {
				set address [SystemBusName]
			}
			session - sessionbus {
				set address [SessionBusName]
			}
		}
	}
	# TODO fix error reporting; "empty address" is meaningless and
	# only has sense for system and session buses with address inferring.
	if {$address == ""} {
		return -code error "Empty address"
	}
	set dests [ParseServerAddress $address]
	if {$master && [llength $dests] != 2} {
		return -code error "Exactly one address must be specified when using -server"
	}

	if {$master} {
		ServerEndpoint $dests $bus $command $mechs $timeout
	} else {
		ClientEndpoint $dests $bus $command $mechs $timeout $async
	}
}

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

	set fields [list \
		[list 1 [list OBJECT_PATH {} $object]] \
		[list 2 [list STRING {} $iface]] \
		[list 3 [list STRING {} $member]]]

	if {$dest != ""} {
		lappend fields [list 6 [list STRING {} $dest]]
	}
	if {$insig != ""} {
		lappend fields [list 8 [list SIGNATURE {} $insig]]
	}

	foreach chunk [MarshalMessage 1 $flags $serial $fields $mlist $args] {
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

	set flags [expr {$ignore | $noautostart}]
	set serial [NextSerial $chan]

	if {$obj != ""} {
		lappend fields [list 1 [list OBJECT_PATH {} $obj]]
	}

	lappend fields [list 5 [list UINT32 {} $replyserial]]

	if {$dest != ""} {
		lappend fields [list 6 [list STRING {} $dest]]
	}

	if {$sig != ""} {
		if {[catch {SigParseCached $sig} mlist]} {
			return -code error "Bad signature: $mlist"
		}
		lappend fields [list 8 [list SIGNATURE {} $sig]]
	} else {
		set mlist [list]
	}

	foreach chunk [MarshalMessage 2 $flags $serial $fields $mlist $args] {
		puts -nonewline $chan $chunk
	}
}

proc ::dbus::fail {chan errorname replyserial args} {
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

	set flags [expr {$ignore | $noautostart}]
	set serial [NextSerial $chan]

	if {$obj != ""} {
		lappend fields [list 1 [list OBJECT_PATH {} $obj]]
	}

	lappend fields [list 4 [list STRING {} $errorname]]
	lappend fields [list 5 [list UINT32 {} $replyserial]]

	if {$dest != ""} {
		lappend fields [list 6 [list STRING {} $dest]]
	}

	if {$sig != ""} {
		if {[catch {SigParseCached $sig} mlist]} {
			return -code error "Bad signature: $mlist"
		}
		lappend fields [list 8 [list SIGNATURE {} $sig]]
	} else {
		set mlist [list]
	}

	foreach chunk [MarshalMessage 3 $flags $serial $fields $mlist $args] {
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

	set fields [list \
		[list 1 [list OBJECT_PATH {} $object]] \
		[list 2 [list STRING {} $iface]] \
		[list 3 [list STRING {} $member]]]

	if {$dest != ""} {
		lappend fields [list 6 [list STRING {} $dest]]
	}
	if {$sig != ""} {
		lappend fields [list 8 [list SIGNATURE {} $sig]]
	}

	foreach chunk [MarshalMessage 4 $flags $serial $fields $mlist $args] {
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

