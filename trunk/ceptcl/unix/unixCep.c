/* 
 * unixCep.c
 *
 *	Channel driver for various socket types,
 *      or Communications EndPoints (CEPs)
 *
 * This was originally unix/tclUnixChan.c
 *
 *
 * Copyright (c) 1995-1997 Sun Microsystems, Inc.
 * Copyright (c) 1998-1999 by Scriptics Corporation.
 * Copyright (c) 2003-2004 by Stuart Cassoff
 *
 * See the file "license.terms" for information on usage and redistribution
 * of this file, and for a DISCLAIMER OF ALL WARRANTIES.
 *
 */


/* Most of the include/define stuff was taken from unix/tclUnixPort.h */
/* I'm not sure if I really need all of it */
#include <errno.h>
#include <fcntl.h>

#ifdef HAVE_NET_ERRNO_H
#   include <net/errno.h>
#endif

#include <sys/types.h>

#if TIME_WITH_SYS_TIME
#   include <sys/time.h>
#   include <time.h>
#else
#if HAVE_SYS_TIME_H
#   include <sys/time.h>
#else
#   include <time.h>
#endif
#endif

#ifdef HAVE_UNISTD_H
#   include <unistd.h>
#else
#   include "../compat/unistd.h"
#endif

#ifdef  USE_FIONBIO
/*
 * Not using the Posix fcntl(...,O_NONBLOCK,...) interface, instead
 * we are using ioctl(..,FIONBIO,..).
 */
#  ifdef HAVE_SYS_FILIO_H
#    include <sys/filio.h>   /* For FIONBIO. */
#  endif
#endif  /* USE_FIONBIO */

#ifdef HAVE_SYS_IOCTL_H
#  include <sys/ioctl.h>   /* For FIONBIO and/or FIONREAD */
#endif

#ifndef HAVE_GETPEEREID
#   include "../compat/openbsd-compat.h"
#endif

#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <net/if.h>
#include <assert.h>
#include <string.h>
#include <tcl.h>

#include "../generic/ceptcl.h"


#ifdef SO_REUSEPORT
#  define CEP_REUSEPORT SO_REUSEPORT
#else
#  define CEP_REUSEPORT SO_REUSEADDR
#endif

/* This little bit is from generic/tclIO.h */
/* I'm not sure that it's needed */
/*
 * Make sure that both EAGAIN and EWOULDBLOCK are defined. This does not
 * compile on systems where neither is defined. We want both defined so
 * that we can test safely for both. In the code we still have to test for
 * both because there may be systems on which both are defined and have
 * different values.
 */

#if ((!defined(EWOULDBLOCK)) && (defined(EAGAIN)))
#  define EWOULDBLOCK EAGAIN
#endif

/*
#if ((!defined(EAGAIN)) && (defined(EWOULDBLOCK)))
#  define EAGAIN EWOULDBLOCK
#endif
*/

#if ((!defined(EAGAIN)) && (!defined(EWOULDBLOCK)))
error one of EWOULDBLOCK or EAGAIN must be defined
#endif


/* The rest here was taken from unix/tclUnixPort.h */
/*
 * The following defines the maximum length of the listen queue. This is
 * the number of outstanding yet-to-be-serviced requests for a connection
 * on a server cep, more than this number of outstanding requests and
 * the connection request will fail.
 */

#ifndef SOMAXCONN
#   define SOMAXCONN	100
#endif /* SOMAXCONN */

#if (SOMAXCONN < 100)
#   undef  SOMAXCONN
#   define SOMAXCONN	100
#endif /* SOMAXCONN < 100 */

/*
 * The following defines how much buffer space the kernel should maintain
 * for a cep (socket).
 */

#define SOCKET_BUFSIZE	4096

/*
 * Define FD_CLOEEXEC (the close-on-exec flag bit) if it isn't
 * already defined.
 */

#ifndef FD_CLOEXEC
#   define FD_CLOEXEC 1
#endif

/*
 * The following macro defines the type of the mask arguments to
 * select:
 */

#ifndef NO_FD_SET
#   define SELECT_MASK fd_set
#else /* NO_FD_SET */
#   ifndef _AIX
        typedef long fd_mask;
#   endif /* !AIX */
#   if defined(_IBMR2)
#       define SELECT_MASK void
#   else /* !defined(_IBMR2) */
#       define SELECT_MASK int
#   endif /* defined(_IBMR2) */
#endif /* !NO_FD_SET */

/*
 * Define "NBBY" (number of bits per byte) if it's not already defined.
 */

#ifndef NBBY
#   define NBBY 8
#endif

/*
 * The following macro defines the number of fd_masks in an fd_set:
 */

#ifndef FD_SETSIZE
#   ifdef OPEN_MAX
#       define FD_SETSIZE OPEN_MAX
#   else
#       define FD_SETSIZE 256
#   endif
#endif /* FD_SETSIZE */
#if !defined(howmany)
#   define howmany(x, y) (((x)+((y)-1))/(y))
#endif /* !defined(howmany) */
#ifndef NFDBITS
#   define NFDBITS NBBY*sizeof(fd_mask)
#endif /* NFDBITS */
#define MASK_SIZE howmany(FD_SETSIZE, NFDBITS)


/* The rest of the code was originally unix/tclUnixChan.c or is new code */

#define CEP_CHANNELNAME_MAX (16 + TCL_INTEGER_SPACE)
#define CEP_HOSTNAME_MAX (NI_MAXHOST + 1)

/*
 * This structure describes per-instance state of a cep based channel.
 */

typedef struct CepState {
  Tcl_Channel channel;	/* Channel associated with this file. */
  int fd;			/* The cep itself. */
  unsigned int flags;		/* ORed combination of the bitfields
				 * defined below. */
  int protocol;
  CepAcceptProc *acceptProc;	/* Proc to call on accept. */
  ClientData acceptProcData;	/* The data for the accept proc. */
} CepState;


/*
 * These bits may be ORed together into the "flags" field of a CepState
 * structure.
 */

/*
 *
 *  uuuu ttt ddd 111111
 *  |||| ||| ||| ||||||- Asynchronous cep
 *  |||| ||| ||| |||||-- Async connect in progress
 *  |||| ||| ||| ||||--- Cep is server.
 *  |||| ||| ||| |||---- Read is shut down
 *  |||| ||| ||| ||----- Write is shut down
 *  |||| ||| ||| |------ Resolve names
 *  |||| ||| |||-------- Domain
 *  |||| |||------------ Type
 *  ||||---------------- Undefined
 *
 */

#define CEP_ASYNC_CEP      (1 << 0)  /* Asynchronous cep. */
#define CEP_ASYNC_CONNECT  (1 << 1)  /* Async connect in progress. */
#define CEP_SERVER_CEP     (1 << 2)  /* 1 == cep is a server */
#define CEP_SHUT_READ      (1 << 3)  /* Shutdown for reading */
#define CEP_SHUT_WRITE     (1 << 4)  /* Shutdown for writing */
#define CEP_RESOLVE_NAMES  (1 << 5)  /* Resolve names */
#define DOMAIN_SHIFT       6
#define TYPE_SHIFT         9
#define BASE_MASK          0x07
#define DOMAIN2MASK(D)     ((D & BASE_MASK) << DOMAIN_SHIFT)
#define TYPE2MASK(T)       ((T & BASE_MASK) << TYPE_SHIFT)
#define MASK2DOMAIN(M)     ((M >> DOMAIN_SHIFT) & BASE_MASK)
#define MASK2TYPE(M)       ((M >> TYPE_SHIFT) & BASE_MASK)


/*
 * Static routines for this file:
 */

static CepState *	CreateCep _ANSI_ARGS_((Tcl_Interp *interp,
					       int cepDomain, int cepType,
					       const char *protocol,
					       const char *host, int port, int server,
					       const char *myaddr, int myport,
					       int async, int resolve,
					       int reuseaddr, int reuseport));

static void		CepAccept _ANSI_ARGS_((ClientData data, int mask));

static void		CepReceiverListen _ANSI_ARGS_((ClientData data, int mask));

static int		CepBlockModeProc _ANSI_ARGS_((ClientData data,
						      int mode));

static int		CepCloseProc _ANSI_ARGS_((ClientData instanceData,
						  Tcl_Interp *interp, int flags));

static int		CepGetHandleProc _ANSI_ARGS_((ClientData instanceData,
						      int direction, ClientData *handlePtr));

static int		CepGetOptionProc _ANSI_ARGS_((ClientData instanceData,
						      Tcl_Interp *interp, const char *optionName,
						      Tcl_DString *dsPtr));

static int		CepSetOptionProc _ANSI_ARGS_((ClientData instanceData,
						      Tcl_Interp *interp, const char *optionName,
						      const char *value));

static int		CepInputProc _ANSI_ARGS_((ClientData instanceData,
						  char *buf, int toRead,  int *errorCode));

static int		CepOutputProc _ANSI_ARGS_((ClientData instanceData,
						   const char *buf, int toWrite, int *errorCode));

static void		CepWatchProc _ANSI_ARGS_((ClientData instanceData,
						  int mask));

static int		WaitForConnect _ANSI_ARGS_((CepState *statePtr,
						    int *errorCodePtr));

static Tcl_Channel	MakeCepClientChannelMode _ANSI_ARGS_(
							     (ClientData sock,
							      int cepDomain,
							      int cepType,
							      int protocol,
							      int resolve,
							      int mode));

static int		CreateCepAddress _ANSI_ARGS_(
						     (int cepDomain,
						      struct sockaddr_storage *sockaddrPtr,
						      const char *host, int port, int resolve));

static int              CepDomainToSysDomain (int cepDomain);
static int              SysDomainToCepDomain (int sysDomain);
static int              CepTypeToSysType (int cepType);
static int              SysTypeToCepType (int sysType);
static socklen_t        GetSocketStructSize (int cepDomain);
static int              NameToAddr (int family, const char *host, void *addrPtr, int resolve);

static int              _TCL_SockMinimumBuffers _ANSI_ARGS_((int sock, int size));
static int              _TCL_UnixWaitForFile _ANSI_ARGS_((int fd, int mask, int timeout));


/*
 * This structure describes the channel type structure for cep
 * based IO:
 */

static Tcl_ChannelType cepChannelType = {
  (char *) "cep",        /* Type name. */
  TCL_CHANNEL_VERSION_2, /* v2 channel */
  TCL_CLOSE2PROC,        /* Close proc. */
  CepInputProc,          /* Input proc. */
  CepOutputProc,         /* Output proc. */
  NULL,                  /* Seek proc. */
  CepSetOptionProc,      /* Set option proc. */
  CepGetOptionProc,      /* Get option proc. */
  CepWatchProc,          /* Initialize notifier. */
  CepGetHandleProc,      /* Get OS handles out of channel. */
  CepCloseProc,          /* close2proc. */
  CepBlockModeProc,      /* Set blocking or non-blocking mode.*/
  NULL,                  /* flush proc. */
  NULL,                  /* handler proc. */
};


/*
 *----------------------------------------------------------------------
 *
 * _TCL_SockMinimumBuffers --
 *
 * This was TclSockMinimumbuffers from generic/tclIO.c
 *
 *      Ensure minimum buffer sizes (non zero).
 *
 * Results:
 *      A standard Tcl result.
 *
 * Side effects:
 *      Sets SO_SNDBUF and SO_RCVBUF sizes.
 *
 *----------------------------------------------------------------------
 */

