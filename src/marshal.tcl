# $Id$
# Wire marshaling/unmarshaling.

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

# TODO some points about marshaling aren't clear:
# * Are empty structs allowed?
# * Are variants containing variants allowed?

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

# Calculates minimal amount of NUL-byte padding required to naturally align a
# value consisting of $n bytes after $a bytes of data.
# The command returns a format string for [binary format] which is a "xN" for
# non-zero amount of padding (which is N bytes) or an empty string otherwise.
# NOTE: we treat "x" type specifier for binary format to generate NUL-padding
# specially due to a Tcl bug #923966 which actually prohibits the usage of
# "x0", so when no padding is required (a padding of zero length), this command
# returns an empty string.
proc ::dbus::Pad {a n} {
	set x [expr {$a % $n}]
	if {$x} {
		return x[expr {$n - $x}]
	} else {
		return ""
	}
}

# Does exactly what [Pad] does but for a (presumably binary) string $s
proc ::dbus::PadStr {s n} {
	Pad [string length $s] $n
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

proc ::dbus::MarshalByte {outVar value} {
	upvar 1 $outVar out
	append out [binary format c $value]
}

proc ::dbus::MarshalBoolean {outVar value} {
	upvar 1 $outVar s
	append s [binary format [PadStr $s 4]i expr {!!$value}]
}

proc ::dbus::MarshalInt16 {outVar value} {
	upvar 1 $outVar s
	append s [binary format [PadStr $s 2]s $value]
}

proc ::dbus::MarshalInt32 {outVar value} {
	upvar 1 $outVar s
	append s [binary format [PadStr $s 4]i $value]
}

proc ::dbus::MarshalInt64 {outVar value} {
	upvar 1 $outVar s
	append s [binary format [PadStr $s 8]w $value]
}

proc ::dbus::MarshalDouble {outVar value} {
	upvar 1 $outVar s
	append s [binary format [PadStr $s 8]] [DoubleToIEEE $value]
}

proc ::dbus::MarshalString {outVar value} {
	upvar 1 $outVar s
	append s [binary format [PadStr $s 4]i [string bytelength $value]] $value \0
}

# $value must be a two-element list: {type value}
proc ::dbus::MarshalVariant {outVar value} {
	upvar 1 $outVar s
	variable srevmap
	variable marshals

	foreach {type val} $value break

	MarshalString s $srevmap($type)
	$marshals($type) s $val
}

# $value must be an even list: {type value ?type value ...?}
proc ::dbus::MarshalStruct {outVar value} {
	upvar 1 $outVar s
	variable marshals

	append s [binary format [PadStr $s 8]]
	foreach {type val} $value {
		$marshals($type) s $val
	}
}

namespace eval ::dbus {
	variable basictypes
	array set basictypes {
		BYTE       {}
		BOOLEAN    {}
		INT16      {}
		UINT16     {}
		INT32      {}
		UINT32     {}
		INT64      {}
		UINT64     {}
	}
	variable binfmt
	array set binfmt {
		INT16       {2 s}
		UNIT16      {2 s}
		INT32       {4 i}
		UINT32      {4 i}
		INT64       {8 w}
		UINT64      {8 w}
	}
}

# $value must be a three-element list: {type nesting list_of_elements},
# where list_of_elements may be nested (thus representing
# array of array [...of array, etc] of type; nesting should match
# the nesting level.
proc ::dbus::MarshalArray {outVar value} {
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
			MarshalArray inner [list $type [expr {$nest - 1}] $item] 
		}

		set len [string length $inner]
		if {$len > 67108864} {
			return -code error "Array size exceeds limit"
		}
		
		append s [binary format [PadStr $s 4]i $len] $inner
	}
}

proc ::dbus::MarshalBasicArray {outVar type items} {
	upvar 1 $outVar s
	variable binfmt

	foreach {n c} $binfmt($type) break
	set fmt [PadStr $s 4]i[Pad 4 $n]

	set len [llength $items]
	if {$len > 0} {
		append fmt $c $len
		append s [binary format $fmt [expr {$len * $n}] $items]
	} else {
		append s [binary format $fmt 0]
	}
}

proc ::dbus::MarshalList {outVar list} {
	upvar 1 $outVar s
	variable marshals

	foreach {type val} $list {
		$marshals($type) s $val
	}
}

namespace eval ::dbus {
	variable bytesex [expr {
		[string equal $::tcl_platform(byteOrder) littleEndian]
			? "l"
			: "B"}]
	variable proto_major 1
}

proc ::dbus::MarshalHeader {outVar type flags len serial args} {
	variable bytesex
	variable proto_major

	upvar 1 $outVar s

	append s [binary format acccii $bytesex $type $flags $proto_major $len $serial]
}

