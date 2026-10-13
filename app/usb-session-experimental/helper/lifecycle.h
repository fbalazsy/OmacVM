#pragma once
typedef enum { ST_AUTH,ST_SCAN,ST_INIT,ST_OPEN,ST_RECHECK,ST_HOST,ST_HANDOFF,ST_POSTCHECK,ST_LOOP,ST_HOST_CLOSE,ST_HANDLE_CLOSE,ST_EXIT,ST_SOCKET_CLOSE,ST_COUNT } Stage;
typedef struct {void *ctx;int (*step)(void *,Stage);int (*stop)(void *);} Ops;
int lifecycle(Ops *ops);
