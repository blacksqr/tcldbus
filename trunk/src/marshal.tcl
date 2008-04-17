# $Id$
# Wire marshaling/unmarshaling.

# TODO some points about marshaling aren't clear:
# * Are empty structs allowed?
# * Are variants containing variants allowed?
# * Are array elements packed or they're subject to the same alignment
#   issues as "regular" marshaled values?

# Convert double precision floating point values to
# the IEEE754 format and back.
# Courtesy of Frank Pilhofer (fpilhofe_at_mc.com)
# See http://wiki.tcl.tk/756
# and http://coding.derkeiler.com/Archive/Tcl/comp.lang.tcl/2004-10/0664.html

# TODO [binary] in Tcl >= 8.5 is able to do this transformation natively;
# moreover, many today's hardware is beleived to implement floats already in
# IEEE754 format, eliminating the need for the conversion.
# We should implement generation of [MarshalDouble] and [UnmarshalDouble]
# upon package loading; code should use 8.5 features if possible.

# TODO the same is also true for integers: possibly the whole idea of bytesex
# in D-Bus is to make transfers on the same physical host as fast as possible
# by using native byte order. Tcl >= 8.5 is able to [binary format] integers
# using native byte order, which is what we probably need.

proc ::dbus::DoubleToIEEE value {
	if {$value > 0} {
		set sign 0
	} else {
		set sign 1
		set value [expr {-1. * $value}]
	}

	# If the following math fails, then it's because of the logarithm.
	# That means that value is indistinguishable from zero
	if {[catch {
		set exponent [expr {int(floor(log($value)/0.69314718055994529))+1023}]
		set fraction [expr {($value/pow(2.,double($exponent-1023)))-1.}]
	}]} {
		set exponent 0
		set fraction 0.0
	} else {
		# round off too-small values to zero, throw error for too-large values
		if {$exponent < 0} {
			set exponent 0
			set fraction 0.0
		} elseif {$exponent > 2047} {
			return -code error "Value $value outside legal range for a float"
		}
	}

	set fraction [expr {$fraction * 16.}]
	set f1f      [expr {floor($fraction)}]

	set fraction [expr {($fraction - $f1f) * 256.}]
	set f2f      [expr {floor($fraction)}]

	set fraction [expr {($fraction - $f2f) * 256.}]
	set f3f      [expr {floor($fraction)}]

	set fraction [expr {($fraction - $f3f) * 256.}]
	set f4f      [expr {floor($fraction)}]

	set fraction [expr {($fraction - $f4f) * 256.}]
	set f5f      [expr {floor($fraction)}]

	set fraction [expr {($fraction - $f5f) * 256.}]
	set f6f      [expr {floor($fraction)}]

	set fraction [expr {($fraction - $f6f) * 256.}]
	set f7f      [expr {floor($fraction)}]

	for {set i 1} {$i <= 7} {incr i} {
		set var f$i
		append var f
		set f$i [expr {int([set $var])}]
	}

	set se1 [expr {($sign ? 128 : 0) | ($exponent >> 4)}]
	set e2f1 [expr {(($exponent & 15) * 16) | $f1}]

	binary format cccccccc $f7 $f6 $f5 $f4 $f3 $f2 $e2f1 $se1
}

namespace eval ::dbus {
	variable marshalers
	array set marshalers {
		BYTE         MarshalByte
		BOOLEAN      MarshalBoolean
		INT16        MarshalInt16
		UINT16       MarshalInt16
		INT32        MarshalInt32
		UINT32       MarshalInt32
		INT64        MarshalInt64
		UINT64       MarshalInt64
		DOUBLE       MarshalDouble
		STRING       MarshalString
		OBJECT_PATH  MarshalString
		SIGNATURE    MarshalSignature
		VARIANT      MarshalVariant
		STRUCT       MarshalStruct
		ARRAY        MarshalArray
	}
	variable basictypes
	array set basictypes {
		BYTE       {}
		INT16      {}
		UINT16     {}
		INT32      {}
		UINT32     {}
		INT64      {}
		UINT64     {}
	}
	variable paddings
	array set paddings {
		BYTE         1
		BOOLEAN      4
		INT16        2
		UINT16       2
		INT32        4
		UINT32       4
		INT64        8
		UINT64       8
		DOUBLE       8
		STRING       4
		OBJECT_PATH  4
		SIGNATURE    4
		VARIANT      4
		HEADER_FIELD 8
		STRUCT       8
		ARRAY        0
	}
}

proc ::dbus::Pad {len n} {
	set x [expr {$len % $n}]
	if {$x} {
		binary format x[expr {$n - $x}]
	} else {
		return ""
	}
}

proc ::dbus::PadType {len type} {
	variable paddings
	Pad $len $paddings($type)
}

proc ::dbus::MarshalByte {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len

	lappend out [binary format c $value]
	incr len
}