static int
_TCL_SockMinimumBuffers(sock, size)
    int sock;                   /* Socket file descriptor */
    int size;                   /* Minimum buffer size */
{
    int current;
    socklen_t len;

    len = sizeof(int);
    getsockopt(sock, SOL_SOCKET, SO_SNDBUF, (char *) &current, &len);
    if (current < size) {
        len = sizeof(int);
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, (char *) &size, len);
    }
    len = sizeof(int);
    getsockopt(sock, SOL_SOCKET, SO_RCVBUF, (char *) &current, &len);
    if (current < size) {
        len = sizeof(int);
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, (char *) &size, len);
    }
    return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * _TCL_UnixWaitForFile --
 *
 * Original excpet changed 'index' to 'maskIndex'
 * To avoid compiler warning '-Wshadow'
 *
 *	This procedure waits synchronously for a file to become readable
 *	or writable, with an optional timeout.
 *
 * Results:
 *	The return value is an OR'ed combination of TCL_READABLE,
 *	TCL_WRITABLE, and TCL_EXCEPTION, indicating the conditions
 *	that are present on file at the time of the return.  This
 *	procedure will not return until either "timeout" milliseconds
 *	have elapsed or at least one of the conditions given by mask
 *	has occurred for file (a return value of 0 means that a timeout
 *	occurred).  No normal events will be serviced during the
 *	execution of this procedure.
 *
 * Side effects:
 *	Time passes.
 *
 *----------------------------------------------------------------------
 */

static int
_TCL_UnixWaitForFile(fd, mask, timeout)
    int fd;			/* Handle for file on which to wait. */
    int mask;			/* What to wait for: OR'ed combination of
				 * TCL_READABLE, TCL_WRITABLE, and
				 * TCL_EXCEPTION. */
    int timeout;		/* Maximum amount of time to wait for one
				 * of the conditions in mask to occur, in
				 * milliseconds.  A value of 0 means don't
				 * wait at all, and a value of -1 means
				 * wait forever. */
{
    Tcl_Time abortTime, now;
    struct timeval blockTime, *timeoutPtr;
    int maskIndex, bit, numFound, result = 0;
    fd_mask readyMasks[3*MASK_SIZE];
				/* This array reflects the readable/writable
				 * conditions that were found to exist by the
				 * last call to select. */

    /*
     * If there is a non-zero finite timeout, compute the time when
     * we give up.
     */

    if (timeout > 0) {
	Tcl_GetTime(&now);
	abortTime.sec = now.sec + timeout/1000;
	abortTime.usec = now.usec + (timeout%1000)*1000;
	if (abortTime.usec >= 1000000) {
	    abortTime.usec -= 1000000;
	    abortTime.sec += 1;
	}
	timeoutPtr = &blockTime;
    } else if (timeout == 0) {
	timeoutPtr = &blockTime;
	blockTime.tv_sec = 0;
	blockTime.tv_usec = 0;
    } else {
	timeoutPtr = NULL;
    }

    /*
     * Initialize the ready masks and compute the mask offsets.
     */

    if (fd >= FD_SETSIZE) {
	Tcl_Panic("_TCL_WaitForFile can't handle file id %d", fd);
    }
    memset((VOID *) readyMasks, 0, 3*MASK_SIZE*sizeof(fd_mask));
    maskIndex = fd/(NBBY*sizeof(fd_mask));
    bit = 1 << (fd%(NBBY*sizeof(fd_mask)));

    /*
     * Loop in a mini-event loop of our own, waiting for either the
     * file to become ready or a timeout to occur.
     */

    while (1) {
	if (timeout > 0) {
	    blockTime.tv_sec = abortTime.sec - now.sec;
	    blockTime.tv_usec = abortTime.usec - now.usec;
	    if (blockTime.tv_usec < 0) {
		blockTime.tv_sec -= 1;
		blockTime.tv_usec += 1000000;
	    }
	    if (blockTime.tv_sec < 0) {
		blockTime.tv_sec = 0;
		blockTime.tv_usec = 0;
	    }
	}

	/*
	 * Set the appropriate bit in the ready masks for the fd.
	 */

	if (mask & TCL_READABLE) {
	    readyMasks[maskIndex] |= bit;
	}
	if (mask & TCL_WRITABLE) {
	    (readyMasks+MASK_SIZE)[maskIndex] |= bit;
	}
	if (mask & TCL_EXCEPTION) {
	    (readyMasks+2*(MASK_SIZE))[maskIndex] |= bit;
	}

	/*
	 * Wait for the event or a timeout.
	 */

	numFound = select(fd+1, (SELECT_MASK *) &readyMasks[0],
		(SELECT_MASK *) &readyMasks[MASK_SIZE],
		(SELECT_MASK *) &readyMasks[2*MASK_SIZE], timeoutPtr);
	if (numFound == 1) {
	    if (readyMasks[maskIndex] & bit) {
		result |= TCL_READABLE;
	    }
	    if ((readyMasks+MASK_SIZE)[maskIndex] & bit) {
		result |= TCL_WRITABLE;
	    }
	    if ((readyMasks+2*(MASK_SIZE))[maskIndex] & bit) {
		result |= TCL_EXCEPTION;
	    }
	    result &= mask;
	    if (result) {
		break;
	    }
	}
	if (timeout == 0) {
	    break;
	}

	/*
	 * The select returned early, so we need to recompute the timeout.
	 */

	Tcl_GetTime(&now);
	if ((abortTime.sec < now.sec)
		|| ((abortTime.sec == now.sec)
		&& (abortTime.usec <= now.usec))) {
	    break;
	}
    }
    return result;
}

/*
 *----------------------------------------------------------------------
 *
 * WaitForConnect --
 *
 *	Waits for a connection on an asynchronously opened cep to
 *	be completed.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	The cep is connected after this function returns.
 *
 *----------------------------------------------------------------------
 */

static int
WaitForConnect (statePtr, errorCodePtr)
     CepState *statePtr;		/* State of the cep. */
     int *errorCodePtr;		/* Where to store errors? */
{
  int timeOut;		/* How long to wait. */
  int state;			/* Of calling TclWaitForFile. */
  int flags;			/* fcntl flags for the cep. */

  /*
   * If an asynchronous connect is in progress, attempt to wait for it
   * to complete before reading.
   */

  if (statePtr->flags & CEP_ASYNC_CONNECT) {
    if (statePtr->flags & CEP_ASYNC_CEP) {
      timeOut = 0;
    } else {
      timeOut = -1;
    }
    Tcl_SetErrno(0);
    state = _TCL_UnixWaitForFile(statePtr->fd,
				   TCL_WRITABLE | TCL_EXCEPTION, timeOut);
    if (!(statePtr->flags & CEP_ASYNC_CEP)) {
#ifndef USE_FIONBIO
      flags = fcntl(statePtr->fd, F_GETFL);
      flags &= (~(O_NONBLOCK));
      (void) fcntl(statePtr->fd, F_SETFL, flags);
#else /* USE_FIONBIO */
      flags = 0;
      (void) ioctl(statePtr->fd, FIONBIO, &flags);
#endif /* !USE_FIONBIO */
    }
    if (state & TCL_EXCEPTION) {
      return -1;
    }
    if (state & TCL_WRITABLE) {
      statePtr->flags &= (~(CEP_ASYNC_CONNECT));
    } else if (timeOut == 0) {
      Tcl_SetErrno(EWOULDBLOCK);
      *errorCodePtr = EWOULDBLOCK;
      return -1;
    }
  }
  return 0;
}

/*
 *----------------------------------------------------------------------
 *
 * CepBlockModeProc --
 *
 *	This procedure is invoked by the generic IO level to set blocking
 *	and nonblocking mode on a cep based channel.
 *
 * Results:
 *	0 if successful, errno when failed.
 *
 * Side effects:
 *	Sets the device into blocking or nonblocking mode.
 *
 *----------------------------------------------------------------------
 */

static int
CepBlockModeProc (instanceData, mode)
     ClientData instanceData;		/* Cep state. */
     int mode;				/* The mode to set. Can be one of
					 * TCL_MODE_BLOCKING or
					 * TCL_MODE_NONBLOCKING. */
{
  CepState *statePtr = (CepState *) instanceData;
  int setting;

#ifndef USE_FIONBIO
  setting = fcntl(statePtr->fd, F_GETFL);
  if (mode == TCL_MODE_BLOCKING) {
    statePtr->flags &= (~(CEP_ASYNC_CEP));
    setting &= (~(O_NONBLOCK));
  } else {
    statePtr->flags |= CEP_ASYNC_CEP;
    setting |= O_NONBLOCK;
  }
  if (fcntl(statePtr->fd, F_SETFL, setting) < 0) {
    return Tcl_GetErrno();
  }
#else /* USE_FIONBIO */
  if (mode == TCL_MODE_BLOCKING) {
    statePtr->flags &= (~(CEP_ASYNC_CEP));
    setting = 0;
  } else {
    statePtr->flags |= CEP_ASYNC_CEP;
    setting = 1;
  }
  if (ioctl(statePtr->fd, (int) FIONBIO, &setting) == -1) {
    return Tcl_GetErrno();
  }
#endif /* !USE_FIONBIO */

  return 0;
}

/*
 *----------------------------------------------------------------------
 *
 * CepInputProc --
 *
 *	This procedure is invoked by the generic IO level to read input
 *	from a cep based channel.
 *
 * Results:
 *	The number of bytes read is returned or -1 on error. An output
 *	argument contains the POSIX error code on error, or zero if no
 *	error occurred.
 *
 * Side effects:
 *	Reads input from the input device of the channel.
 *
 *----------------------------------------------------------------------
 */

static int
CepInputProc (instanceData, buf, bufSize, errorCodePtr)
     ClientData instanceData;		/* Cep state. */
     char *buf;				/* Where to store data read. */
     int bufSize;			/* How much space is available
					 * in the buffer? */
     int *errorCodePtr;			/* Where to store error code. */
{
  CepState *statePtr = (CepState *) instanceData;
  int bytesRead, state;

  *errorCodePtr = 0;
  state = WaitForConnect(statePtr, errorCodePtr);
  if (state != 0) {
    return -1;
  }

  bytesRead = recvfrom(statePtr->fd, buf, (size_t) bufSize, 0, NULL, 0);

  if (bytesRead > -1) {
    return bytesRead;
  }
  if (Tcl_GetErrno() == ECONNRESET) {
    /*
     * Turn ECONNRESET into a soft EOF condition.
     */

    return 0;
  }
  *errorCodePtr = Tcl_GetErrno();
  return -1;
}

/*
 *----------------------------------------------------------------------
 *
 * CepWatchProc --
 *
 *	Initialize the notifier to watch the fd from this channel.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Sets up the notifier so that a future event on the channel will
 *	be seen by Tcl.
 *
 *----------------------------------------------------------------------
 */

static void
CepWatchProc (instanceData, mask)
     ClientData instanceData;		/* The cep state. */
     int mask;				/* Events of interest; an OR-ed
					 * combination of TCL_READABLE,
					 * TCL_WRITABLE and TCL_EXCEPTION. */
{
  CepState *statePtr = (CepState *) instanceData;

  /*
   * Make sure we don't mess with server ceps since they will never
   * be readable or writable at the Tcl level.  This keeps Tcl scripts
   * from interfering with the -accept behavior.
   */

  if (statePtr->acceptProc == NULL) {
    if (mask) {
      Tcl_CreateFileHandler(statePtr->fd, mask,
			    (Tcl_FileProc *) Tcl_NotifyChannel,
			    (ClientData) statePtr->channel);
    } else {
      Tcl_DeleteFileHandler(statePtr->fd);
    }
  }
}

