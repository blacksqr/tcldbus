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

proc ::dbus::ChanRead {chan n lenVar} {
	variable $chan; upvar 0 $chan state
	upvar 1 $lenVar len

	set state(buffer)   ""
	set state(expected) $n
	set state(wanted)   $n

	vwait [namespace current]::${chan}(chunk)
	incr len $state(expected)
	set state(chunk)
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
		set state(chunk) $buffer
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

proc ::dbus::UnmarshalPadding {chan n lenVar} {
	upvar 1 $lenVar len

	set pad [PadSize $len $n]
	if {$pad > 0} {
		if {![regexp {^\0+$} [ChanRead $chan $pad len]]} {
			MalformedStream $chan "non-zero padding"
		}
	}
}

proc ::dbus::UnmarshalByte {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	binary scan [ChanRead $chan 1 len] c byte
	set byte
}

proc ::dbus::UnmarshalBoolean {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	set data [UnmarshalInt32 $chan $LE {} len]
	if {0 < $data || $data > 1} {
		MalformedStream $chan "malformed boolean value"
	}
	set data
}

proc ::dbus::UnmarshalInt16 {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	UnmarshalPadding $chan 2 len
	set fmt [expr {$LE ? "s" : "S"}]
	binary scan [ChanRead $chan 2 len] $fmt data
	set data
}

proc ::dbus::UnmarshalUint16 {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	expr {[UnmarshalInt16 $chan $LE {} len] & 0xFFFFFFFF}
}

proc ::dbus::UnmarshalInt32 {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	UnmarshalPadding $chan 4 len
	set fmt [expr {$LE ? "i" : "I"}]
	binary scan [ChanRead $chan 4 len] $fmt data
	set data
}

proc ::dbus::UnmarshalUint32 {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	expr {[UnmarshalInt32 $chan $LE {} len] & 0xFFFFFFFF}
}

proc ::dbus::UnmarshalInt64 {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	UnmarshalPadding $chan 8 len
	set fmt [expr {$LE ? "w" : "W"}]
	binary scan [ChanRead $chan 8 len] $fmt data
	set data
}

proc ::dbus::UnmarshalUint64 {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	expr {[UnmarshalInt64 $chan $LE {} len] & 0xFFFFFFFFFFFFFFFF}
}

proc ::dbus::UnmarshalDouble {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	UnmarshalPadding $chan 8
	IEEEToDouble [ChanRead $chan 8 len] $LE
}

proc ::dbus::UnmarshalString {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	set slen [UnmarshalUint32 $chan $LE {} len]
	if {$slen > 0} {
		set data [ChanRead $chan $slen len]
		if {[string first \0 $data] > 0} {
			MalformedStream $chan "string contains NUL character"
		}
		set s [encoding convertfrom utf-8 $data]
	} else {
		set s ""
	}
	set nul  [UnmarshalByte $chan $LE {} len]
	if {$nul != 0} {
		MalformedStream $chan "string is not terminated by NUL"
	}
	set s
}

proc ::dbus::UnmarshalObjectPath {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	set s [UnmarshalString $chan $LE {} len]
	if {![IsValidObjectPath $s]} {
		MalformedStream $chan "invalid object path"
	}
	set s
}

# Unmarshals a signature from $chan, parses it and
# returns a "marshaling list" corresponding to it.
# This list can be empty if the signature was an empty string.
proc ::dbus::UnmarshalSignature {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	set slen [UnmarshalByte $chan $LE {} len]
	if {$slen > 0} {
		# TODO do we need to convert it from ASCII?
		set sig [ChanRead $chan $slen len]
		if {[catch {SigParse $sig} mlist]} {
			MalformedStream $chan "bad signature"
		}
	} else {
		set mlist [list]
	}
	set nul [UnmarshalByte $chan $LE {} len]
	if {$nul != 0} {
		MalformedStream $chan "signature is not terminated by NUL"
	}
	set mlist
}

# Unmarshals a variant from $chan.
# If $reqtype is not an empty string, it represents a
# type (in "marshaling list" format) that the value
# encapsulated in the variant must match.
proc ::dbus::UnmarshalVariant {chan LE reqtype lenVar} {
	upvar 1 $lenVar len

	set mlist [UnmarshalSignature $chan $LE {} len]

	if {[llength $mlist] != 2} {
		MalformedStream $chan "variant signature does not represent a single complete type"
	}

	if {$reqtype != ""} {
		if {![MarshalingListsAreEqual $mlist $reqtype]} {
			MalformedStream $chan "header field type mismatch"
		}
	}

	variable unmarshalers
	$unmarshalers([lindex $mlist 0]) $chan $LE [lindex $mlist 1] len
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

proc ::dbus::UnmarshalHeaderField {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	UnmarshalPadding $chan 8 len

	set ftype [UnmarshalByte $chan $LE {} len]

	variable field_types
	upvar 0 field_types($ftype) fdesc
	if {![info exists fdesc]} return ;# unknown field, skip it

	foreach {name type validator} $fdesc break

	set value [UnmarshalVariant $chan $LE $type len]
	if {![$validator $value]} {
		MalformedStream $chan "invalid value of header field"
	}

	list $name $value
}

proc ::dbus::UnmarshalStruct {chan LE subtype lenVar} {
	upvar 1 $lenVar len
	variable unmarshalers

	UnmarshalPadding $chan 8 len

	set out [list]
	foreach {type stype} $subtype {
		lappend out [$unmarshalers($type) $chan $LE $stype len]
	}
	set out
}

proc ::dbus::UnmarshalArray {chan LE etype lenVar} {
	upvar 1 $lenVar len

	set alen [UnmarshalUint32 $chan $LE {} len]
	if {$alen == 0} {
		return
	} elseif {$alen > 0x04000000} {
		MalformedStream $chan "array length exceeds limit"
	}

	foreach {nestlvl type subtype} $etype break

	set out [list]
	if {$nestlvl == 1} {
		variable unmarshalers
		upvar 0 unmarshalers($type) unmarshaler
		set end [expr {$len + $alen + [PadSizeType $len $type]}]
		while {$len < $end} {
			lappend out [$unmarshaler $chan $LE $subtype len]
		}
		set len $end
	} else {
		lset etype 0 [expr {$nestlvl - 1}]
		set end [expr {$len + $alen}]
		while {$len < $alen} {
			lappend out [UnmarshalArray $chan $LE $etype len]
		}
	}
	set out
}

proc ::dbus::UnmarshalList {chan LE mlist lenVar} {
	upvar 1 $lenVar len

	variable unmarshalers
	set out [list]
	foreach {type subtype} $mlist {
		lappend out [$unmarshalers($type) $chan $LE $subtype len]
	}
	set out
}

proc ::dbus::UnmarshalHeaderFields {chan LE msgtype fieldsVar lenVar} {
	upvar 1 $fieldsVar fields $lenVar len

	array set fields {}
	foreach item [UnmarshalArray $chan $LE {1 HEADER_FIELD {}} len] {
		set fields([lindex $item 0]) [lindex $item 1]
	}

	if {$msgtype > 4} return ;# ignore message of unknown type

	variable required_fields
	foreach req [lindex $required_fields $msgtype] {
		if {![info exists fields($req)]} {
			MalformedStream $chan "missing required header field"
		}
	}
}

proc ::dbus::ReadMessages chan {
	$chan [MyCmd ChanAsyncRead $chan]

	while 1 {
		ReadNextMessage $chan
	}
}

proc ::dbus::ReadNextMessage chan {
	variable $chan; upvar 0 $chan state
	upvar 0 state(len) len
	variable proto_major

	set len 0
	set header [ChanRead $chan 12 len]

	binary scan $header accc bytesex msgtype flags proto
	if {$proto > $proto_major} {
		MalformedStream $chan "unsupported protocol version"
	}
	if {$msgtype < 1} {
		MalformedStream $chan "invalid message type"
	}
	switch -- $bytesex {
		l { set LE 1; set fmt @4ii }
		B { set LE 0; set fmt @4II }
		default {
			MalformedStream $chan "invalid bytesex specifier"
		}
	}

	binary scan $header $fmt bodysize serial
	set bodysize [expr {$bodysize & 0xFFFFFFFF}]
	set serial [expr {$serial & 0xFFFFFFFF}]

	# TODO we should pass it a "maximum length" value
	# calculated from message size limit and $bodysize.
	# In this case the size check below will be unnecessary.
	UnmarshalHeaderFields $chan $LE $msgtype fields len

	set full [expr {$len + [PadSize $len 8] + $bodysize}]
	if {$full > 0x08000000} {
		MalformedStream $chan "message length exceeds limit"
	}

	if {$bodysize == 0} {
		if {[info exists fields(SIGNATURE)]} {
			MalformedStream $chan "signature present while body size is 0"
		} else return
	}

	UnmarshalPadding $chan 8 len
	set body [UnmarshalList $chan $LE $fields(SIGNATURE) len]

	ProcessArrivedResult $chan $serial
}

