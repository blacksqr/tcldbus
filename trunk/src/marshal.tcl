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

proc ::dbus::IEEEToDouble {data} {
if 0 {
	if {$byteorder == 0} {
		set code [binary scan $data cccccccc se1 e2f1 f2 f3 f4 f5 f6 f7]
	} else {
		set code [binary scan $data cccccccc f7 f6 f5 f4 f3 f2 e2f1 se1]
	}
} else {
	binary scan $data cccccccc f7 f6 f5 f4 f3 f2 e2f1 se1
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

namespace eval ::dbus {
	variable marshals
	array set marshals {
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
		SIGNATURE    MarshalString
		VARIANT      MarshalVariant
		STRUCT       MarshalStruct
		ARRAY        MarshalArray
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

proc ::dbus::MarshalByte {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len

	lappend out [binary format c $value]
	incr len
}

proc ::dbus::MarshalBoolean {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 4] [binary format i] [expr {!!$value}]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalInt16 {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 2] [binary format s $value]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalInt32 {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 4] [binary format i $value]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalInt64 {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 8] [binary format w $value]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalDouble {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 8] [DoubleToIEEE $value]
	lappend out $s
	incr len [string length $s]
}

proc ::dbus::MarshalString {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len

	append s [Pad $len 4] [binary format i [string bytelength $value]] $value \0
	lappend out $s
	incr len [string length $s]
}

# $value must be a two-element list: {type value}
proc ::dbus::MarshalVariant {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len
	variable srevmap
	variable marshals

	foreach {type val} $value break

	MarshalString out len $srevmap($type)
	$marshals($type) out len $val
}

# $value must be an even list: {type value ?type value ...?}
proc ::dbus::MarshalStruct {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len
	variable marshals

	set s [Pad $len 8]
	set padlen [string length $s]
	if {$padlen > 0} {
		lappend out $s
		incr len $padlen
	}

	foreach {type val} $value {
		$marshals($type) out len $val
	}
}

namespace eval ::dbus {
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
		STRUCT       8
		ARRAY        0
	}
}

#### List-style marshaling:

proc ::dbus::PadType {len type} {
	variable paddings
	Pad $len $paddings($type)
}

# TODO
# * Implement processing of nested arrays.
#   Observe that calculating padding for the type should be moved
#   to the case of nesting level == 1 since with nesting > 2
#   padding thould be calculated for array header (4 byte int).
# * Implement processing of basic types with [binary format].

proc ::dbus::MarshalArray {outVar lenVar value} {
	upvar 1 $outVar out $lenVar len

	foreach {nestlvl type items} $value break

	if {[llength $items] == 0} {
		append s [Pad $len 4] [binary format i 0]
		return
	}

	set head [Pad $len 4]
	set fakelen [expr {$len + [string length $head] + 4}]
	set pad [PadType $fakelen $type]
	incr fakelen [string length $pad]

	set runlen $fakelen
	if {$nestlvl == 1} {
		variable marshals
		upvar 0 marshals($type) marshal
		set data [list]
		foreach item $items {
			$marshal data runlen $item
		}
	} else {
		error "NOT IMPLEMENTED"
	}

	set datalen [expr {$runlen - $fakelen}]
	if {wide($datalen) > 0x04000000} {
		return -code error "Array data size exceeds limit"
	}

	append head [binary format i $datalen] $pad
	lappend out $head
	foreach item $data {
		lappend out $item
	}
}

proc ::dbus::MarshalList {outVar lenVar items} {
	upvar 1 $outVar out $lenVar len
	variable marshals

	foreach {type value} $items {
		$marshals($type) out len $value
	}

	if {wide($len) > 0x08000000} {
		return -code error "Message data size exceeds limit"
	}

	set out
}

proc ::dbus::MarshalListTest items {
	set out [list]
	set len 0
	MarshalList out len $items
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
			variable marshals
			upvar 0 marshals($type) marshal
			set inner ""
			foreach item $items {
				$marshal inner $item
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
	variable serial 0
}

proc ::dbus::MarshalHeader {type flags msglen serial fields} {
	variable bytesex
	variable proto_major

	set head [binary format acccii $bytesex $type $flags $proto_major $msglen $serial]

	set out [list $head]
	set len [string length $head]
	MarshalArray out len $fields

	lappend out [Pad $len 8]

	set out
}

proc ::dbus::MarshalMethodCall {object iface method signature params {flags 0}} {
	variable serial

	set msg [list]
	set len 0

	MarshalList msg len $params

	set out [MarshalHeader 1 $flags $len $serial [list 1 STRUCT [list \
		[list BYTE 1 VARIANT [list OBJECT_PATH $object]] \
		[list BYTE 2 VARIANT [list STRING $iface]] \
		[list BYTE 3 VARIANT [list STRING $method]] \
		[list BYTE 8 VARIANT [list SIGNATURE $signature]] \
	]]]
	incr serial

	foreach item $msg {
		lappend out $item
	}

	set out
}