proc ::dbus::MarshalBoolean {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 4] [binary format i [expr {!!$value}]]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalInt16 {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 2] [binary format s $value]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalInt32 {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 4] [binary format i $value]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalInt64 {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 8] [binary format w $value]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalDouble {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 8] [DoubleToIEEE $value]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalString {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len

	set blob [encoding convertto utf-8 $value]
	append s [Pad $len 4] [binary format i [string length $blob]] $blob \0
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalSignature {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len

	set blob [encoding convertto utf-8 $value]
	append s [binary format c [string length $blob]] $blob \0
	lappend out $s
	incr len [string length $s]
}

# $value must be a three-element list: {type subtype value}
proc ::dbus::MarshalVariant {outVar lenVar dummy value} {
	upvar 1 $outVar out $lenVar len
	variable srevmap
	variable marshalers

	foreach {type subtype val} $value break

	MarshalSignature out len {} $srevmap($type)
	$marshalers($type) out len $subtype $val
}

# $value must be an even list: {type value ?type value ...?}
proc ::dbus::MarshalStruct {outVar lenVar subtype value} {
	upvar 1 $outVar out $lenVar len
	variable marshalers

	set s [Pad $len 8]
	set padlen [string length $s]
	if {$padlen > 0} {
		lappend out $s
		incr len $padlen
	}

	foreach {type subtype} $subtype item $value {
		$marshalers($type) out len $subtype $item
	}
}

# TODO
# * Implement processing of nested arrays.
#   Observe that calculating padding for the type should be moved
#   to the case of nesting level == 1 since with nesting > 2
#   padding thould be calculated for array header (4 byte int).
#   UPD: really? each subarray must have it, no?
# * Implement processing of basic types with [binary format].

proc ::dbus::MarshalArray {outVar lenVar etype items} {
	upvar 1 $outVar out $lenVar len

	foreach {nestlvl type subtype} $etype break

	if {[llength $items] == 0} {
		append s [Pad $len 4] [binary format i 0]
		lappend out $s
		incr len [string length $s]
		return
	}

	set head [Pad $len 4]
	set fakelen [expr {$len + [string length $head] + 4}]
	set pad [PadType $fakelen $type]
	incr fakelen [string length $pad]

	set len $fakelen
	set data [list]
	if {$nestlvl == 1} {
		variable marshalers
		upvar 0 marshalers($type) marshaler
		foreach item $items {
			$marshaler data len $subtype $item
		}
	} else {
		lset etype 0 [expr {$nestlvl - 1}]
		foreach item $items {
			MarshalArray data len $etype $item
		}
	}

	set datalen [expr {$len - $fakelen}]
	if {$datalen > 0x04000000} {
		return -code error "Array data size exceeds limit"
	}

	append head [binary format i $datalen] $pad
	lappend out $head
	foreach item $data {
		lappend out $item
	}
}

proc ::dbus::MarshalList {outVar lenVar mlist items} {
	upvar 1 $outVar out $lenVar len
	variable marshalers

	foreach {type subtype} $mlist value $items {
		$marshalers($type) out len $subtype $value
	}
}

proc ::dbus::MarshalListTest {mlist items} {
	set out [list]
	set len 0
	MarshalList out len $mlist $items
	set out
}

####

# $value must be a three-element list: {type nesting list_of_elements},
# where list_of_elements may be nested (thus representing
# array of array [...of array, etc] of type; nesting should match
# the nesting level.
proc ::dbus::MarshalArrayOld {outVar value} {
	upvar 1 $outVar s

	foreach {type nest items} $value break

	if {$nest == 1} {
		variable basictypes
		if {[info exists basictypes($type)]} {
			variable binfmt
			foreach {n c} $binfmt($type) break
			set len [llength $items]
			append s [binary format [PadStr $s $n]i${c}$len [expr {$len * $n}] $items]
		} else {
			variable marshalers
			upvar 0 marshalers($type) marshaler
			set inner ""
			foreach item $items {
				$marshaler inner $item
			}

			set len [string length $inner]
			if {$len > 67108864} {
				return -code error "Array size exceeds limit"
			}
			
			append s [binary format [PadStr $s 4]i $len] $inner
		}
	} else {
		set inner ""
		foreach item $items {
			MarshalArrayOld inner [list $type [expr {$nest - 1}] $item] 
		}

		set len [string length $inner]
		if {$len > 67108864} {
			return -code error "Array size exceeds limit"
		}
		
		append s [binary format [PadStr $s 4]i $len] $inner
	}
}

namespace eval ::dbus {
	variable bytesex [expr {
		[string equal $::tcl_platform(byteOrder) littleEndian]
			? "l"
			: "B"}]
	variable proto_major 1
}

proc ::dbus::MarshalHeader {outVar lenVar type flags msglen serial fields} {
	upvar 1 $outVar out $lenVar len
	variable bytesex
	variable proto_major

	set head [binary format acccii $bytesex $type $flags $proto_major $msglen $serial]

	set out [list $head]
	set len 12
	MarshalArray out len {1 STRUCT {BYTE {} VARIANT {}}} $fields

	set pad [Pad $len 8]
	lappend out $pad
	incr len [string length $pad]
}

proc ::dbus::MarshalMessage {type flags serial fields mlist params} {
	set msg [list]
	set msglen 0

	if {$mlist != ""} {
		MarshalList msg msglen $mlist $params
	}

	MarshalHeader header len $type $flags $msglen $serial $fields

	if {$len + $msglen > 0x08000000} {
		return -code error "Message data size exceeds limit"
	}

	concat $header $msg
}

