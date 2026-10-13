#pragma once
#include "process.h"
int session_main(const char *attempt,uid_t uid,const Process *app,const char *self);
int worker_main(const char *attempt,uid_t uid,const Process *parent);
