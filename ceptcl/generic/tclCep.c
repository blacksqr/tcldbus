/*
 * tclCep.c --
 *
 *      This file implements a Tcl interface to
 *      Local Communication EndPoints (CEPs)
 *
 * This was generic/tclIOCmd.c
 *
 * Copyright (c) 1995-1997 Sun Microsystems, Inc.
 * Copyright (c) 2003 Stuart Cassoff
 *
 * See the file "license.terms" for information on usage and redistribution
 * of this file, and for a DISCLAIMER OF ALL WARRANTIES.
 *
 */

#include <unistd.h>
#include <string.h>
#include <netdb.h>
/* This may be needed for ntohs on some platforms */
#include <netinet/in.h>
/* */
#include <assert.h>
#include <tcl.h>
#include "../generic/ceptcl.h"

/*
 * Callback structure for accept callback in a CEP server.
 */

typedef struct AcceptCallback {
  char *script;                       /* Script to invoke. */
  Tcl_Interp *interp;                 /* Interpreter in which to run it. */
} AcceptCallback;

/*
 * Static functions for this file:
 */

static CepAcceptProc AcceptCallbackProc;

static CepAcceptProc ReceiverCallbackProc;


static void     RegisterCepServerInterpCleanup _ANSI_ARGS_((Tcl_Interp *interp,
                    AcceptCallback *acceptCallbackPtr));

static void     CepAcceptCallbacksDeleteProc _ANSI_ARGS_((
                    ClientData clientData, Tcl_Interp *interp));

static void     CepServerCloseProc _ANSI_ARGS_((ClientData callbackData));

static void     UnregisterCepServerInterpCleanupProc _ANSI_ARGS_((
                    Tcl_Interp *interp, AcceptCallback *acceptCallbackPtr));

static int      Cep_Cmd _ANSI_ARGS_((ClientData notUsed, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]));

static int      Sendto_Cmd _ANSI_ARGS_((ClientData notUsed, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]));

static int      _TCL_SockGetPort _ANSI_ARGS_((Tcl_Interp *interp, const char *string, const char *proto, int *portPtr));



/*
 *---------------------------------------------------------------------------
 *
 * _TCL_SockGetPort --
 *
 * This was TclSockGetPort from generic/tclIO.c
 * with some cmall changes for types and error message.
 *
 *	Maps from a string, which could be a service name, to a port.
 *	Used by socket creation code to get port numbers and resolve
 *	registered service names to port numbers.
 *
 * Results:
 *	A standard Tcl result.  On success, the port number is returned
 *	in portPtr. On failure, an error message is left in the interp's
 *	result.
 *
 * Side effects:
 *	None.
 *
 *---------------------------------------------------------------------------
 */

