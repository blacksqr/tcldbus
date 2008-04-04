package require SASL
package require sha1

namespace eval ::SASL::DBusCookieSHA1 {
}

proc ::SASL::DBusCookieSHA1::client {context challenge args} {
	global tcl_platform
	upvar #0 $context ctx

	incr ctx(step)

	switch -- $ctx(step) {
		1 {
			set ctx(response) $tcl_platform(user)
			set res 1
		}

		2 {
			foreach {cookctx id shex} [split $ctx(challenge) " "] break
			set cookie [GetCookie $cookctx $id]
			set res 1
		}

		3 {
		}

		default {
			return -code error "Invalid step: \"$ctx(step)\""
		}
	}

	return $res
}

proc ::SASL::DBusCookieSHA1::GetCookie {ctx id} {
	set f [file join ~/.dbus-keyrings/ $ctx]

	if {![file readable $f]} return

	file stat $f props
	# TODO add mode checking; probably also owner checking

	set fd [open $f]
	foreach rec [split [read $fd] \n] {
	}
	close $fd
}

::SASL::register DBUS_COOKIE_SHA1 50 ::SASL::DBusCookieSHA1

