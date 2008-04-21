# $Id$

# "Tree compare" -- compares nested lists in $a and $b

proc tc {a b} {
	if {[llength $a] == 1 || [llength $b] == 1} {
		if {[llength $a] == [llength $b]} {
			return [string equal [lindex $a 0] [lindex $b 0]]
		} else {
			return 0
		}
	} else {
		foreach x $a y $b {
			if {![tc $x $y]} {
				return 0
			}
		}
	}
	return 1
}

# Self-tests:

if {[info exists tc_tested]} return

test tester-1.1 {Equal basic values} -body {
	tc X X
} -result 1

test tester-1.2 {Equal lists} -body {
	tc {a b c} {a b c}
} -result 1

test tester-1.3 {Equal lists, nesting level 2} -body {
	tc {a {X Y} c} {a {X Y} c}
} -result 1

test tester-1.4 {Equal lists, nesting level 3} -body {
	tc {a b {
		X {foo bar} Y} c} {a b {X {
			foo
			bar}
				Y} c}
} -result 1

test tester-1.5 {Not equal lists} -body {
	tc {a b {X {foo bar} Y} c} {a b {X {foO bar} Y} c}
} -result 0

test tester-1.6 {Sublists of different length} -body {
	tc {a b {X {foo bar} Y} c} {a b {X {foo bar baz} Y} c}
} -result 0

set tc_tested 1

