#pragma once
#include <stdint.h>
#include <sys/types.h>
#include <sys/param.h>
typedef struct {pid_t pid; uid_t uid; uint64_t sec; uint32_t usec,version;} Process;
int scalar(const char *s,uint64_t max,uint64_t *out);
int process_read(pid_t pid,Process *out);
int process_equal(const Process *a,const Process *b);
