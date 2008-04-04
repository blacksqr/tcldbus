proc foo n {
	if {$n == 0} {
		streamerror "Wow, error!"
		puts "and the beat goes on..."
	} else {
		after 100 [list foo [expr {$n - 1}]]
	}
}

proc streamerror error {
	if {[info commands mumble] != ""} {
		set cmd [list mumble $error]
	} else {
		#set cmd [list error $error]
		return -code error -errorinfo "processing stream" $error
	}
	uplevel #0 $cmd
	return -code error -errorinfo "processing stream" $error
}

proc mumbleX msg {
	puts [info level 0]
}

after 100 foo 2

vwait forever
puts never

