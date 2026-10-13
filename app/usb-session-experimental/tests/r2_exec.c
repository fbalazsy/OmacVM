/* Parent SPAWN path only, all fork/pipe/FD syscalls are fakes. No executable runs. */
#include <unistd.h>
#include <fcntl.h>
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <setjmp.h>
static int pipe_calls,read_mode,closed,forks,child_branch,redirected,ack_failure;static jmp_buf child_exit;
static pid_t f_fork(void){forks++;return child_branch?0:444;}
static int f_pipe(int p[2]){pipe_calls++;p[0]=88;p[1]=89;return 0;}
static int f_close(int fd){assert(fd>=3 && fd<100);closed++;return 0;}
static int f_fcntl(int fd,int op,...){(void)fd;(void)op;return 0;}
static ssize_t f_read(int fd,void *p,size_t n){assert(fd==88 && n>0);if(read_mode==0){errno=EAGAIN;return -1;}if(read_mode==1)return 0;*(unsigned char *)p=127;return 1;}
static int f_open(const char *p,int flags,...){assert(!strcmp(p,"/dev/null")&&flags==O_RDWR);return 90;}
static int f_dup2(int from,int to){assert((from==90&&to>=0&&to<=2)||(from==77&&to==3));redirected|=1<<to;return to;}
static long f_sysconf(int name){assert(name==_SC_OPEN_MAX);return 100;}
static sig_t f_signal(int sig,sig_t handler){(void)sig;(void)handler;return SIG_DFL;}
static int f_execve(const char *path,char *const args[],char *const env[]){assert(strstr(path,"org.omacvm.usb-session-experimental-helper")&&args[1]&&!strcmp(args[1],"--serve")&&env[0]);errno=ENOEXEC;return -1;}
static ssize_t f_write(int fd,const void *p,size_t n){assert(fd==89&&n==1);ack_failure=*(const unsigned char *)p;return 1;}
__attribute__((noreturn)) static void f_exit(int rc){assert(rc==127);longjmp(child_exit,1);}
#define open f_open
#define dup2 f_dup2
#define sysconf f_sysconf
#define signal f_signal
#define execve f_execve
#define write f_write
#define _exit f_exit
#define fork f_fork
#define pipe f_pipe
#define close f_close
#define fcntl f_fcntl
#define read f_read
#define main forbidden_entry
#include "../activation/activation_native.c"
#undef main
int main(void){Runtime r={0};assert(!step(&r,SPAWN));assert(pipe_calls==1 && r.child==444 && forks==1);assert(step(&r,EXEC_ACK)==0 && r.exec_pending);
 read_mode=2;assert(step(&r,EXEC_ACK)==-1 && !r.exec_pending && r.child==444);
 read_mode=1;r.execfd=88;r.exec_pending=1;assert(step(&r,EXEC_ACK)==1 && !r.exec_pending);
 r.socket.active=1;r.socket.fd=77;
 child_branch=1;if(!setjmp(child_exit)){step(&r,SPAWN);assert(0);}
 assert(redirected==13&&ack_failure==127);
 puts("PASS child failure ack; stdin/stderr detached, stdout bounded evidence pipe retained; exec ack and child reap ownership retained");}
