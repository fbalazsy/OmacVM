#pragma once
typedef enum { AUTH=1,PREPARE,PUBLISH,REAUTH,SPAWN,READY,WAIT,CANCEL,TERM,KILL,PAUSE,CLEAN,QUARANTINE,EXEC_ACK } Stage;
typedef enum { CHILD_RUNNING, CHILD_REAPED, CHILD_ERROR } ChildKind;
typedef struct { ChildKind kind; int status, error; } ChildResult;
/* A signal never proves reaping. CHILD_ERROR retains ownership. */
typedef struct { void *ctx; int (*step)(void *,Stage); double (*clock)(void *); ChildResult (*wait)(void *); } Ops;
/* 125 = termination unconfirmed, quarantined; never a release confirmation. */
int activation_flow(const Ops *,unsigned);
