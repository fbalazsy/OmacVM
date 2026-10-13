#pragma once
#include <stdint.h>
#include <stddef.h>
#include "local_pins.h"
typedef struct { uint32_t pid, usec, lease, version; uint64_t sec, deadline_ns; } Request;
typedef struct { uint32_t pid, uid, ruid, usec, version; uint64_t sec; int signature, argv; char path[4096], sha[65], cdhash[41]; } Identity;
int request_parse(const char *,const char *,const char *,const char *,Request *);
int identity_policy(const Request *,const Identity *,const Identity *);
int manifest_format(const Request *,char *,size_t);
