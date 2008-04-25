/*
 * ceptcl.h --
 *
 *	This header file contains the function declarations needed for
 *	all of the source files in this package.
 *
 * Copyright (c) 2003 Stuart Cassoff
 *
 * See the file "LICENSE" for information on usage and redistribution
 * of this file, and for a DISCLAIMER OF ALL WARRANTIES.
 *
 */

#ifndef _CEPTCL
#define _CEPTCL

#include <tcl.h>

/*
 * Windows needs to know which symbols to export.  Unix does not.
 * BUILD_cep should be undefined for Unix.
 */

#ifdef BUILD_cep
#undef TCL_STORAGE_CLASS
#define TCL_STORAGE_CLASS DLLEXPORT
#endif /* BUILD_cep */


/* Domains */
#define CEP_LOCAL 0
#define CEP_INET  1
#define CEP_INET6 2

/* Types */
#define CEP_RAW    0
#define CEP_DGRAM  1
#define CEP_STREAM 2

/* Careful! These shorcut macros assume */
/* that a variable 'Tcl_Interp *interp' exists.*/
/* q is for 'quick' */

#define qseterr(msg) Cep_SetInterpResultError(interp,msg,(char*)NULL)
#define qseterrpx(msg) Cep_SetInterpResultErrorPosix(interp,msg,(char*)NULL)

typedef void (CepAcceptProc) _ANSI_ARGS_((ClientData callbackData,
					  Tcl_Channel chan, const char *addr, int port, int cepDomain,
					  uid_t euid, gid_t egid, const unsigned char *data));


EXTERN Tcl_Channel      Cep_OpenClient _ANSI_ARGS_((Tcl_Interp * interp, 
						    int cepDomain, int cepType,
						    const char *protocol,
						    const char *host, int port,
						    const char *myaddr, int myport,
						    int async, int resolve,
						    int reuseaddr, int reuseport));

EXTERN Tcl_Channel      Cep_OpenServer _ANSI_ARGS_((Tcl_Interp * interp, 
						    int receiver,
						    int cepDomain, int cepType,
						    const char *protocol,
						    const char *myName, int port,
						    int resolve,
						    int reuseaddr, int reuseport,
						    CepAcceptProc *acceptProc, 
						    ClientData callbackData));

EXTERN int              Cep_OpenLocalPair _ANSI_ARGS_((Tcl_Interp * interp, 
						       int cepDomain, int cepType,
						       const char *protocol,
						       Tcl_Channel *chan1, Tcl_Channel *chan2));

EXTERN Tcl_Channel      MakeCepClientChannel (ClientData sock, int cepDomain, int cepType, int protocol, int resolve);

EXTERN int              Cep_Sendto (Tcl_Channel chan, const char *host, int port, const unsigned char *data, int dataLen);

EXTERN int              Ceptcl_Init _ANSI_ARGS_((Tcl_Interp * interp));

EXTERN int              Ceptcl_SafeInit _ANSI_ARGS_((Tcl_Interp * interp));

EXTERN int              Cep_SetInterpResultError TCL_VARARGS(Tcl_Interp *,arg1);

EXTERN int              Cep_SetInterpResultErrorPosix TCL_VARARGS(Tcl_Interp *,arg1);


#endif /* _CEPTCL */
