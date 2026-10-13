#pragma once
#include "process.h"
#include <sys/stat.h>
typedef struct {Process process;char path[4096];struct stat st;} ProcessSeal;
int seal_process(const Process *expected,ProcessSeal *seal);
int seal_live(const ProcessSeal *seal);
int secure_directory(const char *path,uid_t owner);
int self_protected(char path[4096]);
