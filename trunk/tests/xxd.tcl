# $Id$
# Dumper/undumper of binary data to readable format
# resembling that of "xxd" utility.

if 0 {
0000000: 6c01 0001 0000 0000 0000 0000 6d00 0000  l...........m...
0000010: 0101 6f00 1500 0000 2f6f 7267 2f66 7265  ..o...../org/fre
0000020: 6564 6573 6b74 6f70 2f44 4275 7300 0000  edesktop/DBus...
0000030: 0201 7300 1400 0000 6f72 672e 6672 6565  ..s.....org.free
0000040: 6465 736b 746f 702e 4442 7573 0000 0000  desktop.DBus....
0000050: 0301 7300 0500 0000 4865 6c6c 6f00 0000  ..s.....Hello...
0000060: 0601 7300 1400 0000 6f72 672e 6672 6565  ..s.....org.free
0000070: 6465 736b 746f 702e 4442 7573 0000 0000  desktop.DBus....
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

		if {![regexp {^(?:([[:xdigit:]]+):)?([[:xdigit:]]+)?(?:#.*)?$} \
				$str -> ofs bytes]} {
			PackError $lineno "invalid dump format"
		}
		if {$bytes == ""} continue

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

# 128 bytes of some D-Bus message generated
# by the reference D-Bus implementation:
set bref [binary format H* [regsub -all \\s+ {
	6c01000100000000100000006d000000
	01016f00150000002f6f72672f667265
	656465736b746f702f44427573000000
	02017300140000006f72672e66726565
	6465736b746f702e4442757300000000
	030173000500000048656c6c6f000000
	06017300140000006f72672e66726565
	6465736b746f702e4442757300000000
} ""]]

# Packer -- correct formats:

test pack-1.1 {"Reference" xxd format} -body {
	xxd::pack {
		0000000: 6c01 0001 0000 0000 1000 0000 6d00 0000
		0000010: 0101 6f00 1500 0000 2f6f 7267 2f66 7265
		0000020: 6564 6573 6b74 6f70 2f44 4275 7300 0000
		0000030: 0201 7300 1400 0000 6f72 672e 6672 6565
		0000040: 6465 736b 746f 702e 4442 7573 0000 0000
		0000050: 0301 7300 0500 0000 4865 6c6c 6f00 0000
		0000060: 0601 7300 1400 0000 6f72 672e 6672 6565
		0000070: 6465 736b 746f 702e 4442 7573 0000 0000
	}
} -result $bref

test pack-1.2 {No offsets} -body {
	xxd::pack {
		6c01 0001 0000 0000 1000 0000 6d00 0000
		0101 6f00 1500 0000 2f6f 7267 2f66 7265
		6564 6573 6b74 6f70 2f44 4275 7300 0000
		0201 7300 1400 0000 6f72 672e 6672 6565
		6465 736b 746f 702e 4442 7573 0000 0000
		0301 7300 0500 0000 4865 6c6c 6f00 0000
		0601 7300 1400 0000 6f72 672e 6672 6565
		6465 736b 746f 702e 4442 7573 0000 0000
	}
} -result $bref

test pack-1.3 {Arbitrary whitespace} -body {
	xxd::pack {
		0000000: 6 c0 1 00 01 00	00 000 0 1 000 0000 6d00 0000
		0000010: 0101 6f00 15
			00 0000 2f6f 7 267 2f66 7265
		00 00 0 20: 6564 657	3 6	\
			b74 6f70 2\
				f44 4275 7300 0000
		0000030: 0 201 7 300 1400 0000 6f
		    72 672e 6 672  6565
		00000 40	: 6465 736b 746f 702e 4442 7573 0000 0000
		0000 050: 0301 73  00 0500 00
				00 4865 6c6c 6f
						00 0000
		00 00 060 : 06	01 7300 14
			00 0000 6f72 67\
				2e 6672 6565
		00000 70 : 6 4 6 5 736b746f702e 4 4 4 2 75 73 0000 0000
	}
} -result $bref

test pack-1.4 {Comments} -body {
	xxd::pack {
		# Header:
		6c01 0001 0000 0000 1000 0000 6d00 0000
		0101 6f00 1500 0000 2f6f 7267 2f66 7265	# Next line
		6564 6573 6b74 6f70 2f44 4275 7300 0000
		0201 7300 1400 0000 6f72 672e 6672 6565
		# Another line:
		6465 736b 746f 702e 4442 7573 0000 0000
		0301 7300 0500 00 # Yet another line
			00 4865 6c6c 6f00 0000 # Next line
		0601 7300 1400 0000 6f72 672e 6672 6565
		6465 736b 746f 702e 4442 7573 0000 0000      # Last line
		# End of block
	}
} -result $bref

test pack-1.5 {Full-featured format} -body {
	xxd::pack {
		# Header prologue:
		00: 6c # Endianness marker
		01: 01 # Message type
		02: 00 # Flags
		03: 01 # Protocol version
		04: 0000 0000 # Body length
		08: 1000 0000 # Serial
		# Header fields:
		0C: 6d00 0000 # Length of fields array body
		10: 0101 6f00 1500 0000 2f6f 7267 2f66 7265
		20: 6564 6573 6b74 6f70 2f44 4275 7300 0000
		30: 0201 7300 1400 0000 6f72 672e 6672 6565
		40: 6465 736b 746f 702e 4442 7573 0000 0000
		50: 0301 7300 0500 0000 4865 6c6c 6f00 0000
		60: 0601 7300 1400 0000 6f72 672e 6672 6565
		70: 6465 736b 746f 702e 4442 7573
		# Padding:
		0000 0000
	}
} -result $bref

test pack-1.6 {Offsets w/o actual bytes} -body {
	xxd::pack {
		0000000: 6c01 0001 0000 0000 1000 0000 6d00 0000
		0000010:
		0000010: # filler...
		0000010:
		0000010: 0101 6f00 1500 0000 2f6f 7267 2f66 7265
		0000020: 6564 6573 6b74 6f70 2f44 4275 7300 0000
		0000030: 0201 7300 1400 0000 6f72 672e 6672 6565
		0000040: 6465 736b 746f 702e 4442 7573 0000 0000
		0000050: 0301 7300 0500 0000 4865 6c6c 6f00 0000
		0000060: 0601 7300 1400 0000 6f72 672e 6672 6565
		0000070: 6465 736b 746f 702e 4442 7573 0000 0000
	}
} -result $bref

test pack-1.7 {Empty format} -body {
	xxd::pack "
		\n\n\n\t\n\
		\
		\n\
	"
} -result ""

test pack-1.8 {Effectively empty format} -body {
	xxd::pack {
		# Start:
		00000000: # Line #1
		00000000: # Line #2
		00000000: # ...
		00000000: # ...
		00000000: # ...
		# End
	}
} -result ""

# Packer -- malformed formats:

test pack-2.1 {Garbage in format} -body {
	xxd::pack {
		6c01 0001 0000 0000 1000 0000 6d00 0000;
	}
} -returnCodes error -result "At line 2: invalid dump format"

test pack-2.2 {Stray nybble on a line} -body {
	xxd::pack {
		6c01 0001 0000
		0000 1000 0
		000 6d00 0000
	}
} -returnCodes error -result "At line 3: non-even number of nybbles in a string"

test pack-2.3 {Two colons on a line} -body {
	xxd::pack {
		0000000: 6c01 0001 0000 0000 0000008: 0101 6f00 1500 0000
	}
} -returnCodes error -result "At line 2: invalid dump format"

test pack-2.4 {Two colons on a line} -body {
	xxd::pack {
		0000000: 6c01 0001 0000 0000 0000008: 0101 6f00 1500 0000
	}
} -returnCodes error -result "At line 2: invalid dump format"

test pack-2.5 {Invalid offset #1} -body {
	xxd::pack {
		0000000: 6c01 0001 0000 0000
		0000009: 0101 6f00 1500 0000
	}
} -returnCodes error -result "At line 3: invalid offset"

test pack-2.6 {Invalid offset #2} -body {
	xxd::pack {
		0000000: 6c01 0001 0000 0000
		0000004: 0101 6f00 1500 0000
	}
} -returnCodes error -result "At line 3: invalid offset"

test pack-2.7 {Invalid offset #3} -body {
	xxd::pack {
		00000FF: 6c01 0001 0000 0000
	}
} -returnCodes error -result "At line 2: invalid offset"

set xxd_tested 1

