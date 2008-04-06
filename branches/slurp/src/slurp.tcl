# $Id$
# Unmarshaling messages from D-Bus input stream

proc ::dbus::IEEEToDouble {data LE} {
	if {$LE} {
		binary scan $data cccccccc f7 f6 f5 f4 f3 f2 e2f1 se1
	} else {
		binary scan $data cccccccc se1 e2f1 f2 f3 f4 f5 f6 f7
	}

	set se1 [expr {($se1 + 0x100) % 0x100}]
	set e2f1 [expr {($e2f1 + 0x100) % 0x100}]
	set f2 [expr {($f2 + 0x100) % 0x100}]
	set f3 [expr {($f3 + 0x100) % 0x100}]
	set f4 [expr {($f4 + 0x100) % 0x100}]
	set f5 [expr {($f5 + 0x100) % 0x100}]
	set f6 [expr {($f6 + 0x100) % 0x100}]
	set f7 [expr {($f7 + 0x100) % 0x100}]

	set sign [expr {$se1 >> 7}]
	set exponent [expr {(($se1 & 0x7f) << 4 | ($e2f1 >> 4))}]
	set f1 [expr {$e2f1 & 0x0f}]

	if {$exponent == 0} {
		set res 0.0
	} else {
		set fraction [expr {double($f1)*0.0625 + \
							double($f2)*0.000244140625 + \
							double($f3)*9.5367431640625e-07 + \
							double($f4)*3.7252902984619141e-09 + \
							double($f5)*1.4551915228366852e-11 + \
							double($f6)*5.6843418860808015e-14 + \
							double($f7)*2.2204460492503131e-16}]

		set res [expr {($sign ? -1. : 1.) * \
						pow(2.,double($exponent-1023)) * \
						(1. + $fraction)}]
	}

	return $res
}

proc ::dbus::StreamTearDown {chan reason} {
	variable $chan; upvar 0 $chan state
	upvar 0 state(command) command

	close $chan

	if {[info exists command]} {
		set cmd [list $command $chan receive error $reason]
	} else {
		set cmd [MyCmd streamerror $chan receive error $reason]
	}
	unset state
	uplevel #0 $cmd

	# This catch-all command is needed in case the user redefined
	# ::dbus::streamerror so that it does not raise an error
	return -code error $reason
}

proc ::dbus::MalformedStream {chan reason} {
	append s "Malformed incoming D-Bus stream from " $chan ": " $reason
	StreamTearDown $chan $s
}

proc ::dbus::streamerror {chan mode status message} {
	return -code error $message
}

proc ::dbus::ChanRead {chan n script} {
	variable $chan; upvar 0 $chan state

	set state(buffer)   ""
	set state(expected) $n
	set state(wanted)   $n
	set state(script)   $script
}

proc ::dbus::ChanAppend {chan n script} {
	variable $chan; upvar 0 $chan state

	incr state(expected) $n
	incr state(wanted)   $n
	set state(script)   $script
}

proc ::dbus::ChanAsyncRead chan {
	if {[eof $chan]} {
		StreamTearDown $chan "unexpected remote disconnect"
	}

	variable $chan; upvar 0 $chan state
	upvar 0 state(buffer) buffer state(wanted) wanted

	append buffer [read $chan $wanted]
	set wanted [expr {[string length $buffer] - $state(expected)}]
	if {$wanted == 0} {
		eval [linsert $state(script) end $buffer]
	}
}

proc ::dbus::PadSize {len n} {
	set x [expr {$len % $n}]
	if {$x} {
		expr {$n - $x}
	} else {
		return 0
	}
}

proc ::dbus::PadSizeType {len type} {
	variable paddings
	set n $paddings($type)

	set x [expr {$len % $n}]
	if {$x} {
		expr {$n - $x}
	} else {
		return 0
	}
}

proc ::dbus::BufRead {buf n ixVar} {
	upvar 1 $ixVar ix

	set from $ix
	incr ix $n
	string range $buf $from [expr {$ix - 1}]
}

