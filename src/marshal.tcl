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

proc ::dbus::Pad {s n} {
	set x [expr {[string length $s] % $n}]
	expr {$x ? $n - $x : 0}
}

proc ::dbus::MarshalByte {outVar value} {
	upvar 1 $outVar out
	append out [binary format c $value]
}

proc ::dbus::MarshalInt16 {outVar value} {
	upvar 1 $outVar s
	append s [binary format x[Pad $s 2]s $value]
}

proc ::dbus::MarshalInt32 {outVar value} {
	upvar 1 $outVar s
	append s [binary format x[Pad $s 4]i $value]
}

proc ::dbus::MarshalInt64 {outVar value} {
	upvar 1 $outVar s
	append s [binary format x[Pad $s 8]w $value]
}

proc ::dbus::MarshalDouble {outVar value} {
	upvar 1 $outVar s
	append s [binary format x[Pad $s 8]] [DoubleToIEEE $value]
}

proc ::dbus::MarshalString {outVar value} {
	upvar 1 $outVar s
	append s [binary format x[Pad $s 4]i [string length $value]] $value \0
}

namespace eval ::dbus {
	variable marshal
	array set marshal {
		INT16       {2 s}
		UNIT16      {2 s}
		INT32       {4 i}
		UINT32      {4 i}
		INT64       {8 w}
		UINT64      {8 w}
	}
}

# TODO fix x0s problem (Tcl bug #923966) by reimplementing
# [Pad] to return a format string rather than a number;
# for zero amount of padding it would return an empty string.
# TODO think of [PadS] or [PadStr] and [PadN].

proc ::dbus::MarshalArray {outVar type items} {
	upvar 1 $outVar s
	variable marshal
	set len [llength $items]
	foreach {n c} $marshal($type) break
	set x [expr {4 % $n}]
	set pad [expr {$x ? $n - $x : 0}]
	set fmt x[Pad $s 4]ix${pad}${c}$len
	puts $fmt
	append s [binary format $fmt $len $items]
}