/*
 *----------------------------------------------------------------------
 *
 * CepGetHandleProc --
 *
 *	Called from Tcl_GetChannelHandle to retrieve OS handles from inside
 *	a cep based channel.
 *
 * Results:
 *	Returns TCL_OK with the fd in handlePtr, or TCL_ERROR if
 *	there is no handle for the specified direction. 
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

static int
CepGetHandleProc (instanceData, direction, handlePtr)
     ClientData instanceData;	/* The cep state. */
     int direction;		/* Not used. */
     ClientData *handlePtr;	/* Where to store the handle.  */
{
  CepState *statePtr = (CepState *) instanceData;

  *handlePtr = (ClientData) statePtr->fd;
  return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * CepOutputProc --
 *
 *	This procedure is invoked by the generic IO level to write output
 *	to a cep based channel.
 *
 * Results:
 *	The number of bytes written is returned. An output argument is
 *	set to a POSIX error code if an error occurred, or zero.
 *
 * Side effects:
 *	Writes output on the output device of the channel.
 *
 *----------------------------------------------------------------------
 */

static int
CepOutputProc (instanceData, buf, toWrite, errorCodePtr)
     ClientData instanceData;		/* Cep state. */
     const char *buf;			/* The data buffer. */
     int toWrite;			/* How many bytes to write? */
     int *errorCodePtr;			/* Where to store error code. */
{
  CepState *statePtr = (CepState *) instanceData;
  int written;
  int state;				/* Of waiting for connection. */

  *errorCodePtr = 0;
  state = WaitForConnect(statePtr, errorCodePtr);
  if (state != 0) {
    return -1;
  }
  written = sendto(statePtr->fd, buf, (size_t) toWrite, 0, NULL, 0);
  if (written > -1) {
    return written;
  }
  *errorCodePtr = Tcl_GetErrno();
  return -1;
}

/*
 *----------------------------------------------------------------------
 *
 * CepCloseProc --
 *
 *	This procedure is invoked by the generic IO level to perform
 *	channel-type-specific cleanup when a cep based channel
 *	is closed.
 *
 * Results:
 *	0 if successful, the value of errno if failed.
 *
 * Side effects:
 *	Closes the cep of the channel.
 *
 *----------------------------------------------------------------------
 */

static int
CepCloseProc (instanceData, interp, flags)
     ClientData instanceData;	/* The cep to close. */
     Tcl_Interp *interp;		/* For error reporting - unused. */
     int flags;

{
  CepState *statePtr = (CepState *) instanceData;
  int errorCode = 0;

  /*
   * Delete a file handler that may be active for this cep if this
   * is a server cep - the file handler was created automatically
   * by Tcl as part of the mechanism to accept new client connections.
   * Channel handlers are already deleted in the generic IO channel
   * closing code that called this function, so we do not have to
   * delete them here.
   */

  if (flags == 0) {
    Tcl_DeleteFileHandler(statePtr->fd);
    if ((statePtr->flags & CEP_SERVER_CEP) && (MASK2DOMAIN(statePtr->flags) == CEP_LOCAL)) {
      struct sockaddr_un sockaddr;
      socklen_t socklen = sizeof(struct sockaddr_un);
      if (getsockname(statePtr->fd, (struct sockaddr *) &sockaddr, &socklen) == 0) {
	unlink(sockaddr.sun_path);
      }
    }
    if (close(statePtr->fd) < 0) {
      errorCode = Tcl_GetErrno();
    }
    ckfree((char *) statePtr);
  }

  return errorCode;
}

/*
 *----------------------------------------------------------------------
 *
 * CepSetOptionProc --
 *
 *      Sets an option on a cep.
 *
 * Results:
 *      A standard Tcl result. Also sets the interp's result on error if
 *      interp is not NULL.
 *
 * Side effects:
 *      May modify an option on a device.
 *      Sets Error message if needed (by calling Tcl_BadChannelOption).
 *
 *----------------------------------------------------------------------
 */

static int              
CepSetOptionProc (instanceData, interp, optionName, value)
     ClientData instanceData;    /* Cep state. */
     Tcl_Interp *interp;         /* For error reporting - can be NULL. */
     const char *optionName;     /* Which option to set? */
     const char *value;          /* New value for option. */
{
  CepState *statePtr = (CepState *) instanceData;
  /*
  struct sockaddr_storage sockaddr;
  struct sockaddr     *sap = (struct sockaddr     *) &sockaddr;
  size_t size;
  */
  size_t len;
  int optionInt;
  socklen_t socklen;
  int cepDomain = MASK2DOMAIN(statePtr->flags);
  int cepType = MASK2TYPE(statePtr->flags);
  int resolve = (statePtr->flags & CEP_RESOLVE_NAMES);

  len = strlen(optionName);


  /*
   * Option -broadcast boolean
   */
  if ((len > 1) && (optionName[1] == 'b') &&
      (strncmp(optionName, "-broadcast", len) == 0)) {
    if (Tcl_GetBoolean(interp, value, &optionInt) != TCL_OK) {
      return TCL_ERROR;
    }
    socklen = sizeof(optionInt);
    if (setsockopt(statePtr->fd, SOL_SOCKET, SO_BROADCAST, (char *) &optionInt, socklen) < 0) {
      return qseterrpx("can't set broadcast: ");
    }
    return TCL_OK;
  }

  /*
   * Option -hops n
   */
  if ((len > 1) && (optionName[1] == 'h') &&
      (strncmp(optionName, "-hops", len) == 0)) {
    int  ret;
    if (Tcl_GetInt(interp, value, &optionInt) != TCL_OK) {
      return TCL_ERROR;
    }
    if ((cepDomain == CEP_INET) && ((optionInt < 0) || (optionInt > 255))) {
      Tcl_SetErrno(EINVAL);
      return qseterrpx("can't set hops: ");
    }
    socklen = sizeof(optionInt);
    if (cepDomain == CEP_INET6) {
      ret = setsockopt(statePtr->fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, (char *) &optionInt, socklen);
    } else {
      ret = setsockopt(statePtr->fd, IPPROTO_IP, IP_TTL, (char *) &optionInt, socklen);
    }
    if (ret < 0) {
      return qseterrpx("can't set hops: ");
    }
    return TCL_OK;
  }

  /*
   * Option -shutdown
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 's') &&
       (strncmp(optionName, "-shutdown", len) == 0))) {
    int mask = 0;
    int how;
    int argc;
    const char **argv;
    if (Tcl_SplitList(interp, value, &argc, &argv) == TCL_ERROR) {
      return TCL_ERROR;
    }
    if (argc == 0) {
      ckfree((char *) argv);
      return TCL_OK;
    }
    if (argc > 2) {
      ckfree((char *) argv);
      return qseterrpx("should be read write {read write} {write read} or {}");
    }
    for (argc--; argc >= 0; argc--) {
      if (strcmp(argv[argc], "read") == 0) {
	mask |= CEP_SHUT_READ;
      } else if (strcmp(argv[argc], "write") == 0) {
	mask |= CEP_SHUT_WRITE;
      } else {
	ckfree((char *) argv);
	return qseterrpx("should be read write {read write} {write read} or {}");
      }
    }
    ckfree((char *) argv);

    if ((mask & CEP_SHUT_READ) && (mask & CEP_SHUT_WRITE)) {
      how = SHUT_RDWR;
    } else if (mask & CEP_SHUT_READ) {
      how = SHUT_RD;
    } else {
      how = SHUT_WR;
    }
    if (shutdown(statePtr->fd, how) != 0) {
      return qseterrpx("can't shutdown: ");
    }
    statePtr->flags |= mask;
    return TCL_OK;
  }

  /*
   * Option -join and -leave
   */
  if ((len > 1) && ((optionName[1] == 'j') || (optionName[1] == 'l')) &&
      ((strncmp(optionName, "-join", len) == 0) || (strncmp(optionName, "-leave", len) == 0))) {
    int op;
    const char *errMsg;
    int ret;
    int argc;
    const char **argv;
    if (Tcl_SplitList(interp, value, &argc, &argv) == TCL_ERROR) {
      return TCL_ERROR;
    }
    if (argc == 0) {
      ckfree((char *) argv);
      return TCL_OK;
    }
    if (strncmp(optionName, "-join", len) == 0) {
      op = 1;
      errMsg = "can't join group: ";
    } else {
      op =  0;
      errMsg = "can't leave group: ";
    }
    if (argc > 2) {
      ckfree((char *) argv);
      return qseterrpx("should be addr, addr interface  or {}");
    }
    if (cepDomain == CEP_INET6) {
      struct ipv6_mreq mreq6;
      if (!NameToAddr(CepDomainToSysDomain(cepDomain), argv[0], &mreq6.ipv6mr_multiaddr, resolve)) {
	ckfree((char *) argv);
	return qseterrpx(errMsg);
      }
      if (argc > 1) {
	if ((mreq6.ipv6mr_interface = if_nametoindex(argv[1])) == 0) {
	  ckfree((char *) argv);
	  return qseterrpx(errMsg);
	}
      } else {
	mreq6.ipv6mr_interface = 0;
      }
      ret = setsockopt(statePtr->fd, IPPROTO_IPV6, (op ? IPV6_JOIN_GROUP : IPV6_LEAVE_GROUP), (char *) &mreq6, sizeof(mreq6));
    } else {
      struct ip_mreq mreq;
      if (!NameToAddr(CepDomainToSysDomain(cepDomain), argv[0], &mreq.imr_multiaddr, resolve)) {
	ckfree((char *) argv);
	return qseterrpx(errMsg);
      }
      if (argc > 1) {
	if (!NameToAddr(CepDomainToSysDomain(cepDomain), argv[1], &mreq.imr_interface, resolve)) {
	  ckfree((char *) argv);
	  return qseterrpx(errMsg);
	}
      } else {
	mreq.imr_interface.s_addr = INADDR_ANY;
      }
      ret = setsockopt(statePtr->fd, IPPROTO_IP, op ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP, (char *) &mreq, sizeof(mreq));
    }
    ckfree((char *) argv);
    if (ret < 0) {
      return qseterrpx(errMsg);
    }
    return TCL_OK;
  }

  /*
   * Option -loop boolean
   */
  if ((len > 1) && (optionName[1] == 'l') &&
      (strncmp(optionName, "-loop", len) == 0)) {
    unsigned char optionUChar;
    if (Tcl_GetBoolean(interp, value, &optionInt) != TCL_OK) {
      return TCL_ERROR;
    }
    optionUChar = optionInt;
    socklen = sizeof(optionUChar);
    if (setsockopt(statePtr->fd,
		   ((cepDomain == CEP_INET6) ? IPPROTO_IPV6 : IPPROTO_IP),
		   ((cepDomain == CEP_INET6) ? IPV6_MULTICAST_LOOP : IP_MULTICAST_LOOP),
		   (char *) &optionUChar, socklen) < 0) {
      return qseterrpx("can't set loop: ");
    }
    return TCL_OK;
  }

  /*
   * Option -mhops n
   */
  if ((len > 1) && (optionName[1] == 'm') &&
      (strncmp(optionName, "-mhops", len) == 0)) {
    unsigned char optionUChar;
    if (Tcl_GetInt(interp, value, &optionInt) != TCL_OK) {
      return TCL_ERROR;
    }
    optionUChar = 4;
    socklen = sizeof(optionUChar);
    if (setsockopt(statePtr->fd,
		   ((cepDomain == CEP_INET6) ? IPPROTO_IPV6 : IPPROTO_IP),
		   ((cepDomain == CEP_INET6) ? IPV6_MULTICAST_HOPS : IP_MULTICAST_TTL),
		   (char *) &optionUChar, socklen) < 0) {
      return qseterrpx("can't set mhops: ");
    }
    return TCL_OK;
  }

  /*
   * Option -maddr
   */
  if ((len > 1) && (optionName[1] == 'm') &&
      (strncmp(optionName, "-maddr", len) == 0)) {
    if (cepDomain == CEP_INET6) {
      struct in6_addr addr;
      socklen = sizeof(addr);
      if (!NameToAddr(CepDomainToSysDomain(cepDomain), value, &addr, resolve)) {
	return qseterrpx("can't set maddr: ");
      }
      if (setsockopt(statePtr->fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, (char *) &addr, socklen) < 0) {
	return qseterrpx("can't set maddr: ");
      }
    } else {
      struct in_addr addr;
      socklen = sizeof(addr);
      if (!NameToAddr(CepDomainToSysDomain(cepDomain), value, &addr, resolve)) {
	return qseterrpx("can't set maddr: ");
      }
      if (setsockopt(statePtr->fd, IPPROTO_IP, IP_MULTICAST_IF, (char *) &addr, socklen) < 0) {
	return qseterrpx("can't set maddr: ");
      }
    }
    return TCL_OK;
  }

  /*
   * Option -resolve boolean
   */
  if ((len > 1) && (optionName[1] == 'r') &&
      (strncmp(optionName, "-resolve", len) == 0)) {
    if (Tcl_GetBoolean(interp, value, &optionInt) != TCL_OK) {
      return TCL_ERROR;
    }
    if (optionInt) {
      statePtr->flags |= CEP_RESOLVE_NAMES;
    } else {
      statePtr->flags &= (~(CEP_RESOLVE_NAMES));
    }
    return TCL_OK;
  }

  /*
   * Option -header
   */
  if ((len > 1) && (optionName[1] == 'h') &&
      (strncmp(optionName, "-header", len) == 0)) {
    if ((cepType == CEP_RAW) && (cepDomain == CEP_INET)) {
      if (Tcl_GetBoolean(interp, value, &optionInt) != TCL_OK) {
	return TCL_ERROR;
      }
      socklen = sizeof(optionInt);
      if (setsockopt(statePtr->fd, IPPROTO_IP, IP_HDRINCL, (char *) &optionInt, socklen) != 0) {
	return qseterrpx("can't set header: ");
      }
    }
    return TCL_OK;
  }

  /*
   * Option -route
   */
  if ((len > 1) && (optionName[1] == 'r') &&
      (strncmp(optionName, "-route", len) == 0)) {
    if (Tcl_GetBoolean(interp, value, &optionInt) != TCL_OK) {
      return TCL_ERROR;
    }
    /* DONTROUTE - so it's backwards */
    optionInt = !optionInt;
    socklen = sizeof(optionInt);
    if (setsockopt(statePtr->fd, SOL_SOCKET, SO_DONTROUTE, (char *) &optionInt, socklen) != 0) {
      return qseterrpx("can't set route: ");
    }
    return TCL_OK;
  }

  /*
   * Option -sendtimeout
   */
  /*
  if ((len > 1) && (optionName[1] == 'r') &&
      (strncmp(optionName, "-sendtimeout", len) == 0)) {
    struct timeval t;
    if (Tcl_GetInt(interp, value, &optionInt) != TCL_OK) {
      return TCL_ERROR;
    }
    t.tv_sec = optionInt;
    t.tv_usec = 0;
    socklen = sizeof(t);
    if (setsockopt(statePtr->fd, SOL_SOCKET, SO_SNDTIMEO, (char *) &t, socklen) != 0) {
      return qseterrpx("can't set sendtimeout: ");
    }
    return TCL_OK;
  }
  */

  /*
   * Option -receivetimeout
   */
  /*
  if ((len > 1) && (optionName[1] == 'r') &&
      (strncmp(optionName, "-receivetimeout", len) == 0)) {
    struct timeval t;
    if (Tcl_GetInt(interp, value, &optionInt) != TCL_OK) {
      return TCL_ERROR;
    }
    t.tv_sec = optionInt;
    t.tv_usec = 0;
    socklen = sizeof(t);
    if (setsockopt(statePtr->fd, SOL_SOCKET, SO_RCVTIMEO, (char *) &t, socklen) != 0) {
      return qseterrpx("can't set receivetimeout: ");
    }
    return TCL_OK;
  }
  */

  /*
   * Option -peername
   */
  if ((len > 1) && (optionName[1] == 'p') &&
      (strncmp(optionName, "-peername", len) == 0)) {
    struct sockaddr_storage sockaddr;
    int argc;
    const char **argv;
    if (Tcl_SplitList(interp, value, &argc, &argv) == TCL_ERROR) {
      return TCL_ERROR;
    }
    if (argc != 2) {
      ckfree((char *) argv);
      return qseterrpx("should be addr port or \"{} -1\" to disassociate");
    }
    if (Tcl_GetInt(interp, argv[1], &optionInt) != TCL_OK) {
      ckfree((char *) argv);
      return TCL_ERROR;
    }
    if ((optionInt == -1) && (strlen(argv[0]) == 0)) {
      (void) memset((void *) &sockaddr, '\0', sizeof(sockaddr));
      if (cepDomain == CEP_INET6) {
	((struct sockaddr_in6 *) &sockaddr)->sin6_family = AF_UNSPEC;
	/*	((struct sockaddr_in6 *) &sockaddr)->sin6_len = GetSocketStructSize(cepDomain);*/
      } else {
	((struct sockaddr_in *) &sockaddr)->sin_family = AF_UNSPEC;
	/*	((struct sockaddr_in *) &sockaddr)->sin_len = GetSocketStructSize(cepDomain);*/
      }
    } else {
      if (CreateCepAddress(cepDomain, &sockaddr, argv[0], optionInt, resolve) != 0) {
	ckfree((char *) argv);
	return qseterrpx("can't set peername: ");
      }
    }
    socklen = GetSocketStructSize(cepDomain);
    if ((connect(statePtr->fd, (struct sockaddr *) &sockaddr, socklen) < 0) && (Tcl_GetErrno() != EAFNOSUPPORT)) {
      ckfree((char *) argv);
      return qseterrpx("can't set peername: ");
    }
    ckfree((char *) argv);
    return TCL_OK;
  }

  return Tcl_BadChannelOption(interp, optionName, "broadcast header hops join leave loop maddr mhops peername resolve route shutdown");
}

/*
 *----------------------------------------------------------------------
 *
 * CepGetOptionProc --
 *
 *	Computes an option value for a CEP socket based channel, or a
 *	list of all options and their values.
 *
 *	Note: This code is based on code contributed by John Haxby.
 *
 * Results:
 *	A standard Tcl result. The value of the specified option or a
 *	list of all options and their values is returned in the
 *	supplied DString. Sets Error message if needed.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

static int
CepGetOptionProc (instanceData, interp, optionName, dsPtr)
     ClientData instanceData;	 /* Socket state. */
     Tcl_Interp *interp;		 /* For error reporting - can be NULL. */
     const char *optionName;	 /* Name of the option to
				  * retrieve the value for, or
				  * NULL to get all options and
				  * their values. */
     Tcl_DString *dsPtr;		 /* Where to store the computed
					  * value; initialized by caller. */
{
  CepState *statePtr = (CepState *) instanceData;
  struct sockaddr_storage sockaddr;
  struct sockaddr     *sap = (struct sockaddr     *) &sockaddr;
  struct sockaddr_in6 *s6p = (struct sockaddr_in6 *) &sockaddr;
  struct sockaddr_in  *s4p = (struct sockaddr_in  *) &sockaddr;
  struct sockaddr_un  *slp = (struct sockaddr_un  *) &sockaddr;
  socklen_t socklen;
  size_t len = 0;
  char optionVal[TCL_INTEGER_SPACE];
  int optionInt;
  char addrBuf[CEP_HOSTNAME_MAX];
  int port;
  int cepDomain = MASK2DOMAIN(statePtr->flags);
  int cepType = MASK2TYPE(statePtr->flags);


  if (optionName != (char *) NULL) {
    len = strlen(optionName);
  }


  /*
   * Option -error
   */
  if ((len > 1) && (optionName[1] == 'e') &&
      (strncmp(optionName, "-error", len) == 0)) {
    int err, ret;
    socklen = sizeof(int);
    ret = getsockopt(statePtr->fd, SOL_SOCKET, SO_ERROR, (char *) &err, &socklen);
    if (ret != 0) {
      err = Tcl_GetErrno();
    }
    if (err != 0) {
      Tcl_DStringAppend(dsPtr, Tcl_ErrnoMsg(err), -1);
    }
    return TCL_OK;
  }

  /*
   * Option -peername
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'p') &&
       (strncmp(optionName, "-peername", len) == 0))) {
    socklen = sizeof(struct sockaddr_storage);
    if (getpeername(statePtr->fd, (struct sockaddr *) &sockaddr, &socklen) == 0) {
      if (len == 0) {
	Tcl_DStringAppendElement(dsPtr, "-peername");
	Tcl_DStringStartSublist(dsPtr);
      }
      if (sap->sa_family == AF_LOCAL) {
	Tcl_DStringAppendElement(dsPtr, slp->sun_path);
	Tcl_DStringAppendElement(dsPtr, slp->sun_path);
	(void) snprintf(optionVal, TCL_INTEGER_SPACE, "%u", socklen);
	Tcl_DStringAppendElement(dsPtr, optionVal);
      } else {
	if (getnameinfo((struct sockaddr *) &sockaddr, socklen,
			addrBuf, sizeof(addrBuf), NULL, 0, NI_NUMERICHOST) != 0) {
	  if (inet_ntop(sap->sa_family,
			(sap->sa_family == AF_INET6) ? (const void *) &s6p->sin6_addr : (const void *) &s4p->sin_addr,
			addrBuf, sizeof(addrBuf)) == NULL) {
	    addrBuf[0] = '?';
	    addrBuf[1] = '\0';
	  }
	}
	Tcl_DStringAppendElement(dsPtr, addrBuf);
	if (getnameinfo((struct sockaddr *) &sockaddr, socklen,
			addrBuf, sizeof(addrBuf), NULL, 0, ((statePtr->flags & CEP_RESOLVE_NAMES) ? 0 : NI_NUMERICHOST)) != 0) {
	  addrBuf[0] = '?';
	  addrBuf[1] = '\0';
	} else if (statePtr->flags & CEP_RESOLVE_NAMES) {
	  Tcl_DString ds;
	  Tcl_ExternalToUtfDString(NULL, addrBuf, -1, &ds);
	  Tcl_DStringAppendElement(dsPtr, Tcl_DStringValue(&ds));
	  Tcl_DStringFree(&ds);
	} else {
	  Tcl_DStringAppendElement(dsPtr, addrBuf);
	}
	if (sap->sa_family == AF_INET6) {
	  port = ntohs((unsigned short) s6p->sin6_port);
	}else {
	  port = ntohs((unsigned short) s4p->sin_port);
	}
	(void) snprintf(optionVal, TCL_INTEGER_SPACE, "%d", port);
	Tcl_DStringAppendElement(dsPtr, optionVal);
      }
      if (len == 0) {
	Tcl_DStringEndSublist(dsPtr);
      } else {
	return TCL_OK;
      }
    } else if ((len == 0) || ((Tcl_GetErrno() == ENOTCONN) && ((cepType == CEP_DGRAM) || (cepType == CEP_RAW)))) {
      /*
       * getpeername failed - but if we were asked for all the options
       * (len==0) or the cep is an unconnected datagram or raw cep,
       * don't flag an error at that point because it could
       * be an fconfigure request on a server socket. (which have
       * no peer). same must be done on win&mac.
       */
      if (len == 0) {
	Tcl_DStringAppendElement(dsPtr, "-peername");
	Tcl_DStringStartSublist(dsPtr);
      }
      Tcl_DStringAppendElement(dsPtr, "");
      Tcl_DStringAppendElement(dsPtr, "");
      Tcl_DStringAppendElement(dsPtr, "-1");
      if (len == 0) {
	Tcl_DStringEndSublist(dsPtr);
      } else {
	return TCL_OK;
      }
    } else {
      return qseterrpx("can't get peername: ");
    }
  }

  /*
   * Option -sockname
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 's') &&
       (strncmp(optionName, "-sockname", len) == 0))) {
    socklen = sizeof(struct sockaddr_storage);
    if (getsockname(statePtr->fd, (struct sockaddr *) &sockaddr, &socklen) == 0) {
      if (len == 0) {
	Tcl_DStringAppendElement(dsPtr, "-sockname");
	Tcl_DStringStartSublist(dsPtr);
      }
      if (sap->sa_family == AF_LOCAL) {
	Tcl_DStringAppendElement(dsPtr, slp->sun_path);
	Tcl_DStringAppendElement(dsPtr, slp->sun_path);
	(void) snprintf(optionVal, TCL_INTEGER_SPACE, "%u", socklen);
	Tcl_DStringAppendElement(dsPtr, optionVal);
      } else {
	if (getnameinfo((struct sockaddr *) &sockaddr, socklen,
			addrBuf, sizeof(addrBuf), NULL, 0, NI_NUMERICHOST) != 0) {
	  if (inet_ntop(sap->sa_family,
			(sap->sa_family == AF_INET6) ? (const void *) &s6p->sin6_addr : (const void *) &s4p->sin_addr,
			addrBuf, sizeof(addrBuf)) == NULL) {
	    addrBuf[0] = '?';
	    addrBuf[1] = '\0';
	  }
	}
	Tcl_DStringAppendElement(dsPtr, addrBuf);
	if (getnameinfo((struct sockaddr *) &sockaddr, socklen,
			addrBuf, sizeof(addrBuf), NULL, 0, ((statePtr->flags & CEP_RESOLVE_NAMES) ? 0 : NI_NUMERICHOST)) != 0) {
	  addrBuf[0] = '?';
	  addrBuf[1] = '\0';
	} else if (statePtr->flags & CEP_RESOLVE_NAMES) {
	  Tcl_DString ds;
	  Tcl_ExternalToUtfDString(NULL, addrBuf, -1, &ds);
	  Tcl_DStringAppendElement(dsPtr, Tcl_DStringValue(&ds));
	  Tcl_DStringFree(&ds);
	} else {
	  Tcl_DStringAppendElement(dsPtr, addrBuf);
	}
	if (sap->sa_family == AF_INET6) {
	  port = ntohs((unsigned short) s6p->sin6_port);
	} else {
	  port = ntohs((unsigned short) s4p->sin_port);
	}
	(void) snprintf(optionVal, TCL_INTEGER_SPACE, "%d", port);
	Tcl_DStringAppendElement(dsPtr, optionVal);
      }
      if (len == 0) {
	Tcl_DStringEndSublist(dsPtr);
      } else {
	return TCL_OK;
      }
    } else {
      return qseterrpx("can't get sockname: ");
    }
  }

  /*
   * Option -hops
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'h') &&
       (strncmp(optionName, "-hops", len) == 0))) {
    optionInt = 0;
    if ((cepDomain == CEP_INET6) || (cepDomain == CEP_INET)) {
      int ret = 0;
      socklen = sizeof(optionInt);
      if (cepDomain == CEP_INET6) {
	ret = getsockopt(statePtr->fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, (char *) &optionInt, &socklen);
      } else {
	ret = getsockopt(statePtr->fd, IPPROTO_IP, IP_TTL, (char *) &optionInt, &socklen);
      }
      if (ret != 0) {
	return qseterrpx("can't get hops: ");
      }
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-hops");
    }
    (void) snprintf(optionVal, TCL_INTEGER_SPACE, "%d", optionInt);
    Tcl_DStringAppendElement(dsPtr, optionVal);
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -broadcast
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'b') &&
       (strncmp(optionName, "-broadcast", len) == 0))) {
    optionInt = -1;
    socklen = sizeof(optionInt);
    if (getsockopt(statePtr->fd, SOL_SOCKET, SO_BROADCAST, (char *) &optionInt, &socklen) != 0) {
      return qseterrpx("can't get broadcast: ");
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-broadcast");
    }
    (void) snprintf(optionVal, TCL_INTEGER_SPACE, "%d", (optionInt > 0));
    Tcl_DStringAppendElement(dsPtr, optionVal);
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -domain
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'd') &&
       (strncmp(optionName, "-domain", len) == 0))) {
    const char *typePtr;
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-domain");
    }
    switch (cepDomain) {
    case CEP_INET6:
      typePtr = "inet6";
      break;
    case CEP_INET:
      typePtr = "inet";
      break;
    case CEP_LOCAL:
      typePtr = "local";
      break;
    default:
      typePtr = "?";
      break;
    }
    Tcl_DStringAppendElement(dsPtr, typePtr);
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -type
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 't') &&
       (strncmp(optionName, "-type", len) == 0))) {
    const char *typePtr;
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-type");
    }
    switch (cepType) {
    case CEP_STREAM:
      typePtr = "stream";
      break;
    case CEP_DGRAM:
      typePtr = "datagram";
      break;
    case CEP_RAW:
      typePtr = "raw";
      break;
    default:
      typePtr = "?";
      break;
    }
    Tcl_DStringAppendElement(dsPtr, typePtr);
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -join
   */
  /*
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'j') &&
       (strncmp(optionName, "-join", len) == 0))) {
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-join");
    }
    Tcl_DStringAppendElement(dsPtr, "");
    if (len > 0) {
      return TCL_OK;
    }
  }
  */

  /*
   * Option -leave
   */
  /*
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'l') &&
       (strncmp(optionName, "-leave", len) == 0))) {
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-leave");
    }
    Tcl_DStringAppendElement(dsPtr, "");
    if (len > 0) {
      return TCL_OK;
    }
  }
  */

  /*
   * Option -shutdown
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 's') &&
       (strncmp(optionName, "-shutdown", len) == 0))) {
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-shutdown");
      if (((statePtr->flags & CEP_SHUT_READ) && (statePtr->flags & CEP_SHUT_WRITE)) ||
	  !((statePtr->flags & CEP_SHUT_READ) || (statePtr->flags & CEP_SHUT_WRITE))) {
	Tcl_DStringStartSublist(dsPtr);
      }
    }
    if (statePtr->flags & CEP_SHUT_READ) {
      Tcl_DStringAppendElement(dsPtr, "read");
    }
    if (statePtr->flags & CEP_SHUT_WRITE) {
      Tcl_DStringAppendElement(dsPtr, "write");
    }
    if (len == 0) {
      if (((statePtr->flags & CEP_SHUT_READ) && (statePtr->flags & CEP_SHUT_WRITE)) ||
	  !((statePtr->flags & CEP_SHUT_READ) || (statePtr->flags & CEP_SHUT_WRITE))) {
	Tcl_DStringEndSublist(dsPtr);
      }
    } else {
      return TCL_OK;
    }
  }

  /*
   * Option -loop
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'l') &&
       (strncmp(optionName, "-loop", len) == 0))) {
    unsigned char optionUChar = 0;
    if ((cepDomain == CEP_INET6) || (cepDomain == CEP_INET)) {
      int ret = 0;
      socklen = sizeof(optionUChar);
      if (cepDomain == CEP_INET6) {
	ret = getsockopt(statePtr->fd, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, (char *) &optionUChar, &socklen);
      } else {
	ret = getsockopt(statePtr->fd, IPPROTO_IP, IP_MULTICAST_LOOP, (char *) &optionUChar, &socklen);
      }
      if (ret != 0) {
	return qseterrpx("can't get loop: ");
      }
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-loop");
    }
    (void) snprintf(optionVal, TCL_INTEGER_SPACE, "%u", optionUChar);
    Tcl_DStringAppendElement(dsPtr, optionVal);
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -mhops
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'm') &&
       (strncmp(optionName, "-mhops", len) == 0))) {
    unsigned char optionUChar = 0;
    if ((cepDomain == CEP_INET6) || (cepDomain == CEP_INET)) {
      socklen = sizeof(optionUChar);
      if (getsockopt(statePtr->fd,
		     ((cepDomain == CEP_INET6) ? IPPROTO_IPV6 : IPPROTO_IP),
		     ((cepDomain == CEP_INET6) ? IPV6_MULTICAST_HOPS : IP_MULTICAST_TTL),
		     (char *) &optionUChar, &socklen) != 0) {
	return qseterrpx("can't get mhops: ");
      }
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-mhops");
    }
    (void) snprintf(optionVal, TCL_INTEGER_SPACE, "%u", optionUChar);
    Tcl_DStringAppendElement(dsPtr, optionVal);
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -maddr
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'm') &&
       (strncmp(optionName, "-maddr", len) == 0))) {
    addrBuf[0] = '*';
    addrBuf[1] = '\0';
    if (cepDomain == CEP_INET6) {
      struct in6_addr addr;
      socklen = sizeof(addr);
      if (getsockopt(statePtr->fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, (char *) &addr, &socklen) != 0) {
	return qseterrpx("can't get maddr: ");
      }
      if (inet_ntop(CepDomainToSysDomain(cepDomain), &addr, addrBuf, sizeof(addrBuf)) == NULL) {
	addrBuf[0] = '?';
	addrBuf[1] = '\0';
      }
    } else if (cepDomain == CEP_INET) {
      struct in_addr addr;
      socklen = sizeof(addr);
      if (getsockopt(statePtr->fd, IPPROTO_IP, IP_MULTICAST_IF, (char *) &addr, &socklen) != 0) {
	return qseterrpx("can't get maddr: ");
      }
      if (inet_ntop(CepDomainToSysDomain(cepDomain), &addr, addrBuf, sizeof(addrBuf)) == NULL) {
	addrBuf[0] = '?';
	addrBuf[1] = '\0';
      }
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-maddr");
    }
    Tcl_DStringAppendElement(dsPtr, addrBuf);
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -protocol
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'p') &&
       (strncmp(optionName, "-protocol", len) == 0))) {
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-protocol");
    }
    if (statePtr->protocol == 0) {
      Tcl_DStringAppendElement(dsPtr, "default");
    } else {
      struct protoent *pe = getprotobynumber(statePtr->protocol);
      if (pe == NULL) {
	return qseterrpx("can't get protocol: ");
      } else {
	Tcl_DString ds;
	Tcl_ExternalToUtfDString(NULL, pe->p_name, -1, &ds);
	Tcl_DStringAppendElement(dsPtr, Tcl_DStringValue(&ds));
	Tcl_DStringFree(&ds);
      }
    }
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -resolve
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'r') &&
       (strncmp(optionName, "-resolve", len) == 0))) {
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-resolve");
    }
    Tcl_DStringAppendElement(dsPtr, (statePtr->flags & CEP_RESOLVE_NAMES) ? "1" : "0");
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -header
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'h') &&
       (strncmp(optionName, "-header", len) == 0))) {
    optionInt = 0;
    if ((cepType == CEP_RAW) && (cepDomain == CEP_INET)) {
      socklen = sizeof(optionInt);
      if (getsockopt(statePtr->fd, IPPROTO_IP, IP_HDRINCL, (char *) &optionInt, &socklen) != 0) {
	return qseterrpx("can't get header: ");
      }
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-header");
    }
    Tcl_DStringAppendElement(dsPtr, (optionInt == 0) ? "0" : "1");
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -route
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'r') &&
       (strncmp(optionName, "-route", len) == 0))) {
    optionInt = 0;
    socklen = sizeof(optionInt);
    if (getsockopt(statePtr->fd, SOL_SOCKET, SO_DONTROUTE, (char *) &optionInt, &socklen) != 0) {
      return qseterrpx("can't get route: ");
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-route");
    }
    /* DONTROUTE - so it's backwards */
    Tcl_DStringAppendElement(dsPtr, (optionInt == 0) ? "1" : "0");
    if (len > 0) {
      return TCL_OK;
    }
  }

  /*
   * Option -sendtimeout
   */
  /*
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 's') &&
       (strncmp(optionName, "-sendtimeout", len) == 0))) {
    struct timeval t;
    socklen = sizeof(t);
    if (getsockopt(statePtr->fd, SOL_SOCKET, SO_SNDTIMEO, (char *) &t, &socklen) != 0) {
      return qseterrpx("can't get sendtimeout: ");
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-sendtimeout");
      Tcl_DStringStartSublist(dsPtr);
    }
    snprintf(optionVal, TCL_INTEGER_SPACE, "%ld", t.tv_sec);
    Tcl_DStringAppendElement(dsPtr, optionVal);
    snprintf(optionVal, TCL_INTEGER_SPACE, "%ld", t.tv_usec);
    Tcl_DStringAppendElement(dsPtr, optionVal);
    if (len == 0) {
      Tcl_DStringEndSublist(dsPtr);
    } else {
      return TCL_OK;
    }
  }
  */

  /*
   * Option -receivetimeout
   */
  /*
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'r') &&
       (strncmp(optionName, "-receivetimeout", len) == 0))) {
    struct timeval t;
    socklen = sizeof(t);
    if (getsockopt(statePtr->fd, SOL_SOCKET, SO_RCVTIMEO, (char *) &t, &socklen) != 0) {
      return qseterrpx("can't get receivetimeout: ");
    }
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-receivetimeout");
      Tcl_DStringStartSublist(dsPtr);
    }
    snprintf(optionVal, TCL_INTEGER_SPACE, "%ld", t.tv_sec);
    Tcl_DStringAppendElement(dsPtr, optionVal);
    snprintf(optionVal, TCL_INTEGER_SPACE, "%ld", t.tv_usec);
    Tcl_DStringAppendElement(dsPtr, optionVal);
    if (len == 0) {
      Tcl_DStringEndSublist(dsPtr);
    } else {
      return TCL_OK;
    }
  }
  */

  /*
   * Option -closeonexec
   */
  /*
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'c') &&
       (strncmp(optionName, "-closeonexec", len) == 0))) {
    optionInt = 0;
    optionInt = fcntl(statePtr->fd, F_GETFD, FD_CLOEXEC);
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-closeonexec");
      Tcl_DStringStartSublist(dsPtr);
    }
    (void) snprintf(optionVal, TCL_INTEGER_SPACE, "%d", optionInt);
    Tcl_DStringAppendElement(dsPtr, optionVal);
    if (len == 0) {
      Tcl_DStringEndSublist(dsPtr);
    } else {
      return TCL_OK;
    }
  }
  */

  /*
   * Option -peereid
   */
  if ((len == 0) ||
      ((len > 1) && (optionName[1] == 'p') &&
       (strncmp(optionName, "-peereid", len) == 0))) {
    uid_t euid;
    gid_t egid; 
    if (len == 0) {
      Tcl_DStringAppendElement(dsPtr, "-peereid");
      Tcl_DStringStartSublist(dsPtr);
    }
    if (getpeereid(statePtr->fd, &euid, &egid) == 0) {
      (void) snprintf(optionVal, TCL_INTEGER_SPACE, "%u", euid);
      Tcl_DStringAppendElement(dsPtr, optionVal);
      (void) snprintf(optionVal, TCL_INTEGER_SPACE, "%u", egid);
      Tcl_DStringAppendElement(dsPtr, optionVal);
    } else {
      Tcl_DStringAppendElement(dsPtr, "-1");
      Tcl_DStringAppendElement(dsPtr, "-1");
    }
    if (len == 0) {
      Tcl_DStringEndSublist(dsPtr);
    } else {
      return TCL_OK;
    }
  }

  if (len > 0) {
    return Tcl_BadChannelOption(interp, optionName, "broadcast domain header hops maddr mhops resolve loop peereid peername protocol resolve route shutdown sockname type");
  }

  return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * CreateCepAddress --
 *
 *	This function initializes a sockaddr structure for a host and port.
 *
 * Results:
 *	0 on success, -1 on error

 *
 * Side effects:
 *	Fills in the *sockaddrPtr structure.
 *
 *----------------------------------------------------------------------
 */