static int
_TCL_SockGetPort (interp, string, proto, portPtr)
    Tcl_Interp *interp;
    const char *string;		/* Integer or service name */
    const char *proto;		/* "tcp" or "udp", typically */
    int *portPtr;		/* Return port number */
{
    struct servent *sp;		/* Protocol info for named services */
    Tcl_DString ds;
    const char *native;

    if (Tcl_GetInt(NULL, string, portPtr) != TCL_OK) {
	/*
	 * Don't bother translating 'proto' to native.
	 */
	 
	native = Tcl_UtfToExternalDString(NULL, string, -1, &ds);
	sp = getservbyname(native, proto);		/* INTL: Native. */
	Tcl_DStringFree(&ds);
	if (sp != NULL) {
	    *portPtr = ntohs((unsigned short) sp->s_port);
	    return TCL_OK;
	}
    }
    if (Tcl_GetInt(interp, string, portPtr) != TCL_OK) {
	return TCL_ERROR;
    }
    if (*portPtr > 0xFFFF) {
        return qseterr("couldn't open cep: port number too high");
    }
    return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * CepAcceptCallbacksDeleteProc --
 *
 *      Assocdata cleanup routine called when an interpreter is being
 *      deleted to set the interp field of all the accept callback records
 *      registered with the interpreter to NULL. This will prevent the
 *      interpreter from being used in the future to eval accept scripts.
 *
 * Results:
 *      None.
 *
 * Side effects:
 *      Deallocates memory and sets the interp field of all the accept
 *      callback records to NULL to prevent this interpreter from being
 *      used subsequently to eval accept scripts.
 *
 *----------------------------------------------------------------------
 */

static void
CepAcceptCallbacksDeleteProc (clientData, interp)
    ClientData clientData;      /* Data which was passed when the assocdata
                                 * was registered. */
    Tcl_Interp *interp;         /* Interpreter being deleted - not used. */
{
    Tcl_HashTable *hTblPtr;
    Tcl_HashEntry *hPtr;
    Tcl_HashSearch hSearch;
    AcceptCallback *acceptCallbackPtr;

    hTblPtr = (Tcl_HashTable *) clientData;
    for (hPtr = Tcl_FirstHashEntry(hTblPtr, &hSearch);
             hPtr != (Tcl_HashEntry *) NULL;
             hPtr = Tcl_NextHashEntry(&hSearch)) {
        acceptCallbackPtr = (AcceptCallback *) Tcl_GetHashValue(hPtr);
        acceptCallbackPtr->interp = (Tcl_Interp *) NULL;
    }
    Tcl_DeleteHashTable(hTblPtr);
    ckfree((char *) hTblPtr);
}

/*
 *----------------------------------------------------------------------
 *
 * RegisterCepServerInterpCleanup --
 *
 *	Registers an accept callback record to have its interp
 *	field set to NULL when the interpreter is deleted.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	When, in the future, the interpreter is deleted, the interp
 *	field of the accept callback data structure will be set to
 *	NULL. This will prevent attempts to eval the accept script
 *	in a deleted interpreter.
 *
 *----------------------------------------------------------------------
 */

static void
RegisterCepServerInterpCleanup (interp, acceptCallbackPtr)
    Tcl_Interp *interp;		/* Interpreter for which we want to be
                                 * informed of deletion. */
    AcceptCallback *acceptCallbackPtr;
    				/* The accept callback record whose
                                 * interp field we want set to NULL when
                                 * the interpreter is deleted. */
{
    Tcl_HashTable *hTblPtr;	/* Hash table for accept callback
                                 * records to smash when the interpreter
                                 * will be deleted. */
    Tcl_HashEntry *hPtr;	/* Entry for this record. */
    int new;			/* Is the entry new? */

    hTblPtr = (Tcl_HashTable *) Tcl_GetAssocData(interp,
            "CepAcceptCallbacks",
            NULL);
    if (hTblPtr == (Tcl_HashTable *) NULL) {
        hTblPtr = (Tcl_HashTable *) ckalloc((unsigned) sizeof(Tcl_HashTable));
        Tcl_InitHashTable(hTblPtr, TCL_ONE_WORD_KEYS);
        (void) Tcl_SetAssocData(interp, "CepAcceptCallbacks",
                CepAcceptCallbacksDeleteProc, (ClientData) hTblPtr);
    }
    hPtr = Tcl_CreateHashEntry(hTblPtr, (char *) acceptCallbackPtr, &new);
    if (!new) {
        Tcl_Panic("RegisterCepServerInterpCleanup: damaged accept record table");
    }
    Tcl_SetHashValue(hPtr, (ClientData) acceptCallbackPtr);
}

/*
 *----------------------------------------------------------------------
 *
 * UnregisterCepServerInterpCleanupProc --
 *
 *	Unregister a previously registered accept callback record. The
 *	interp field of this record will no longer be set to NULL in
 *	the future when the interpreter is deleted.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Prevents the interp field of the accept callback record from
 *	being set to NULL in the future when the interpreter is deleted.
 *
 *----------------------------------------------------------------------
 */

static void
UnregisterCepServerInterpCleanupProc (interp, acceptCallbackPtr)
    Tcl_Interp *interp;		/* Interpreter in which the accept callback
                                 * record was registered. */
    AcceptCallback *acceptCallbackPtr;
    				/* The record for which to delete the
                                 * registration. */
{
    Tcl_HashTable *hTblPtr;
    Tcl_HashEntry *hPtr;

    hTblPtr = (Tcl_HashTable *) Tcl_GetAssocData(interp,
            "CepAcceptCallbacks", NULL);
    if (hTblPtr == (Tcl_HashTable *) NULL) {
        return;
    }
    hPtr = Tcl_FindHashEntry(hTblPtr, (char *) acceptCallbackPtr);
    if (hPtr == (Tcl_HashEntry *) NULL) {
        return;
    }
    Tcl_DeleteHashEntry(hPtr);
}

/*
 *----------------------------------------------------------------------
 *
 * CepServerCloseProc --
 *
 *	This callback is called when the CEP server channel for which it
 *	was registered is being closed. It informs the interpreter in
 *	which the accept script is evaluated (if that interpreter still
 *	exists) that this channel no longer needs to be informed if the
 *	interpreter is deleted.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	In the future, if the interpreter is deleted this channel will
 *	no longer be informed.
 *
 *----------------------------------------------------------------------
 */

static void
CepServerCloseProc (callbackData)
    ClientData callbackData;	/* The data passed in the call to
                                 * Tcl_CreateCloseHandler. */
{
    AcceptCallback *acceptCallbackPtr;
    				/* The actual data. */

    acceptCallbackPtr = (AcceptCallback *) callbackData;
    if (acceptCallbackPtr->interp != (Tcl_Interp *) NULL) {
        UnregisterCepServerInterpCleanupProc(acceptCallbackPtr->interp,
                acceptCallbackPtr);
    }
    Tcl_EventuallyFree((ClientData) acceptCallbackPtr->script, TCL_DYNAMIC);
    ckfree((char *) acceptCallbackPtr);
}

/*
 *----------------------------------------------------------------------
 *
 * AcceptCallbackProc --
 *
 *	This callback is invoked by the CEP channel driver when it
 *	accepts a new connection from a client on a server socket.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Whatever the script does.
 *
 *----------------------------------------------------------------------
 */

static void
AcceptCallbackProc (callbackData, chan, addr, port, cepDomain, euid, egid, data)
    ClientData callbackData;		/* The data stored when the callback
                                         * was created in the call to
                                         * OpenCepServer. */
    Tcl_Channel chan;			/* Channel for the newly accepted
                                         * connection. */
    const char *addr ;			/* Address of client that was
                                         * accepted. */
    int port;
    int cepDomain;
    uid_t euid;
    gid_t egid;
    const unsigned char *data;
{
    AcceptCallback *acceptCallbackPtr;
    Tcl_Interp *tinterp;
    char *tscript;
    int result;
    Tcl_Obj *cmd[4];

    acceptCallbackPtr = (AcceptCallback *) callbackData;

    /*
     * Check if the callback is still valid; the interpreter may have gone
     * away, this is signalled by setting the interp field of the callback
     * data to NULL.
     */
    
    if (acceptCallbackPtr->interp != (Tcl_Interp *) NULL) {
        tscript = acceptCallbackPtr->script;
        tinterp = acceptCallbackPtr->interp;

	Tcl_Preserve((ClientData) tscript);
        Tcl_Preserve((ClientData) tinterp);

	cmd[0] = Tcl_NewStringObj(tscript, -1);
	cmd[1] = Tcl_NewStringObj(Tcl_GetChannelName(chan), -1);
	cmd[2] = Tcl_NewStringObj(addr, -1);

	if (cepDomain == CEP_LOCAL) {
	  cmd[3] = Tcl_NewObj();
	  Tcl_ListObjAppendElement(NULL, cmd[3], Tcl_NewIntObj((signed) euid));
	  Tcl_ListObjAppendElement(NULL, cmd[3], Tcl_NewIntObj((signed) egid));
	} else {
	  cmd[3] = Tcl_NewIntObj(port);
	}

        Tcl_RegisterChannel(tinterp, chan);

        /*
         * Artificially bump the refcount to protect the channel from
         * being deleted while the script is being evaluated.
         */

        Tcl_RegisterChannel((Tcl_Interp *) NULL,  chan);
        
	result = Tcl_EvalObjv(tinterp, 4, cmd, TCL_EVAL_GLOBAL);

        if (result != TCL_OK) {
            Tcl_BackgroundError(tinterp);
	    Tcl_UnregisterChannel(tinterp, chan);
        }

        /*
         * Decrement the artificially bumped refcount. After this it is
         * not safe anymore to use "chan", because it may now be deleted.
         */

        Tcl_UnregisterChannel((Tcl_Interp *) NULL, chan);
        
        Tcl_Release((ClientData) tinterp);
        Tcl_Release((ClientData) tscript);
    } else {

        /*
         * The interpreter has been deleted, so there is no useful
         * way to utilize the client socket - just close it.
         */

        Tcl_Close((Tcl_Interp *) NULL, chan);
    }
}

/*
 *----------------------------------------------------------------------
 *
 * ReceiverCallbackProc --
 *
 *	This callback is invoked by the CEP channel driver when it
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Whatever the script does.
 *
 *----------------------------------------------------------------------
 */

static void
ReceiverCallbackProc (callbackData, chan, addr, port, cepDomain, euid, egid, data)
    ClientData callbackData;		/* The data stored when the callback
                                         * was created in the call to
                                         * OpenCepServer. */
    Tcl_Channel chan;			/* Channel for the newly accepted
                                         * connection. */
    const char *addr ;			/* Address of client that was
                                         * accepted. */
    int port;
    int cepDomain;
    uid_t euid;
    gid_t egid;
    const unsigned char *data;
{
    AcceptCallback *acceptCallbackPtr;
    Tcl_Interp *tinterp;
    char *tscript;
    int result;
    Tcl_Obj *cmd[6];

    acceptCallbackPtr = (AcceptCallback *) callbackData;

    /*
     * Check if the callback is still valid; the interpreter may have gone
     * away, this is signalled by setting the interp field of the callback
     * data to NULL.
     */
    
    if (acceptCallbackPtr->interp != (Tcl_Interp *) NULL) {
        tscript = acceptCallbackPtr->script;
        tinterp = acceptCallbackPtr->interp;

        Tcl_Preserve((ClientData) tscript);
        Tcl_Preserve((ClientData) tinterp);

	cmd[0] = Tcl_NewStringObj(tscript, -1);
	cmd[1] = Tcl_NewStringObj(Tcl_GetChannelName(chan), -1);
	cmd[2] = Tcl_NewStringObj(addr, -1);
	cmd[3] = Tcl_NewIntObj(port);
	cmd[4] = Tcl_NewIntObj((signed) egid);
	cmd[5] = Tcl_NewByteArrayObj(data, (signed) egid);

        /*
         * Artificially bump the refcount to protect the channel from
         * being deleted while the script is being evaluated.
         */

        Tcl_RegisterChannel((Tcl_Interp *) NULL,  chan);
        
	result = Tcl_EvalObjv(tinterp, 6, cmd, TCL_EVAL_GLOBAL);

        if (result != TCL_OK) {
            Tcl_BackgroundError(tinterp);
	    Tcl_UnregisterChannel(tinterp, chan);
        }

        /*
         * Decrement the artificially bumped refcount. After this it is
         * not safe anymore to use "chan", because it may now be deleted.
         */

        Tcl_UnregisterChannel((Tcl_Interp *) NULL, chan);
        
        Tcl_Release((ClientData) tinterp);
        Tcl_Release((ClientData) tscript);
    }
}

/*
 *----------------------------------------------------------------------
 *
 * Cep_Cmd --
 *
 *	This procedure is invoked to process the "cep" Tcl command.
 *	See the user documentation for details on what it does.
 *
 * Results:
 *	A standard Tcl result.
 *
 * Side effects:
 *	Creates an cep based channel.
 *
 *----------------------------------------------------------------------
 */

static int
Cep_Cmd (notUsed, interp, objc, objv)
     ClientData notUsed;		/* Not used. */
     Tcl_Interp *interp;		/* Current interpreter. */
     int objc;				/* Number of arguments. */
     Tcl_Obj *const objv[];		/* Argument objects. */
{
  static const char *cepOptions[] = {
    "-async", "-domain", "-myaddr", "-myport", "-noresolve", "-noreuseaddr",
    "-protocol", "-receiver", "-reuseport", "-server", "-type", (char *) NULL
  };
  enum cepOptions {
    CEP_ASYNC, CEP_DOMAIN, CEP_MYADDR, CEP_MYPORT, CEP_NORESOLVE, CEP_NOREUSEADDR, CEP_PROTOCOL,
    CEP_RECEIVER, CEP_REUSEPORT, CEP_SERVER, CEP_TYPE
  };

  Tcl_Channel chan;
  AcceptCallback *acceptCallbackPtr;
  int server = 0;
  int receiver = 0;
  int localpair = 0;
  int async = 0;
  int port = 0;
  int cepDomain = CEP_INET;
  int cepType = CEP_STREAM;
  int optionIndex;
  int a;
  const char *name = NULL;
  const char *arg;
  char *copyScript;
  const char *script = NULL;
  const char *myaddr = NULL;
  const char *myportName = NULL;
  int myport = 0;
  const char *protocol = NULL;
  int resolve = 1;
  int reuseaddr = 1;
  int reuseport = 0;
  int domainSpecified = 0;
  int typeSpecified = 0;


  for (a = 1; a < objc; a++) {
    arg = Tcl_GetString(objv[a]);
    if (arg[0] != '-') {
      break;
    }
    if (Tcl_GetIndexFromObj(interp, objv[a], cepOptions,
			    "option", TCL_EXACT, &optionIndex) != TCL_OK) {
      return TCL_ERROR;
    }
    switch ((enum cepOptions) optionIndex) {
    case CEP_ASYNC: {
      async = 1;		
      break;
    }
    case CEP_NORESOLVE: {
      resolve = 0;
      break;
    }
    case CEP_NOREUSEADDR: {
      reuseaddr = 0;
      break;
    }
    case CEP_REUSEPORT: {
      reuseport = 0;
      break;
    }
    case CEP_MYADDR: {
      a++;
      if (a >= objc) {
	return qseterr("no argument given for -myaddr option");
      }
      myaddr = Tcl_GetString(objv[a]);
      break;
    }
    case CEP_MYPORT: {
      a++;
      if (a >= objc) {
	return qseterr("no argument given for -myport option");
      }
      myportName = Tcl_GetString(objv[a]);
      break;
    }
    case CEP_SERVER: {
      a++;
      if (a >= objc) {
	return qseterr("no argument given for -server option");
      }
      script = Tcl_GetString(objv[a]);
      server = 1;
      break;
    }
    case CEP_RECEIVER: {
      a++;
      if (a >= objc) {
	return qseterr("no argument given for -receiver option");
      }
      script = Tcl_GetString(objv[a]);
      receiver = 1;
      break;
    }
    case CEP_DOMAIN: {
      static const char *domainOptions[] = {
	"inet", "inet6", "local", (char *) NULL
      };
      enum domainOptions {
	DOMAIN_INET, DOMAIN_INET6, DOMAIN_LOCAL
      };
      int domainIndex;

      a++;
      if (a >= objc) {
	return qseterr("no argument given for -domain option");
      }

      if (Tcl_GetIndexFromObj(interp, objv[a], domainOptions,
			      "option", TCL_EXACT, &domainIndex) != TCL_OK) {
	return TCL_ERROR;
      }

      switch ((enum domainOptions) domainIndex) {
      case DOMAIN_INET: {
	cepDomain = CEP_INET;
	break;
      }
      case DOMAIN_INET6: {
	cepDomain = CEP_INET6;
	break;
      }
      case DOMAIN_LOCAL: {
	cepDomain = CEP_LOCAL;
	break;
      }
      default: {
	break;
      }
      }
      domainSpecified = 1;
      break;
    }
    case CEP_TYPE: {
      static const char *typeOptions[] = {
	"datagram", "raw", "stream", (char *) NULL
      };
      enum typeOptions {
	TYPE_DGRAM, TYPE_RAW, TYPE_STREAM
      };
      int typeIndex;
      a++;
      if (a >= objc) {
	return qseterr("no argument given for -type option");
      }
      if (Tcl_GetIndexFromObj(interp, objv[a], typeOptions,
			      "option", TCL_EXACT, &typeIndex) != TCL_OK) {
	return TCL_ERROR;
      }
      switch ((enum typeOptions) typeIndex) {
      case TYPE_DGRAM: {
	cepType = CEP_DGRAM;
	break;
      }
      case TYPE_STREAM: {
	cepType = CEP_STREAM;
	break;
      }
      case TYPE_RAW: {
	cepType = CEP_RAW;
	break;
      }
      default: {
	break;
      }
      }
      typeSpecified = 1;
      break;
    }
    case CEP_PROTOCOL: {
      a++;
      if (a >= objc) {
	return qseterr("no argument given for -protocol option");
      }
      protocol = Tcl_GetString(objv[a]);
      break;
    }
    default: {
      Tcl_Panic("Cep_Cmd: bad option index to cepOptions");
    }
    }
  }

  if (async) {
    if (server) {
      return qseterr("cannot set -async option for server ceps");
    }
    if (receiver) {
      return qseterr("cannot set -async option for receiver ceps");
    }
  }

  if (server && receiver) {
    return qseterr("-server and -receiver are mutually exclusive");
  }

  if (receiver) {
    if (cepType == CEP_STREAM) {
      if (typeSpecified) {
	return qseterr("cannot use type stream with receiver ceps");
      } else {
	cepType = CEP_DGRAM;
      }
    }
  }

  if (myportName != NULL) {
    if (_TCL_SockGetPort(interp, myportName, (cepType == CEP_STREAM ? "tcp" : "udp"), &myport) != TCL_OK) {
      return TCL_ERROR;
    }
  }

  if (server || receiver) {
    if (cepDomain == CEP_INET6 || cepDomain == CEP_INET) {
      name = myaddr;          /* NULL implies INADDR_ANY */
    } else {
      name = Tcl_GetString(objv[a]);
      a++;
    }
    if (myport != 0) {
      return qseterr("Option -myport is not valid for servers");
    }
  } else if (a < objc) {
    name = Tcl_GetString(objv[a]);
    a++;
  }

  if (a < objc) {
    if (_TCL_SockGetPort(interp, (const char *) Tcl_GetString(objv[a]), (cepType == CEP_STREAM ? "tcp" : "udp"), &port) != TCL_OK) {
      return TCL_ERROR;
    }
    a++;
  }

  if ((a == objc) && (cepDomain == CEP_LOCAL || !domainSpecified) && (name == NULL) && !server && !receiver) {
    cepDomain = CEP_LOCAL;
    localpair = 1;
  } else if (a != objc) {
    Tcl_ResetResult(interp);
    Tcl_AppendResult(interp, "wrong # args: should be either:\n",
		     Tcl_GetString(objv[0]), " ?-domain local? ?-type type?\n",
		     Tcl_GetString(objv[0]), " ?-domain domain? ?-type type? ?-protocol protocol? ?-myaddr addr? ?-myport myport? ?-noresolve? ?-noreuseaddr? ?-reuseport? ?-async? host ?port?\n",
		     Tcl_GetString(objv[0]), " ?-domain domain? ?-type type? ?-noreuseaddr? ?-reuseport? -server command ?port/name?\n",
		     Tcl_GetString(objv[0]), " ?-domain domain? ?-type type? ?-noreuseaddr? ?-reuseport? -receiver command ?port?",
		     (char *) NULL);
    return TCL_ERROR;
  }

  if (server || receiver) {
      acceptCallbackPtr = (AcceptCallback *) ckalloc((unsigned) sizeof(AcceptCallback));
      acceptCallbackPtr->interp = interp;
      copyScript = ckalloc((unsigned) strlen(script) + 1);
      strcpy(copyScript, script);
      acceptCallbackPtr->script = copyScript;

      chan = Cep_OpenServer(interp, receiver, cepDomain, cepType, protocol, (const char *) name, port,
			    resolve, reuseaddr, reuseport,
			    (receiver ? ReceiverCallbackProc : AcceptCallbackProc),
			    (ClientData) acceptCallbackPtr);
      if (chan == (Tcl_Channel) NULL) {
	ckfree(copyScript);
	ckfree((char *) acceptCallbackPtr);
	return TCL_ERROR;
      }

    /*
     * Register with the interpreter to let us know when the
     * interpreter is deleted (by having the callback set the
     * acceptCallbackPtr->interp field to NULL). This is to
     * avoid trying to eval the script in a deleted interpreter.
     */

    RegisterCepServerInterpCleanup(interp, acceptCallbackPtr);
        
    /*
     * Register a close callback. This callback will inform the
     * interpreter (if it still exists) that this channel does not
     * need to be informed when the interpreter is deleted.
     */

    Tcl_CreateCloseHandler(chan, CepServerCloseProc, (ClientData) acceptCallbackPtr);

  } else if (localpair) {
    Tcl_Channel chan2;
    if (async) {
      return qseterr("cannot set -async option for localpair ceps");
    }
    if (myaddr != NULL) {
      return qseterr("cannot set -myaddr option for localpair ceps");
    }
    if (myportName != NULL) {
      return qseterr("cannot set -myport option for localpair ceps");
    }
    if (Cep_OpenLocalPair(interp, cepDomain, cepType, protocol, &chan, &chan2) != 0) {
      return TCL_ERROR;
    }
    Tcl_RegisterChannel(interp, chan);
    Tcl_RegisterChannel(interp, chan2);
    Tcl_ResetResult(interp);
    Tcl_AppendResult(interp, Tcl_GetChannelName(chan), " ", Tcl_GetChannelName(chan2), (char *) NULL);
    return TCL_OK;
  } else {
    chan = Cep_OpenClient(interp, cepDomain, cepType, protocol,
			  ((port == -1 && strlen(name) == 0) ? NULL : name), port,
			  myaddr, myport, async, resolve, reuseaddr, reuseport);
    if (chan == (Tcl_Channel) NULL) {
      return TCL_ERROR;
    }
  }

  /* localpair is handled above */
  Tcl_RegisterChannel(interp, chan);
  qseterr(Tcl_GetChannelName(chan));
  return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * Sendto_Cmd --
 *
 *	This procedure is invoked to process the "sendto" Tcl command.
 *	See the user documentation for details on what it does.
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *----------------------------------------------------------------------
 */

static int
Sendto_Cmd (notUsed, interp, objc, objv)
     ClientData notUsed;		/* Not used. */
     Tcl_Interp *interp;		/* Current interpreter. */
     int objc;				/* Number of arguments. */
     Tcl_Obj *const objv[];		/* Argument objects. */
{
  Tcl_Channel chan;
  int port;
  const unsigned char *data;
  int dataLen;

  if (objc != 5) {
    return Cep_SetInterpResultError(interp, "Wrong # args: should be \"", Tcl_GetString(objv[0]),
				    " channelId, addr port message\"", (char *) NULL);
  }

  chan = Tcl_GetChannel(interp, Tcl_GetString(objv[1]), NULL);
  if (chan == NULL) {
    return TCL_ERROR;
  }

  if (_TCL_SockGetPort(interp, (const char *) Tcl_GetString(objv[3]), ("udp"), &port) != TCL_OK) {
    return TCL_ERROR;
  }

  data = Tcl_GetByteArrayFromObj(objv[4], &dataLen);
  /* Not sure if this ever returns null */
  if (data == NULL) {
    return TCL_ERROR;
  }

  dataLen = Cep_Sendto(chan, (const char *) Tcl_GetString(objv[2]), port, data, dataLen);
  if (dataLen == -1) {
    return TCL_ERROR;
  }

  Tcl_SetObjResult(interp, Tcl_NewIntObj(dataLen));

  return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * Ceptcl_Init --
 *
 *      Initialize the new package.  The string "Cep" in the
 *      function name must match the PACKAGE declaration at the top of
 *      configure.in.
 *
 * Results:
 *      A standard Tcl result
 *
 * Side effects:
 *      The cep package is created.
 *      One new command "cep" is added to the Tcl interpreter.
 *
 *----------------------------------------------------------------------
 */

int
Ceptcl_Init (Tcl_Interp *interp)
{
  /*
   * This may work with 8.0, but we are using strictly stubs here,
   * which requires 8.1.
   */
  if (Tcl_InitStubs(interp, "8.1", 0) == NULL) {
    return TCL_ERROR;
  }
  if (Tcl_PkgRequire(interp, "Tcl", "8.1", 0) == NULL) {
    return TCL_ERROR;
  }
  if (Tcl_PkgProvide(interp, "ceptcl", VERSION) != TCL_OK) {
    return TCL_ERROR;
  }

  Tcl_CreateObjCommand(interp, "cep", Cep_Cmd,
		       (ClientData) NULL, (Tcl_CmdDeleteProc *) NULL);
  Tcl_CreateObjCommand(interp, "sendto", Sendto_Cmd,
		       (ClientData) NULL, (Tcl_CmdDeleteProc *) NULL);

  return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * Ceptcl_SafeInit --
 *
 *      Initialize the new package.  The string "Cep" in the
 *      function name must match the PACKAGE declaration at the top of
 *      configure.in.
 *
 * Results:
 *      A standard Tcl result
 *
 * Side effects:
 *      The cep package is created.
 *      No commands are added
 *
 *----------------------------------------------------------------------
 */

int
Ceptcl_SafeInit (Tcl_Interp *interp)
{
  /*
   * This may work with 8.0, but we are using strictly stubs here,
   * which requires 8.1.
   */
  if (Tcl_InitStubs(interp, "8.1", 0) == NULL) {
    return TCL_ERROR;
  }
  if (Tcl_PkgRequire(interp, "Tcl", "8.1", 0) == NULL) {
    return TCL_ERROR;
  }
  if (Tcl_PkgProvide(interp, "ceptcl", VERSION) != TCL_OK) {
    return TCL_ERROR;
  }

  /*
  Tcl_CreateObjCommand(interp, "cep", Cep_Cmd,
		       (ClientData) NULL, (Tcl_CmdDeleteProc *) NULL);
  Tcl_CreateObjCommand(interp, "sendto", Sendto_Cmd,
		       (ClientData) NULL, (Tcl_CmdDeleteProc *) NULL);
  */

  return TCL_OK;
}


/* EOF */