namespace eval ::dbus {
	variable unmarshalers
	array set unmarshalers {
		BYTE         UnmarshalByte
		BOOLEAN      UnmarshalBoolean
		INT16        UnmarshalInt16
		UINT16       UnmarshalUint16
		INT32        UnmarshalInt32
		UINT32       UnmarshalUint32
		INT64        UnmarshalInt64
		UINT64       UnmarshalUint64
		DOUBLE       UnmarshalDouble
		STRING       UnmarshalString
		OBJECT_PATH  UnmarshalObjectPath
		SIGNATURE    UnmarshalSignature
		VARIANT      UnmarshalVariant
		HEADER_FIELD UnmarshalHeaderField
		STRUCT       UnmarshalStruct
		ARRAY        UnmarshalArray
	}
	variable field_types
	array set field_types {
		1  {PATH          {OBJECT_PATH {}}  IsValidObjectPath}
		2  {INTERFACE     {STRING      {}}  IsValidInterfaceName}
		3  {MEMBER        {STRING      {}}  IsValidMemberName}
		4  {ERROR_NAME    {STRING      {}}  IsValidInterfaceName}
		5  {REPLY_SERIAL  {UINT32      {}}  IsValidSerial}
		6  {DESTINATION   {STRING      {}}  IsValidBusName}
		7  {SENDER        {STRING      {}}  IsValidBusName}
		8  {SIGNATURE     {SIGNATURE   {}}  IsValidSignature}
	}
	# Required header fields for different types of messages
	# (this is a list indexed by message type code (1..4)):
	variable required_fields {
		{}
		{PATH  MEMBER}
		{REPLY_SERIAL}
		{REPLY_SERIAL  ERROR_NAME}
		{PATH  MEMBER  INTERFACE}
	}
}

proc ::dbus::UnmarshalPadding {buf n ixVar} {
	upvar 1 $ixVar ix

	set pad [PadSize $ix $n]
	if {$pad > 0} {
		if {![regexp {^\0+$} [BufRead $buf $pad ix]]} {
			MalformedStream $chan "non-zero padding"
		}
	}
}

proc ::dbus::UnmarshalByte {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	binary scan $buf @${ix}c byte
	incr ix
	set byte
}

proc ::dbus::UnmarshalBoolean {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	set data [UnmarshalInt32 $buf $LE {} ix]
	if {0 < $data || $data > 1} {
		MalformedStream $chan "malformed boolean value"
	}
	set data
}

proc ::dbus::UnmarshalInt16 {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	UnmarshalPadding $buf 2 ix
	append fmt @ $ix [expr {$LE ? "s" : "S"}]
	binary scan $buf $fmt data
	incr ix 2
	set data
}

proc ::dbus::UnmarshalUint16 {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	expr {[UnmarshalInt16 $buf $LE {} ix] & 0xFFFFFFFF}
}

proc ::dbus::UnmarshalInt32 {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	UnmarshalPadding $buf 4 ix
	append fmt @ $ix [expr {$LE ? "i" : "I"}]
	binary scan $buf $fmt data
	incr ix 4
	set data
}

proc ::dbus::UnmarshalUint32 {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	expr {[UnmarshalInt32 $buf $LE {} ix] & 0xFFFFFFFF}
}

proc ::dbus::UnmarshalInt64 {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	UnmarshalPadding $buf 8 ix
	append fmt @ $ix [expr {$LE ? "w" : "W"}]
	binary scan $buf $fmt data
	incr ix 8
	set data
}

proc ::dbus::UnmarshalUint64 {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	expr {[UnmarshalInt64 $buf $LE {} ix] & 0xFFFFFFFFFFFFFFFF}
}

proc ::dbus::UnmarshalDouble {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	UnmarshalPadding $buf 8
	IEEEToDouble [BufRead $buf 8 ix] $LE
}

proc ::dbus::UnmarshalString {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	set slen [UnmarshalUint32 $buf $LE {} ix]
	if {$slen > 0} {
		set data [BufRead $buf $slen ix]
		if {[string first \0 $data] > 0} {
			MalformedStream $chan "string contains NUL character"
		}
		set s [encoding convertfrom utf-8 $data]
	} else {
		set s ""
	}
	set nul  [UnmarshalByte $buf $LE {} ix]
	if {$nul != 0} {
		MalformedStream $chan "string is not terminated by NUL"
	}
	set s
}