static int
CreateCepAddress (cepDomain, sockaddrPtr, host, port, resolve)
     int cepDomain;
     struct sockaddr_storage *sockaddrPtr;	/* Socket address */
     const char *host;			/* Host.  NULL implies INADDR_ANY */
     int port;				/* Port number */
     int resolve;
{
  /*  struct hostent *hostent;	*/	/* Host database entry */
  struct sockaddr     *sap = (struct sockaddr     *) sockaddrPtr;
  struct sockaddr_in6 *s6p = (struct sockaddr_in6 *) sockaddrPtr;
  struct sockaddr_in  *s4p = (struct sockaddr_in  *) sockaddrPtr;
  struct sockaddr_un  *slp = (struct sockaddr_un  *) sockaddrPtr;
  struct in6_addr addr6;
  struct in_addr  addr4;
  void *addrPtr;


  (void) memset((void *) sockaddrPtr, '\0', sizeof(struct sockaddr_storage));

  port = htons((unsigned short) (port & 0xFFFF));
  sap->sa_family = CepDomainToSysDomain(cepDomain);

  if (cepDomain == CEP_LOCAL) {
    if (host != NULL) {
      Tcl_DString ds;
      const char *native;
      native = Tcl_UtfToExternalDString(NULL, host, -1, &ds);
      strlcpy(slp->sun_path, native, sizeof(slp->sun_path));
      Tcl_DStringFree(&ds);
      return 0;
    }
    return -1;
  }

  if (cepDomain == CEP_INET6) {
    /*    sap->sa_len = sizeof(struct sockaddr_in6);*/
    s6p->sin6_port = port;
    addrPtr = &addr6;
    (void) memset(addrPtr, '\0', sizeof(addr6));
  } else {
    /*    sap->sa_len = sizeof(struct sockaddr_in);*/
    s4p->sin_port = port;
    addrPtr = &addr4;
    (void) memset(addrPtr, '\0', sizeof(addr4));
  }

  if (host == NULL) {
    if (cepDomain == CEP_INET6) {    
      addr6 = in6addr_any;
    } else {
      addr4.s_addr = INADDR_ANY;
    }
  } else {
    if (!NameToAddr(sap->sa_family, host, addrPtr, resolve)) {
      return -1;
    }
  }

  /*
   * NOTE: On 64 bit machines the assignment below is rumored to not
   * do the right thing. Please report errors related to this if you
   * observe incorrect behavior on 64 bit machines such as DEC Alphas.
   * Should we modify this code to do an explicit memcpy?
   */

  if (cepDomain == CEP_INET6) {
    s6p->sin6_addr = addr6;
  } else {
    s4p->sin_addr = addr4;
  }

  return 0;	/* Success. */
}

