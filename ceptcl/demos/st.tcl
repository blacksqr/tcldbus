


package require ceptcl


proc r {args} {
    puts $args
}


cep -type datagram -receiver r -myaddr 192.168.11.255 67


vwait forever