proc ::dbus::UnmarshalObjectPath {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	set s [UnmarshalString $buf $LE {} ix]
	if {![IsValidObjectPath $s]} {
		MalformedStream $chan "invalid object path"
	}
	set s
}

# Unmarshals a signature from $chan, parses it and
# returns a "marshaling list" corresponding to it.
# This list can be empty if the signature was an empty string.
proc ::dbus::UnmarshalSignature {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	set slen [UnmarshalByte $buf $LE {} ix]
	if {$slen > 0} {
		# TODO do we need to convert it from ASCII?
		set sig [BufRead $buf $slen ix]
		if {[catch {SigParse $sig} mlist]} {
			MalformedStream $chan "bad signature"
		}
	} else {
		set mlist [list]
	}
	set nul [UnmarshalByte $buf $LE {} ix]
	if {$nul != 0} {
		MalformedStream $chan "signature is not terminated by NUL"
	}
	set mlist
}

# Unmarshals a variant from $chan.
# If $reqtype is not an empty string, it represents a
# type (in "marshaling list" format) that the value
# encapsulated in the variant must match.
proc ::dbus::UnmarshalVariant {buf LE reqtype ixVar} {
	upvar 1 $ixVar ix

	set mlist [UnmarshalSignature $buf $LE {} ix]

	if {[llength $mlist] != 2} {
		MalformedStream $chan "variant signature does not represent a single complete type"
	}

	if {$reqtype != ""} {
		if {![MarshalingListsAreEqual $mlist $reqtype]} {
			MalformedStream $chan "header field type mismatch"
		}
	}

	variable unmarshalers
	$unmarshalers([lindex $mlist 0]) $buf $LE [lindex $mlist 1] ix
}

proc ::dbus::MarshalingListsAreEqual {first second} {
	if {[llength $first] != 2 || [llength $second] != 2} {
		return 0
	} else {
		foreach {ftype fsubtype} $first {stype ssubtype} $second {
			if {[string equal $ftype $stype]} {
				return 1
			} else {
				return [MarshalingListsAreEqual $fsubtype $ssubtype]
			}
		}
	}
}

proc ::dbus::UnmarshalHeaderField {buf LE subtype ixVar} {
	upvar 1 $ixVar ix

	UnmarshalPadding $buf 8 ix

	set ftype [UnmarshalByte $buf $LE {} ix]

	variable field_types
	upvar 0 field_types($ftype) fdesc
	if {![info exists fdesc]} return ;# unknown field, skip it

	foreach {name type validator} $fdesc break

	set value [UnmarshalVariant $buf $LE $type ix]
	if {![$validator $value]} {
		MalformedStream $chan "invalid value of header field"
	}

	list $name $value
}

proc ::dbus::UnmarshalStruct {buf LE subtype ixVar} {
	upvar 1 $ixVar ix
	variable unmarshalers

	UnmarshalPadding $buf 8 ix

	set out [list]
	foreach {type stype} $subtype {
		lappend out [$unmarshalers($type) $buf $LE $stype ix]
	}
	set out
}

proc ::dbus::UnmarshalArray {buf LE etype ixVar} {
	upvar 1 $ixVar ix

	set alen [UnmarshalUint32 $buf $LE {} ix]
	if {$alen == 0} {
		return
	} elseif {$alen > 0x04000000} {
		MalformedStream $chan "array length exceeds limit"
	}

	UnmarshalArrayElements $buf $LE $etype $alen ix
}

proc ::dbus::UnmarshalArrayElements {buf LE etype alen ixVar} {
	upvar 1 $ixVar ix

	foreach {nestlvl type subtype} $etype break

	set out [list]
	if {$nestlvl == 1} {
		variable unmarshalers
		upvar 0 unmarshalers($type) unmarshaler
		set end [expr {$ix + $alen + [PadSizeType $ix $type]}]
		while {$ix < $end} {
			lappend out [$unmarshaler $buf $LE $subtype ix]
		}
		set ix $end
	} else {
		lset etype 0 [expr {$nestlvl - 1}]
		set end [expr {$ix + $alen}]
		while {$ix < $end} {
			lappend out [UnmarshalArray $buf $LE $etype ix]
		}
	}
	set out
}