/*
 *----------------------------------------------------------------------
 *
 * CreateCep --
 *
 *	This function opens a new cep in client or server mode
 *	and initializes the CepState structure.
 *
 * Results:
 *	Returns a new CepState, or NULL with an error in the interp's
 *	result, if interp is not NULL.
 *
 * Side effects:
 *	Opens a cep.
 *
 *----------------------------------------------------------------------
 */

static CepState *
CreateCep (interp, cepDomain, cepType, protocol, host, port, server, myaddr, myport, async, resolve, reuseaddr, reuseport)
     Tcl_Interp *interp;		/* For error reporting; can be NULL. */
     int cepDomain;
     int cepType;
     const char *protocol;
     const char *host;		/* Name of host on which to open port.
				 * NULL implies INADDR_ANY */
     int port;                           /* Port number to open. */
     int server;			/* 1 if cep should be a server cep,
					 * else 0 for a client cep. */
     const char *myaddr;                 /* Client-side address */
     int myport;                         /* Client-side port */
     int async;			/* If nonzero and creating a client cep,
				 * attempt to do an async connect. Otherwise
				 * do a synchronous connect or bind. */
     int resolve;
     int reuseaddr;
     int reuseport;
{
  struct sockaddr_storage sockaddr;
  struct sockaddr_storage mysockaddr;
  socklen_t size;
  CepState *statePtr;
  int sock;
  int asyncConnect;
  int status;
  int curState;
  int origState;
  int domain;
  int type;
  int proto = 0;

  sock = -1;
  origState = 0;

  domain = CepDomainToSysDomain(cepDomain);
  type = CepTypeToSysType(cepType);
  size = GetSocketStructSize(cepDomain);

  if (!((host == NULL) && (port == -1))) {
    if (CreateCepAddress(cepDomain, &sockaddr, host, port, resolve) != 0) {
      goto addressError;
    }
  }

  if (cepDomain != CEP_LOCAL && (myaddr != NULL || myport != 0)) {
    if (CreateCepAddress(cepDomain, &mysockaddr, myaddr, myport, resolve) != 0) {
      goto addressError;
    }
  }

  if ((protocol != NULL) && (strlen(protocol) > 0) && (strcmp(protocol, "default") != 0)) {
    if (Tcl_GetInt(interp, protocol, &proto) != TCL_OK) {
      Tcl_DString ds;
      const char *native;
      struct protoent *pe;

      native = Tcl_UtfToExternalDString(NULL, protocol, -1, &ds);
      pe = getprotobyname(native);
      Tcl_DStringFree(&ds);
      if (pe == NULL) {
	goto addressError;
      } 
      proto = pe->p_proto;
    }
  }

  if ((sock = socket(domain, type, proto)) == -1) {
    goto addressError;
  }

  /*
   * Set the close-on-exec flag so that the cep will not get
   * inherited by child processes.
   */

  (void) fcntl(sock, F_SETFD, FD_CLOEXEC);

  /*
   * Set kernel space buffering
   */
  if (cepType == CEP_STREAM) {
    _TCL_SockMinimumBuffers(sock, SOCKET_BUFSIZE);
  }

  asyncConnect = 0;
  status = 0;
  if (server) {
    /*
     * Set up to reuse server addresses automatically and bind to the
     * specified port.
     */

    if (cepDomain == CEP_INET || cepDomain == CEP_INET6) {
      if (reuseaddr) {
	status = 1;
	(void) setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char *) &status, sizeof(status));
      }
      if (reuseport) {
	status = 1;
	(void) setsockopt(sock, SOL_SOCKET, CEP_REUSEPORT, (char *) &status, sizeof(status));
      }
    }

    status = bind(sock, (struct sockaddr *) &sockaddr, size);

    if (cepType == CEP_STREAM) {
      if (status != -1) {
	status = listen(sock, SOMAXCONN);
      }
    }
  } else {
    if (cepDomain == CEP_INET || cepDomain == CEP_INET6) {
      if (myaddr != NULL || myport != 0) {
	if (reuseaddr) {
	  status = 1;
	  (void) setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char *) &status, sizeof(status));
	}
	if (reuseport) {
	  status = 1;
	  (void) setsockopt(sock, SOL_SOCKET, CEP_REUSEPORT, (char *) &status, sizeof(status));
	}
	
	status = bind(sock, (struct sockaddr *) &mysockaddr, size);
	
	if (status < 0) {
	  goto bindError;
	}
      }
    }

    if ((host == NULL) && (port == -1)) {
      status = 0;
    } else {
      /*
       * Attempt to connect. The connect may fail at present with an
       * EINPROGRESS but at a later time it will complete. The caller
       * will set up a file handler on the cep if she is interested in
       * being informed when the connect completes.
       */

      if (async) {
#ifndef USE_FIONBIO
	origState = fcntl(sock, F_GETFL);
	curState = origState | O_NONBLOCK;
	status = fcntl(sock, F_SETFL, curState);
#else /* USE_FIONBIO */
	curState = 1;
	status = ioctl(sock, FIONBIO, &curState);
#endif /* !USE_FIONBIO */
      } else {
	status = 0;
      }
      if (status >= 0) {
	status = connect(sock, (struct sockaddr *) &sockaddr, size);
	if (status < 0) {
	  if (Tcl_GetErrno() == EINPROGRESS) {
	    asyncConnect = 1;
	    status = 0;
	  }
	} else {
	  /*
	   * Here we are if the connect succeeds. In case of an
	   * asynchronous connect we have to reset the channel to
	   * blocking mode.  This appears to happen not very often,
	   * but e.g. on a HP 9000/800 under HP-UX B.11.00 we enter
	   * this stage. [Bug: 4388]
	   */
	  if (async) {
#ifndef USE_FIONBIO
	    origState = fcntl(sock, F_GETFL);
	    curState = origState & ~(O_NONBLOCK);
	    status = fcntl(sock, F_SETFL, curState);
#else /* USE_FIONBIO */
	    curState = 0;
	    status = ioctl(sock, FIONBIO, &curState);
#endif /* !USE_FIONBIO */
	  }
	}
      }
    }
  }

 bindError:
  if (status < 0) {
    qseterrpx("couldn't open cep: ");
    if (sock != -1) {
      close(sock);
    }
    return NULL;
  }

  /*
   * Allocate a new CepState for this cep.
   */

  statePtr = (CepState *) ckalloc((unsigned) sizeof(CepState));
  statePtr->fd = sock;
  statePtr->flags = 0;
  statePtr->flags |= DOMAIN2MASK(cepDomain);
  statePtr->flags |= TYPE2MASK(cepType);
  if (asyncConnect) {
    statePtr->flags |= CEP_ASYNC_CONNECT;
  }
  if (server) {
    statePtr->flags |= CEP_SERVER_CEP;
  }
  if (resolve) {
    statePtr->flags |= CEP_RESOLVE_NAMES;
  }
  statePtr->protocol = proto;

  return statePtr;

 addressError:
  if (sock != -1) {
    close(sock);
  }
  qseterrpx("couldn't open cep: ");

  return NULL;
}

