# $Id$
# Implementation of SASL mechs missing from the SASL package.

package require SASL

# SASL EXTERNAL (RFC 2222).
# Client callback is called just once, and in this call it is passed
# the "initial" command and is expected to return initial response
# which must be an authentication token as required by the underlying
# protocol.
# Server callback is called just once, and in this call it is passed
# the "authenticate" command along with client's initial response
# which is its authentication token; the callback is then required to
# return true if the client was authenticated or false otherwise.

proc ::SASL::EXTERNAL:client {context challenge args} {
	upvar #0 $context ctx

	set ctx(response) [eval $ctx(callback) initial [list $challenge]]
}

proc ::SASL::EXTERNAL:server {context clientresp args} {
	upvar #0 $context ctx

	set ok [eval $ctx(callback) authenticate [list $clientresp]]
	set ctx(response) ""
	if {$ok} {
		return 0
	} else {
		return -code error "authentication failed"
	}
}

# TODO priority for this mech has no sense because the client's initial
# response is opaque to us so we can't measure the security implications.
::SASL::register EXTERNAL 10 ::SASL::EXTERNAL:client ::SASL::EXTERNAL:server

