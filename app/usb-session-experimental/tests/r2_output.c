/* Actual READY with a fake permanently full inherited output FD. No real write. */
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <errno.h>
#include <assert.h>
static int blocking_stdio,nonblocking;
static int f_dprintf(int fd,const char *fmt,...){(void)fd;(void)fmt;blocking_stdio++;errno=EAGAIN;return -1;}
static int f_stat(int fd,struct stat *s){(void)fd;*s=(struct stat){.st_mode=S_IFIFO};return 0;}
static int f_fcntl(int fd,int cmd,...){(void)fd;if(cmd==F_GETFL)return 0;if(cmd==F_SETFL){va_list ap;va_start(ap,cmd);nonblocking=va_arg(ap,int)&O_NONBLOCK;va_end(ap);}return 0;}
static ssize_t f_write(int fd,const void *p,size_t n){(void)fd;(void)p;(void)n;assert(nonblocking);errno=EAGAIN;return -1;}
#define dprintf f_dprintf
#define fstat f_stat
#define fcntl f_fcntl
#define write f_write
#define main forbidden_entry
#include "../activation/activation_native.c"
#undef main
int main(void){Runtime r={.req={.lease=5}};assert(step(&r,READY)!=0);assert(!blocking_stdio);puts("PASS actual READY uses bounded nonblocking output, backpressure fails closed");}