/*
 *----------------------------------------------------------------------
 *
 * MakeCepClientChannel --
 *
 *	Creates a Tcl_Channel from an existing client cep.
 *
 * Results:
 *	The Tcl_Channel wrapped around the preexisting cep.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

Tcl_Channel
MakeCepClientChannel (sock, cepDomain, cepType, protocol, resolve)
     ClientData sock;		/* The cep to wrap up into a channel. */
     int cepDomain;
     int cepType;
     int protocol;
     int resolve;
{
  return MakeCepClientChannelMode(sock, cepDomain, cepType, protocol, resolve, (TCL_READABLE | TCL_WRITABLE));
}

/*
 *----------------------------------------------------------------------
 *
 * MakeCepClientChannelMode --
 *
 *	Creates a Tcl_Channel from an existing client cep
 *	with given mode.
 *
 * Results:
 *	The Tcl_Channel wrapped around the preexisting cep.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

static Tcl_Channel
MakeCepClientChannelMode (sock, cepDomain, cepType, protocol, resolve, mode)
     ClientData sock;		/* The socket to wrap up into a channel. */
     int cepDomain;
     int cepType;
     int protocol;
     int resolve;
     int mode;			/* ORed combination of TCL_READABLE and
				 * TCL_WRITABLE to indicate file mode. */
{
  CepState *statePtr;
  char channelName[CEP_CHANNELNAME_MAX];
  struct sockaddr_storage sockaddr;
  socklen_t size;

  size = sizeof(struct sockaddr);
  if (getsockname((int) sock, (struct sockaddr *) &sockaddr, &size) != 0) {
    return NULL;
  }

  if (cepDomain == -1) {
    cepDomain = SysDomainToCepDomain(sockaddr.ss_family);
  }

  if (cepType == -1) {
    int optionInt = -1;
    size = sizeof(optionInt);
    if (getsockopt((int) sock, SOL_SOCKET, SO_TYPE, (char *) &optionInt, &size) != 0) {
      return NULL;
    }
    cepType = SysTypeToCepType(optionInt);
  }

  statePtr = (CepState *) ckalloc((unsigned) sizeof(CepState));
  statePtr->fd = (int) sock;
  statePtr->flags = 0;
  statePtr->flags |= DOMAIN2MASK(cepDomain);
  statePtr->flags |= TYPE2MASK(cepType);
  if (resolve) {
    statePtr->flags |= CEP_RESOLVE_NAMES;
  }
  statePtr->protocol = protocol;
  statePtr->acceptProc = NULL;
  statePtr->acceptProcData = (ClientData) NULL;

  (void) snprintf(channelName, CEP_CHANNELNAME_MAX, "cep%d", statePtr->fd);

  statePtr->channel = Tcl_CreateChannel(&cepChannelType, channelName, (ClientData) statePtr, mode);

  if (Tcl_SetChannelOption((Tcl_Interp *) NULL, statePtr->channel, "-translation", "auto crlf") == TCL_ERROR) {
    Tcl_Close((Tcl_Interp *) NULL, statePtr->channel);
    return NULL;
  }
  return statePtr->channel;
}

