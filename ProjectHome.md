# What #

Implementation of D-Bus protocol in Tcl.

# Goals #

Implement a Tcl package providing:
  * Marshaling/unmarshaling of data between D-Bus wire format and Tcl internal representation.
  * "Peer" interface to D-Bus, i.e. it should be possible to use this package to implement a client for D-Bus system/session messaging bus (calling of methods, emission of signals, object proxying, etc). Peer-to-peer mode of operation is also to be supported.

When the core functionality is mature, several other goals look interesting to achieve:
  * Provide interfaces for XOTcl and TclOO object-oriented packages, may be SNIT, to allow "native" implementation of both local and remote objects via OO facilities of these systems.
  * Implement ready-made bindings to [Telepathy](http://telepathy.freedesktop.org).

# Status #

Early stage of development, unusable.