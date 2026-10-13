/* Actual native WAIT/KILL callbacks with syscall fakes, no processes/signals. */
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <assert.h>
static int wait_error=EIO,signals,exit_status,signal_error=1;static pid_t waited;
static pid_t f_wait(pid_t p,int *s,int flags){assert(p==444 && flags==WNOHANG);if(wait_error){errno=wait_error;return -1;}*s=exit_status;return waited;}
static int f_kill(pid_t p,int sig){assert(p==444 && (sig==SIGKILL||sig==SIGTERM));signals++;errno=EPERM;return signal_error?-1:0;}
#define waitpid f_wait
#define kill f_kill
#define main forbidden_entry
#include "../activation/activation_native.c"
#undef main
int main(void){
 Runtime r={.child=444};
 /* Initially tests the existing int WAIT adapter; migrated to typed wait with fix. */
 assert(child_wait(&r).kind==CHILD_ERROR && r.child==444);
 assert(step(&r,KILL)<0 && r.child==444);
 wait_error=0;waited=444;exit_status=(SIGSTOP<<8)|0x7f;assert(child_wait(&r).kind==CHILD_RUNNING && r.child==444);
 exit_status=3<<8;assert(child_wait(&r).kind==CHILD_REAPED && !r.child);
 int before=signals;assert(!step(&r,TERM));assert(!step(&r,KILL));assert(signals==before);
 /* ECHILD must not be translated to reaped, and WNOHANG is mandatory after KILL. */
 r.child=444;wait_error=ECHILD;assert(child_wait(&r).kind==CHILD_ERROR && r.child==444);
 signal_error=0;assert(!step(&r,KILL));assert(r.child==444);
 puts("PASS typed native child ownership");
}