/*
 *----------------------------------------------------------------------
 *
 * Cep_OpenLocalPair --
 *
 *
 * Results:
 *
 * Side effects:
 *	End of the universe.
 *
 *----------------------------------------------------------------------
 */

int
Cep_OpenLocalPair (interp, cepDomain, cepType, protocol, chan1, chan2)
     Tcl_Interp * interp;
     int cepType;
     int cepDomain;
     const char *protocol;
     Tcl_Channel *chan1;
     Tcl_Channel *chan2;
{
  int result;
  int sv[2];
  int proto = 0;


  if ((protocol != NULL) && (strlen(protocol) > 0) && (strcmp(protocol, "default") != 0)) {
    if (Tcl_GetInt(interp, protocol, &proto) != TCL_OK) {
      Tcl_DString ds;
      const char *native;
      struct protoent *pe;

      native = Tcl_UtfToExternalDString(NULL, protocol, -1, &ds);
      pe = getprotobyname(native);
      Tcl_DStringFree(&ds);
      if (pe == NULL) {
	qseterrpx("couldn't create localpair: ");
	return -1;
      } 
      proto = pe->p_proto;
    }
  }

  result = socketpair(CepDomainToSysDomain(cepDomain), CepTypeToSysType(cepType), proto, sv);

  if (result != 0) {
    qseterrpx("couldn't create localpair: ");
    return -1;
  }

  (void) fcntl(sv[0], F_SETFD, FD_CLOEXEC);
  (void) fcntl(sv[1], F_SETFD, FD_CLOEXEC);

  *chan1 = MakeCepClientChannel((ClientData) sv[0], cepDomain, cepType, proto, 0);
  if (*chan1 == NULL) {
    close(sv[0]);
    close(sv[1]);
    return -1;
  }

  *chan2 = MakeCepClientChannel((ClientData) sv[1], cepDomain, cepType, proto, 0);
  if (*chan1 == NULL) {
    Tcl_Close(interp, *chan1);
    close(sv[0]);
    close(sv[1]);
    return -1;
  }

  return 0;
}

/*
 *----------------------------------------------------------------------
 *
 * Cep_OpenClient --
 *
 *	Opens a client cep and creates a channel around it.
 *
 * Results:
 *	The channel or NULL if failed.	An error message is returned
 *	in the interpreter on failure.
 *
 * Side effects:
 *	Opens a client cep and creates a new channel.
 *
 *----------------------------------------------------------------------
 */

Tcl_Channel
Cep_OpenClient (interp, cepDomain, cepType, protocol, host, port, myaddr, myport, async, resolve, reuseaddr, reuseport)
     Tcl_Interp *interp;			/* For error reporting; can be NULL. */
     int cepDomain;
     int cepType;
     const char *protocol;
     const char *host;			/*  */
     int port;                           /* Port number to open. */
     const char *myaddr;                 /* Client-side address */
     int myport;                         /* Client-side port */
     int async;				/* If nonzero, attempt to do an
					 * asynchronous connect. Otherwise
					 * we do a blocking connect. */
     int resolve;
     int reuseaddr;
     int reuseport;
{
  CepState *statePtr;
  char channelName[CEP_CHANNELNAME_MAX];

  /*
   * Create a new client cep and wrap it in a channel.
   */

  statePtr = CreateCep(interp, cepDomain, cepType, protocol, host, port, 0, myaddr, myport, async, resolve, reuseaddr, reuseport);
  if (statePtr == NULL) {
    return NULL;
  }

  statePtr->acceptProc = NULL;
  statePtr->acceptProcData = (ClientData) NULL;

  (void) snprintf(channelName, CEP_CHANNELNAME_MAX, "cep%d", statePtr->fd);

  statePtr->channel = Tcl_CreateChannel(&cepChannelType, channelName, (ClientData) statePtr, (TCL_READABLE | TCL_WRITABLE));

  if (Tcl_SetChannelOption(interp, statePtr->channel, "-translation", "auto crlf") == TCL_ERROR) {
    Tcl_Close((Tcl_Interp *) NULL, statePtr->channel);
    return NULL;
  }
  return statePtr->channel;
}

/*
 *----------------------------------------------------------------------
 *
 * Ceo_OpenServer --
 *
 *	Opens a server cep and creates a channel around it.
 *
 * Results:
 *	The channel or NULL if failed. If an error occurred, an
 *	error message is left in the interp's result if interp is
 *	not NULL.
 *
 * Side effects:
 *	Opens a server socket cep and creates a new channel.
 *
 *----------------------------------------------------------------------
 */

Tcl_Channel
Cep_OpenServer (interp, receiver, cepDomain, cepType, protocol, myAddr, port, resolve, reuseaddr, reuseport, acceptProc, acceptProcData)
     Tcl_Interp *interp;			/* For error reporting - may be
						 * NULL. ? */
     int receiver;
     int cepDomain;
     int cepType;
     const char *protocol;
     const char *myAddr;			/* */
     int port;
     int resolve;
     int reuseaddr;
     int reuseport;
     CepAcceptProc *acceptProc;	/* Callback for accepting connections
				 * from new clients. */
     ClientData acceptProcData;		/* Data for the callback. */
{
  CepState *statePtr;
  char channelName[CEP_CHANNELNAME_MAX];

  /*
   * Create a new server cep and wrap it in a channel.
   */
  statePtr = CreateCep(interp, cepDomain, cepType, protocol, myAddr, port, 1, NULL, 0, 0, resolve, reuseaddr, reuseport);
  if (statePtr == NULL) {
    return NULL;
  }

  statePtr->acceptProc = acceptProc;
  statePtr->acceptProcData = acceptProcData;

  /*
   * Set up the callback mechanism for accepting connections
   * from new clients.
   */

  if (receiver) {
    Tcl_CreateFileHandler(statePtr->fd, TCL_READABLE, CepReceiverListen, (ClientData) statePtr);
  } else {
    Tcl_CreateFileHandler(statePtr->fd, TCL_READABLE, CepAccept, (ClientData) statePtr);
  }

  (void) snprintf(channelName, CEP_CHANNELNAME_MAX, "cep%d", statePtr->fd);

  statePtr->channel = Tcl_CreateChannel(&cepChannelType, channelName, (ClientData) statePtr, 0);

  return statePtr->channel;
}

/*
 *----------------------------------------------------------------------
 *
 * CepAccept --
 *	Accept a CEP socket connection.	 This is called by the event loop.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Creates a new connection socket. Calls the registered callback
 *	for the connection acceptance mechanism.
 *
 *----------------------------------------------------------------------
 */

