# $Id$
# Makefile intended to run tests

TCLSH = tclsh

test:
	$(TCLSH) tests/all.tcl $(TESTFLAGS)

