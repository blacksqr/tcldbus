# $Id$
# Unmarshaling messages from D-Bus input stream

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
	variable unmarshals
	array set unmarshals {
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
		STRUCT       UnmarshalStruct
		ARRAY        UnmarshalArray
	}
}

proc ::dbus::UnmarshalPadding {chan n lenVar} {
	upvar 1 $lenVar len

	set pad [PadSize $len $n]
	if {$pad > 0} {
		set data [ChanRead $chan $pad len]
		if {[string first \0 $data] > 0} {
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

	set data [UnmarshalInt32 $chan $LE $subtype len]
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

	expr {[UnmarshalInt16 $chan $LE $subtype len] & 0xFFFFFFFF}
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

	expr {[UnmarshalInt32 $chan $LE $subtype len] & 0xFFFFFFFF}
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

	expr {[UnmarshalInt64 $chan $LE $subtype len] & 0xFFFFFFFFFFFFFFFF}
}

proc ::dbus::UnmarshalDouble {chan LE subtype lenVar} {
	error "NOT IMPLEMENTED"
}

proc ::dbus::UnmarshalString {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	set slen [UnmarshalUint32 $chan $LE $subtype len]
	if {$slen > 0} {
		set s [encoding convertfrom utf-8 [ChanRead $chan $slen len]]
	} else {
		set s ""
	}
	set nul  [UnmarshalByte $chan $LE $subtype len]
	if {$nul != 0} {
		MalformedStream $chan "string is not terminated by NUL"
	}
	set s
}

proc ::dbus::UnmarshalObjectPath {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	set s [UnmarshalString $chan $LE $subtype len]
	if {![IsValidObjectPath $s]} {
		MalformedStream $chan "invalid object path"
	}
	set s
}

proc ::dbus::UnmarshalSignature {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	set slen [UnmarshalByte $chan $LE $subtype len]
	if {$slen > 0} {
		# TODO do we need to convert it from ASCII?
		set sig  [ChanRead $chan $slen len]
	} else {
		set sig ""
	}
	set nul  [UnmarshalByte $chan $LE $subtype len]
	if {$nul != 0} {
		MalformedStream $chan "signature is not terminated by NUL"
	}
	set sig
}

proc ::dbus::UnmarshalVariant {chan LE subtype lenVar} {
	upvar 1 $lenVar len

	set sig [UnmarshalSignature $chan $LE $subtype len]
	# TODO validate signature is single complete type
	variable smap
	variable unmarshals
	$unmarshals($smap($sig)) $chan $LE $subtype len
}

proc ::dbus::UnmarshalStruct {chan LE subtype lenVar} {
	upvar 1 $lenVar len
	variable unmarshals

	UnmarshalPadding $chan 8 len

	set out [list]
	foreach {type stype} $subtype {
		lappend out [$unmarshals($type) $chan $LE $stype len]
	}
	set out
}

proc ::dbus::UnmarshalArray {chan LE etype lenVar} {
	upvar 1 $lenVar len

	set alen [UnmarshalUint32 $chan $LE {} len]
	if {$alen == 0} {
		return
	} elseif {$alen > 0x1000000} {
		MalformedStream $chan "array length exceeds limit"
	}

	foreach {nestlvl type subtype} $etype break

	set out [list]
	if {$nestlvl == 1} {
		variable unmarshals
		upvar 0 unmarshals($type) unmarshal
		set end [expr {$len + $alen + [PadSizeType $len $type]}]
		while {$len < $end} {
			lappend out [$unmarshal $chan $LE $subtype len]
		}
		set len $end
	} else {
		error "UNMARSHALING OF NESTED ARRAYS IS NOT IMPLEMENTED"
	}
	set out
}

proc ::dbus::ReadNextMessage chan {
	variable $chan; upvar 0 $chan state
	upvar 0 state(len) len
	variable proto_major

	$chan [MyCmd ChanAsyncRead $chan]

	set len 0
	set header [ChanRead $chan 12 len]

	binary scan $header accc bytesex type flags proto
	if {$proto > $proto_major} {
		MalformedStream $chan "unsupported protocol version"
	}
	if {$type < 1 || $type > 4} {
		MalformedStream $chan "unknown message type"
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

	set fields [UnmarshalArray $chan $LE {1 STRUCT {BYTE {} VARIANT {}}} len]

	set flen 0 ;# TODO we don't know the lentgh of the array body
	set full [expr {$bodysize + $flen}]
	if {$full + [PadSize $full 8] > 0x4000000} {
		MalformedStream $chan "message length exceeds limit"
	}

	puts "Header fields: <[join $fields {, }]>"

	if {$bodysize == 0} return

	puts "skipping $bodysize bytes of body..."
	UnmarshalPadding $chan 8 len
	ChanRead $chan $bodysize len

	$chan [MyCmd ReadNextMessage $chan]
}

