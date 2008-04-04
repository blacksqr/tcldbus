# $Id$
# TODO check for empty structs.
# TODO ensure all the checks from the ref. impl. are performed.

namespace eval ::dbus {
	variable sigcache
	variable valid
	variable smap
	variable srevmap
	array set smap {
		y  BYTE
		b  BOOLEAN
		n  INT16
		q  UINT16
		i  INT32
		u  UINT32
		x  INT64
		t  UINT64
		d  DOUBLE
		s  STRING
		o  OBJECT_PATH
		g  SIGNATURE
		v  VARIANT
	}
	array set srevmap {
		BYTE         y
		BOOLEAN      b
		INT16        n
		UINT16       q
		INT32        i
		UINT32       u
		INT64        x
		UINT64       t
		DOUBLE       d
		STRING       s
		OBJECT_PATH  o
		SIGNATURE    g
		VARIANT      v
	}
}

proc ::dbus::SigParse sig {
	if {[string length $sig] > 255} {
		return -code error "Signature length exceeds limit"
	}

	set ix 0
	SigParseAtom $sig ix 1 0
}

proc ::dbus::SigParseAtom {sig indexVar level slevel} {
	upvar 1 $indexVar ix
	variable smap
	variable srevmap

	set len [string length $sig]
	set out [list]
	set alevel 0
	while {$ix < $len} {
		set c [string index $sig $ix]
		incr ix
		switch -- $c {
			(  {
				if {$slevel == 32} {
					return -code error "Struct nesting limit exceeded"
				}
				set atom [SigParseAtom $sig ix [expr {$level + 1}] [expr {$slevel + 1}]]
				if {$alevel > 0} {
					lappend out ARRAY [list $alevel STRUCT $atom]
					set alevel 0
				} else {
					lappend out STRUCT $atom
				}
			}
			)  -
			\} {
				if {$level == 1} {
					return -code error "Orphaned compound type terminator"
				}
				if {$alevel > 0} {
					return -code error "Incomplete array definition"
				}
				return $out
			}
			a  {
				incr alevel
				if {$alevel > 32} {
					return -code error "Array nesting limit exceeded"
				}
			}
			\{ {
				if {$alevel < 1} {
					return -code error "Stray dict entry"
				}
				set dict [SigParseAtom $sig ix [expr {$level + 1}] $slevel]
				if {[llength $dict] != 4} {
					return -code error "Dict entry doesn't contain exactly two types"
				}
				if {![info exists srevmap([lindex $dict 0])]} {
					return -code error "Dict entry key is not a simple type"
				}
				lappend out ARRAY [list $alevel DICT $dict]
				set alevel 0
			}
			default {
				if {![info exists smap($c)]} {
					return -code error "Prohibited type character"
				}
				if {$alevel > 0} {
					lappend out ARRAY [list $alevel $smap($c) {}]
					set alevel 0
				} else {
					lappend out $smap($c) {}
				}
			}
		}
	}

	if {$level > 1} {
		return -code error "Incomplete compound type"
	}
	if {$alevel > 0} {
		return -code error "Incomplete array definition"
	}

	set out
}

proc ::dbus::SigParseCached sig {
	variable sigcache
	upvar 0 sigcache($sig) csig

	if {[info exists csig]} {
		set csig
	} else {
		set csig [SigParse $sig]
	}
}

# Validates given signature according to the rules of D-Bus spec.
# Returns true if the signature is valid, false otherwise.
# It always first checks the cache since it contains only valid
# signatures, then it parses the signature and caches it if
# $cache is true (false by default).
proc ::dbus::IsValidSignature {signature {cache 0}} {
	variable sigcache

	if {[info exists sigcache($signature)] {
		return 1
	} else {
		catch {
			if {$cache} {
				SigParseCached $signature
			} else {
				SigParse $signature
			}
		}
	}
}

