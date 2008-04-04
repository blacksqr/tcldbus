CFLAGS = -I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include
LDFLAGS = -ldbus-1
ifndef DEBUG
	LDFlAGS += -O2
endif

dbus-unmarshal: dbus-unmarshal.c
	gcc -o dbus-unmarshal $(CFLAGS) $(LDFLAGS) dbus-unmarshal.c

