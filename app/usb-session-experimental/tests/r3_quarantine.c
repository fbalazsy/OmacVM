/* Real quarantine/CLEAN implementation; storage/waits faked, no root files. */
#include <sys/types.h>
#include <unistd.h>
#include <sys/wait.h>
#include <time.h>
#include <setjmp.h>
#include <assert.h>
#include <string.h>
static jmp_buf parked;static int failure,writes,syncs,pauses,reaped;static char marker[32];
static ssize_t f_pwrite(int fd,const void *p,size_t n,off_t off){assert(fd==77&&!off);writes++;if(failure==1)return -1;assert(n<sizeof marker);memcpy(marker,p,n);return (ssize_t)n;}
static int f_fsync(int fd){assert(fd==77);syncs++;return failure==2?-1:0;}
static int f_pause(const struct timespec *t,struct timespec *out){(void)out;assert(t->tv_sec==1);pauses++;longjmp(parked,1);}
static pid_t f_wait(pid_t p,int *status,int flags){assert(p==444 && flags==WNOHANG);*status=0;return reaped?444:0;}
#define waitpid f_wait
#define pwrite f_pwrite
#define fsync f_fsync
#define nanosleep f_pause
#define main forbidden_entry
#include "../activation/activation_native.c"
#undef main
int main(void){
 Runtime r={.lock=77,.child=444};assert(step(&r,CLEAN)==-1 && r.child==444);
 if(!setjmp(parked)){step(&r,QUARANTINE);assert(0 && "must retain supervisor while child unconfirmed");}
 assert(writes==1&&syncs==1&&!strcmp(marker,"UNCONFIRMED\n")&&r.lock==77&&r.child==444);
 reaped=1;assert(!step(&r,QUARANTINE));assert(!r.child);reaped=0;r.child=444;
 for(failure=1;failure<=2;failure++)if(!setjmp(parked)){step(&r,QUARANTINE);assert(0);}else{assert(r.lock==77&&r.child==444);}
 assert(pauses==3);puts("PASS actual quarantine: durable nonempty arbitration marker; storage failures park retaining child/lock; CLEAN refuses live child");
}
