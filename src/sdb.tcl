# $Id$
# "Simple DB" -- support for simple maping of compound keys (category + tag)
# to values with "constructors" and "destructors".

namespace eval sdb {
	variable id 0
	variable names
	variable triggers

	namespace export create drop add delete on
}

proc sdb::create name {
	variable id
	variable names

	if {[string first :: $name] != 0} {
		set cmd [uplevel 1 namespace current]::$name
	} else {
		set cmd $name
	}

	if {[info commands $name] != ""} {
		return -code error "Cannot create database: command \"$name\" already exists"
	}

	set db db$id
	incr id

	interp alias {} $cmd {} [namespace current]::Command $db
	set names($name) $db
}

proc sdb::drop name {
	variable names

	upvar 0 names($name) db
	if {[info exists db]} {
		unset db
	}

	if {[string first :: $name] != 0} {
		set cmd [uplevel 1 namespace current]::$name
	} else {
		set cmd $name
	}

	set ix [lsearch -exact [interp aliases {}] $cmd]
	if {$ix >= 0} {
		interp alias {} $cmd {}
	}
}

proc sdb::on {db action args} {
	variable triggers

	if {[llength $args] < 1} {
		return -code error "Wrong # args:\
			must be on database action ?options? script"
	}

	switch -- $action {
		insert - delete - update {}
		default {
			return -code error "Bad action \"$action\":\
				must be one of insert, delete or update"
		}
	}

	set script [lindex $args end]

	set triggers($db,$action) $script
}

proc sdb::add {db category tag value} {
	variable $db
	variable triggers

	upvar 0 ${db}($category,$tag) record

	if {[info exists record]} {
		upvar 0 $triggers($db,update) trigger
		if {[info exists trigger]} {
			set code [catch [list $trigger $record $value]]
			switch -- $code {
				0 { # ok, do nothing }
				3 { # break
					return
				}
				default {
					return -code $code
				}
			}
		}
	} else {
		upvar 0 $triggers($db,insert) trigger
		if {[info exists trigger]} {
			set code [catch [list $trigger $value]]
			switch -- $code {
				0 { # ok, do nothing }
				3 { # break
					return
				}
				default {
					return -code $code
				}
			}
		}
	}

	set record $value
}

proc sdb::delete {db category {tag *}} {
	variable $db
	variable triggers

	set pattern $category,$tag

	array unset $db $pattern

	# TODO on delete "triggers"
}

proc sdb::Command {db args} {
	if {[llength $args] < 0} {
		return -code error "Wrong # args: must be $db option ?arg ...?"
	}

	set cmd [lindex $args]
	switch -- $cmd {
		add - delete - on - drop {
			eval [list $cmd $db] [lrange $args 1 end]
		}
		default {
			return -code error "Bad option \"$cmd\":\
				must be one of add, delete, on or drop"
		}
	}
}

