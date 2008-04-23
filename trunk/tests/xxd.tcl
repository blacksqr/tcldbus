# $Id$
# Dumper/undumper of binary data to readable format
# resembling that of "xxd" utility.

if 0 {
0000000: 0601 7300 0500 0000 3a31 2e32 3100 0000  ..s.....:1.21...
0000010: 0401 7300 2800 0000 6f72 672e 6672 6565  ..s.(...org.free
0000020: 6465 736b 746f 702e 4442 7573 2e45 7272  desktop.DBus.Err
0000030: 6f72 2e55 6e6b 6e6f 776e 4d65 7468 6f64  or.UnknownMethod
0000040: 0000 0000 0000 0000 0501 7500 0200 0000  ..........u.....
0000050: 0801 6700 0173 0000 0701 7300 1400 0000  ..g..s....s.....
0000060: 6f72 672e 6672 6565 6465 736b 746f 702e  org.freedesktop.
0000070: 4442 7573 00                             DBus.
}

namespace eval xxd {}

proc xxd::dump bstr {
}

proc xxd::pack spec {
	set lineno 0
	set off 0
	set bstr ""

	foreach line [split $spec \n] {
		incr lineno

		set str [regsub -all -- \\s+ $line ""]
		if {$str == ""} continue

		if {![regexp {^(?:([[:xdigit:]]+):)?([[:xdigit:]]+)(?:#.*)?$} \
				$str -> ofs bytes]} {
			PackError $lineno "invalid dump format"
		}

		set len [string length $bytes]
		if {$len % 2} {
			PackError $lineno "non-even number of nybbles in a string"
		}

		if {$ofs != ""} {
			set at [expr {[scan $ofs %x] & 0xFFFFFFFF}]
			if {$at != $off} {
				PackError $lineno "invalid offset"
			}
		}

		append bstr [binary format H* $bytes]

		set off [expr {wide($off) + $len / 2}]
	}

	set bstr
}

proc xxd::PackError {lineno errmsg} {
	return -code error [format "At line %d: %s" $lineno $errmsg]
}

# Testing framework:

if {[info exists xxd_tested]} return

# 117 bytes of some D-Bus message generated
# by the reference D-Bus implementation:
set bref [binary format H* [regsub -all \\s+ {
	06017300050000003a312e3231000000
	04017300280000006f72672e66726565
	6465736b746f702e444275732e457272
	6f722e556e6b6e6f776e4d6574686f64
	00000000000000000501750002000000
	08016700017300000701730014000000
	6f72672e667265656465736b746f702e
	4442757300} ""]]

test pack-1.1 {"Reference" xxd format} -body {
	xxd::pack {
		0000000: 0601 7300 0500 0000 3a31 2e32 3100 0000
		0000010: 0401 7300 2800 0000 6f72 672e 6672 6565
		0000020: 6465 736b 746f 702e 4442 7573 2e45 7272
		0000030: 6f72 2e55 6e6b 6e6f 776e 4d65 7468 6f64
		0000040: 0000 0000 0000 0000 0501 7500 0200 0000
		0000050: 0801 6700 0173 0000 0701 7300 1400 0000
		0000060: 6f72 672e 6672 6565 6465 736b 746f 702e
		0000070: 4442 7573 00
	}
} -result $bref

test pack-1.2 {No offsets} -body {
	xxd::pack {
		0601 7300 0500 0000 3a31 2e32 3100 0000
		0401 7300 2800 0000 6f72 672e 6672 6565
		6465 736b 746f 702e 4442 7573 2e45 7272
		6f72 2e55 6e6b 6e6f 776e 4d65 7468 6f64
		0000 0000 0000 0000 0501 7500 0200 0000
		0801 6700 0173 0000 0701 7300 1400 0000
		6f72 672e 6672 6565 6465 736b 746f 702e
		4442 7573 00
	}
} -result $bref

test pack-1.3 {Arbitrary whitespace} -body {
	xxd::pack {
		06	01 73   00 0500 0000 3a31 	2e32 3100 0000
			0401 7300 2800 0000 6 f 7 2 6 7 2 e 6 6 7 2 6565
		6465 736b 746f 702e 4442 7573 2e45 7272
		6f72 2e55 6e6b 6e
			6f 776e 4d65 7468 6f64
		0000 00
			00 00
				0 0 0 0
							00 0501 7500 0200 0000
		0801 6700 01	73 0000 07
					01 73	00 1400 0000\
		6f72 672e 6672 6565 6465 736b 746f 702e\
		4             44   2 75 	73 00
	}
} -result $bref

test pack-1.4 {Comments} -body {
	xxd::pack {
		0601 7300 0500 0000 3a31 2e32 3100 0000  # First line
		0401 7300 2800 0000 6f72 672e 6672 6565
		6465 736b 746f 702e 4442 7573 2e45 7272
		6f72 2e55 6e6b 6e6f 776e 4d65 7468 6f64      # Another line
		0000 0000 0000 0000 0501 7500 0200 0000
		0801 6700 0173 0000 0701 7300 1400 0000
		6f72 672e 6672 6565 6465 736b 746f 702e
		4442 7573 00# Last line
	}
} -result $bref

set xxd_tested 1

