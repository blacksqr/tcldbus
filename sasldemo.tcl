source src/sasl.tcl

proc Server {ctx cmd args} {
	puts [info level 0]
	return 1 ;# passed
}

proc Client {ctx cmd args} {
	puts [info level 0]
	return kostix_id
}

set server [SASL::new -type server -callback Server -mechanism EXTERNAL]
set client [SASL::new -callback Client -mechanism EXTERNAL]

SASL::step $client ""
set initial [SASL::response $client]

set authd [SASL::step $server $initial]
puts $authd

