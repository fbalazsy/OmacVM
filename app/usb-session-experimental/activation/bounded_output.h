#pragma once
#include <stdarg.h>
/* One bounded write, no stdio buffering/retry. Status requires a FIFO/socket;
 * unsupported or blocked destinations fail closed. Diagnostics may be dropped. */
static int bounded_output(int fd,const char *fmt,...) {
 char b[512];va_list ap;va_start(ap,fmt);int n=vsnprintf(b,sizeof b,fmt,ap);va_end(ap);
 if(n<=0 || (size_t)n>=sizeof b)return -1;
 struct stat s;if(fstat(fd,&s) || (!S_ISFIFO(s.st_mode)&&!S_ISSOCK(s.st_mode)))return -1;
 int flags=fcntl(fd,F_GETFL);if(flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK))return -1;
 return write(fd,b,(size_t)n)==n?0:-1;
}