proc ::dbus::UnmarshalList {buf LE mlist ixVar} {
	upvar 1 $ixVar ix

	variable unmarshalers
	set out [list]
	foreach {type subtype} $mlist {
		lappend out [$unmarshalers($type) $buf $LE $subtype ix]
	}
	set out
}

proc ::dbus::ReadMessages chan {
	$chan [MyCmd ChanAsyncRead $chan]

	ReadNextMessage $chan
}

proc ::dbus::ReadNextMessage chan {
	puts [lindex [info level 0] 0]

	ChanRead $chan 16 [list ProcessHeaderPrologue $chan]
}

proc ::dbus::ProcessHeaderPrologue {chan header} {
	puts [lindex [info level 0] 0]

	variable proto_major

	binary scan $header accc bytesex msgtype flags proto
	if {$proto > $proto_major} {
		MalformedStream $chan "unsupported protocol version"
	}
	if {$msgtype < 1} {
		MalformedStream $chan "invalid message type"
	}
	switch -- $bytesex {
		l { set LE 1; set fmt @4iii }
		B { set LE 0; set fmt @4III }
		default {
			MalformedStream $chan "invalid bytesex specifier"
		}
	}

	binary scan $header $fmt bodysize serial fsize
	set bodysize [expr {$bodysize & 0xFFFFFFFF}]
	set serial [expr {$serial & 0xFFFFFFFF}]
	set fsize [expr {$fsize & 0xFFFFFFFF}]

	if {$fsize > 0x04000000} {
		MalformedStream $chan "array length exceeds limit"
	}

	ChanRead $chan $fsize [list \
		ProcessHeaderFields $chan $LE $msgtype $flags $bodysize $serial]
}

proc ::dbus::ProcessHeaderFields {chan LE msgtype flags bsize serial data} {
	puts [lindex [info level 0] 0]

	set hdr [list]
	array set fields {}
	set ix 0
	foreach item [UnmarshalArrayElements \
			$data $LE {1 HEADER_FIELD {}} [string length $data] ix] {
		foreach {key val} $item break
		lappend hdr $key $val
		set fields($key) $val
	}

	if {$msgtype <= 4} { # Check for required fields
		variable required_fields
		foreach req [lindex $required_fields $msgtype] {
			if {![info exists fields($req)]} {
				MalformedStream $chan "missing required header field"
			}
		}
	}

	if {$bsize == 0} {
		if {[info exists fields(SIGNATURE)]} {
			MalformedStream $chan "signature present while body size is 0"
		} else return
	}

	# TODO is $bsize == 0 we should directly call something like
	# PostProcessMessage

	set pad [PadSize $ix 8]
	if {$pad > 0} {
		ChanRead $chan $pad [list \
			ProcessMessageBodyPadding $chan $LE $msgtype $flags $bsize $serial $hdr]
	} else {
		ChanRead $chan $bsize [list \
			ProcessMessageBody $chan $LE $msgtype $flags $serial $hdr]
	}
}

proc ::dbus::ProcessMessageBodyPadding {chan LE msgtype flags bsize serial fields padding} {
	puts [lindex [info level 0] 0]

	if {![regexp {^\0+$} $padding]} {
		MalformedStream $chan "non-zero padding"
	}

	ChanRead $chan $bsize [list \
		ProcessMessageBody $chan $LE $msgtype $flags $serial $fields]
}

proc ::dbus::ProcessMessageBody {chan LE msgtype flags serial hdr body} {
	puts [lindex [info level 0] 0]

	array set fields $hdr
	parray fields

	if {[info exists fields(SIGNATURE)]} {
		set ix 0
		set parts [UnmarshalList $body $LE $fields(SIGNATURE) ix]
		puts $parts
	}

#	ProcessArrivedResult $chan $serial

	ReadNextMessage $chan
}

