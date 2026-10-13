#include "../security.h"
#include <assert.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
extern int seal_process(const Process *,ProcessSeal *) __attribute__((weak_import));
extern int seal_live(const ProcessSeal *) __attribute__((weak_import));
extern int secure_directory(const char *,uid_t) __attribute__((weak_import));
extern int self_protected(char *) __attribute__((weak_import));
int main(void){assert(seal_process && seal_live && secure_directory && self_protected);Process p;ProcessSeal s;assert(process_read(getpid(),&p));assert(seal_process(&p,&s));assert(seal_live(&s));s.process.version++;assert(!seal_live(&s));char path[4096];assert(!self_protected(path));int library=secure_directory("/Library",0);assert(library>=0);close(library);assert(secure_directory(getenv("HOME"),0)<0);assert(secure_directory("/Library/../Library",0)<0);puts("security PASS: live executable snapshot/exec-generation mismatch; uninstalled self and unsafe ancestry refused");return 0;}