static void
CepAccept (data, mask)
     ClientData data;			/* Callback token. */
     int mask;				/* Not used. */
{
  CepState *statePtr = (CepState *) data;		/* Client data of server socket. */
  CepState *newCepState;		/* State for new socket. */
  struct sockaddr_storage sockaddr;		/* The remote address */
  socklen_t size = sizeof(struct sockaddr_storage);
  int newsock;			/* The new client socket */
  char channelName[CEP_CHANNELNAME_MAX];
  int cepDomain;


  newsock = accept(statePtr->fd, (struct sockaddr *) &sockaddr, &size);
  if (newsock < 0) {
    return;
  }

  /*
   * Set close-on-exec flag to prevent the newly accepted socket from
   * being inherited by child processes.
   */

  (void) fcntl(newsock, F_SETFD, FD_CLOEXEC);

  newCepState = (CepState *) ckalloc((unsigned) sizeof(CepState));

  cepDomain = MASK2DOMAIN(statePtr->flags);

  newCepState->flags = 0;
  newCepState->flags |= DOMAIN2MASK(cepDomain);
  newCepState->flags |= TYPE2MASK(MASK2TYPE(statePtr->flags));
  if (statePtr->flags & CEP_RESOLVE_NAMES) {
    newCepState->flags |= CEP_RESOLVE_NAMES;
  }
  newCepState->protocol = statePtr->protocol;
  newCepState->fd = newsock;
  newCepState->acceptProc = NULL;
  newCepState->acceptProcData = NULL;

  (void) snprintf(channelName, CEP_CHANNELNAME_MAX, "cep%d", newsock);

  newCepState->channel = Tcl_CreateChannel(&cepChannelType, channelName,
					   (ClientData) newCepState, (TCL_READABLE | TCL_WRITABLE));

  Tcl_SetChannelOption(NULL, newCepState->channel, "-translation", "auto crlf");

  if (statePtr->acceptProc != NULL) {
    struct sockaddr_in6 *s6p = (struct sockaddr_in6 *) &sockaddr;
    struct sockaddr_in  *s4p = (struct sockaddr_in  *) &sockaddr;
    struct sockaddr_un  *slp = (struct sockaddr_un  *) &sockaddr;
    char addrBuf[CEP_HOSTNAME_MAX];
    int port = -1;
    uid_t euid = (unsigned) -1;
    gid_t egid = (unsigned) -1; 
    char *addrPtr = addrBuf;
    Tcl_DString ds;

    Tcl_DStringInit(&ds);

    if (cepDomain == CEP_LOCAL) {
      /* accept() doesn't fill in sun_path? */
      if (getsockname(newsock, (struct sockaddr *) &sockaddr, &size) != 0) {
	addrBuf[0] = '!';
	addrBuf[1] = '\0';
      } else {
	Tcl_ExternalToUtfDString(NULL, slp->sun_path, -1, &ds);
	addrPtr = Tcl_DStringValue(&ds);
      }
      if (getpeereid(newsock, &euid, &egid) != 0) {
	/* ? */
      }
    } else {
      if (getnameinfo((struct sockaddr *) &sockaddr, size, addrBuf, sizeof(addrBuf), NULL, 0, NI_NUMERICHOST) != 0) {
	addrBuf[0] = '?';
	addrBuf[1] = '\0';
      }
      if (cepDomain == CEP_INET6) {
	port = ntohs((unsigned short) s6p->sin6_port);
      } else {
	port = ntohs((unsigned short) s4p->sin_port);
      }
    }

    (*statePtr->acceptProc)(statePtr->acceptProcData,
			    newCepState->channel, (const char *) addrPtr, port,
			    cepDomain, euid, egid, (const unsigned char *) NULL);
    Tcl_DStringFree(&ds);
  }
}

/*
 *----------------------------------------------------------------------
 *
 * CepReceiverListen --
 *
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *
 *----------------------------------------------------------------------
 */

static void
CepReceiverListen (data, mask)
     ClientData data;			/* Callback token. */
     int mask;				/* Not used. */
{
  CepState *statePtr = (CepState *) data;		/* Client data of server socket. */
  struct sockaddr_storage sockaddr;		/* The remote address */
  socklen_t size = sizeof(struct sockaddr_storage);
  int bytesAvail;
  ssize_t bytesRead;
  unsigned char *buf;


  /* This is actually the number of bytes + header */
  if (ioctl(statePtr->fd, FIONREAD, &bytesAvail) == -1) {
    Tcl_Panic("CepReceiverListen ioctl FIONREAD error (%s)", Tcl_ErrnoMsg(Tcl_GetErrno()));
  }
  buf = (unsigned char *) ckalloc((unsigned) bytesAvail);
  /* memset(buf, 0, (size_t) bytesAvail); */
  bytesRead = recvfrom(statePtr->fd, buf, (size_t) bytesAvail, 0, (struct sockaddr *) &sockaddr, &size);

  if (statePtr->acceptProc != NULL) {
    struct sockaddr     *sap = (struct sockaddr     *) &sockaddr;
    struct sockaddr_in6 *s6p = (struct sockaddr_in6 *) &sockaddr;
    struct sockaddr_in  *s4p = (struct sockaddr_in  *) &sockaddr;
    struct sockaddr_un  *slp = (struct sockaddr_un  *) &sockaddr;
    char addrBuf[CEP_HOSTNAME_MAX];
    char *addrPtr = addrBuf;
    int cepDomain;
    int port = -1;

    cepDomain = SysDomainToCepDomain(sap->sa_family);
    if (cepDomain == CEP_LOCAL) {
      addrPtr = slp->sun_path;
    } else {
      (void) memset(addrBuf, 0, sizeof(addrBuf));
      if (getnameinfo((struct sockaddr *) &sockaddr, size, addrBuf, sizeof(addrBuf), NULL, 0, NI_NUMERICHOST) != 0) {
	addrBuf[0] = '?';
	addrBuf[1] = '\0';
      }
      if (cepDomain == CEP_INET6) {
	port = ntohs((unsigned short) s6p->sin6_port);
      } else {
	port = ntohs((unsigned short) s4p->sin_port);
      }
    }

    (*statePtr->acceptProc)(statePtr->acceptProcData,
			    statePtr->channel, (const char *) addrPtr, port,
			    cepDomain, (unsigned) -1, (unsigned) bytesRead, (const unsigned char *) buf);
  }
  ckfree((char *) buf);
}

/*
 *----------------------------------------------------------------------
 *
 * Cep_Sendto --
 *
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *
 *----------------------------------------------------------------------
 */

int
Cep_Sendto (Tcl_Channel chan, const char *host, int port, const unsigned char *data, int dataLen)
{
  struct sockaddr_storage sockaddr;
  int cepDomain;
  int written;

  CepState *statePtr = (CepState *)  Tcl_GetChannelInstanceData(chan);

  cepDomain = MASK2DOMAIN(statePtr->flags);

  if (CreateCepAddress(cepDomain, &sockaddr, host, port, (int) (statePtr->flags & (CEP_RESOLVE_NAMES))) != 0) {
    return -1;
  }

  written = sendto(statePtr->fd, data, (size_t) dataLen, 0, (struct sockaddr *) &sockaddr, GetSocketStructSize(cepDomain));

  return written;
}


/*
 *----------------------------------------------------------------------
 *
 * CepDomainToSysDomain --
 *
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *
 *----------------------------------------------------------------------
 */

static int
CepDomainToSysDomain (int cepDomain)
{
  switch (cepDomain) {
  case CEP_LOCAL:
    return AF_LOCAL;
  case CEP_INET:
    return AF_INET;
  case CEP_INET6:
    return AF_INET6;
  default:
    return -1;
  }
}

/*
 *----------------------------------------------------------------------
 *
 * SysDomainToCepDomain --
 *
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *
 *----------------------------------------------------------------------
 */

static int
SysDomainToCepDomain (int sysDomain)
{
  switch (sysDomain) {
  case AF_LOCAL:
    return CEP_LOCAL;
  case AF_INET:
    return CEP_INET;
  case AF_INET6:
    return CEP_INET6;
  default:
    return -1;
  }
}

/*
 *----------------------------------------------------------------------
 *
 * CepTypeToSysType --
 *
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *
 *----------------------------------------------------------------------
 */

static int
CepTypeToSysType (int cepType)
{
  switch (cepType) {
  case CEP_STREAM:
    return SOCK_STREAM;
  case CEP_DGRAM:
    return SOCK_DGRAM;
  case CEP_RAW:
    return SOCK_RAW;
  default:
    return -1;
  }
}

/*
 *----------------------------------------------------------------------
 *
 * SysTypeToCepType --
 *
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *
 *----------------------------------------------------------------------
 */

static int
SysTypeToCepType (int sysType)
{
  switch (sysType) {
  case SOCK_STREAM:
    return CEP_STREAM;
  case SOCK_DGRAM:
    return CEP_DGRAM;
  case SOCK_RAW:
    return CEP_RAW;
  default:
    return -1;
  }
}

/*
 *----------------------------------------------------------------------
 *
 * GetSocketStructSize --
 *
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *
 *----------------------------------------------------------------------
 */

static socklen_t
GetSocketStructSize (cepDomain)
     int cepDomain;
{
  switch (cepDomain) {
  case CEP_LOCAL:
    return sizeof(struct sockaddr_un);
  case CEP_INET:
    return sizeof(struct sockaddr_in);
  case CEP_INET6:
    return sizeof(struct sockaddr_in6);
  default:
    return 0;
  }
}

/*
 *----------------------------------------------------------------------
 *
 * nameToAddr --
 *
 *
 * Results:
 *
 *
 * Side effects:
 *
 *
 *
 *----------------------------------------------------------------------
 */

static int
NameToAddr (int family, const char *host, void *addrPtr, int resolve) {
  struct hostent *hostent;		/* Host database entry */
    Tcl_DString ds;
    const char *native;

    native = Tcl_UtfToExternalDString(NULL, host, -1, &ds);

    if (inet_pton(family, native, addrPtr) != 1) {
      if (resolve) {
	hostent = gethostbyname2(native, family);
      } else {
	hostent = NULL;
      }
      if (hostent != NULL) {
	memcpy(addrPtr, (void *) hostent->h_addr_list[0], (size_t) hostent->h_length);
      } else {
#ifdef	EHOSTUNREACH
	Tcl_SetErrno(EHOSTUNREACH);
#else /* !EHOSTUNREACH */
#ifdef ENXIO
	Tcl_SetErrno(ENXIO);
#endif /* ENXIO */
#endif /* EHOSTUNREACH */
	if (native != NULL) {
	  Tcl_DStringFree(&ds);
	}
	return 0;	/* error */
      }
    }
    if (native != NULL) {
      Tcl_DStringFree(&ds);
    }
    return 1;
}

/*
 *----------------------------------------------------------------------
 *
 * Cep_SetInterpResultError --
 *
 *
 *
 *
 * Results:
 *	TCL_ERROR
 *
 * Side effects:
 *
 *
 *----------------------------------------------------------------------
 */

int
Cep_SetInterpResultError TCL_VARARGS_DEF(Tcl_Interp *,arg1)
{
    Tcl_Interp *interp;
    va_list argList;
    Tcl_Obj *result;

    interp = TCL_VARARGS_START(Tcl_Interp *,arg1,argList);

    if (interp == NULL) {
      return TCL_ERROR;
    }

    result = Tcl_NewObj();

    Tcl_AppendStringsToObjVA(result, argList);

    va_end(argList);

    Tcl_SetObjResult(interp, result);

    return TCL_ERROR;
}

/*
 *----------------------------------------------------------------------
 *
 * Cep_SetInterpResultErrorPosix --
 *
 *
 *
 *
 * Results:
 *	TCL_ERROR
 *
 * Side effects:
 *
 *
 *----------------------------------------------------------------------
 */

int
Cep_SetInterpResultErrorPosix TCL_VARARGS_DEF(Tcl_Interp *,arg1)
{
    Tcl_Interp *interp;
    va_list argList;
    Tcl_Obj *result;

    interp = TCL_VARARGS_START(Tcl_Interp *,arg1,argList);

    if (interp == NULL) {
      return TCL_ERROR;
    }

    result = Tcl_NewObj();

    Tcl_AppendStringsToObjVA(result, argList);

    va_end(argList);

    Tcl_AppendStringsToObj(result, Tcl_PosixError(interp), (char *) NULL);

    Tcl_SetObjResult(interp, result);

    return TCL_ERROR;
}


/* EOF */
