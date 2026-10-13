#include "io.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <bsm/libbsm.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <time.h>
uint64_t monotonic_ms(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC_RAW,&t))return 0;return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000;}
int nonblocking(int fd){int flags=fcntl(fd,F_GETFL);int yes=1;return flags>=0 && !fcntl(fd,F_SETFL,flags|O_NONBLOCK) && !fcntl(fd,F_SETFD,FD_CLOEXEC) && !setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));}
int line_read(int fd,Line *l){
 /* 256-byte peeks avoid consuming a second request and bound syscall work. */
 for(unsigned iterations=0;iterations<128;iterations++){
  char buf[256];ssize_t n=recv(fd,buf,sizeof(buf),MSG_PEEK);
  if(n<0 && (errno==EINTR||errno==EAGAIN||errno==EWOULDBLOCK))return 0;if(n<=0)return -1;
  char *end=memchr(buf,'\n',(size_t)n);size_t take=end?(size_t)(end-buf)+1:(size_t)n;
  if(l->used+take>LINE_MAX_BYTES+1 || memchr(buf,0,take))return -1;
  n=recv(fd,buf,take,0);if(n!=(ssize_t)take)return -1;
  if(end){size_t chars=take-1;memcpy(l->data+l->used,buf,chars);l->used+=chars;l->data[l->used]=0;return 1;}
  if(l->used+take>LINE_MAX_BYTES)return -1;memcpy(l->data+l->used,buf,take);l->used+=take;
 }return 0;
}
void line_consume(Line *l){l->used=0;}
int send_bounded(int fd,const void *data,size_t n,unsigned milliseconds){
 uint64_t end=monotonic_ms()+milliseconds;const char *p=data;
 while(n){ssize_t done=send(fd,p,n,0);if(done>0){p+=done;n-=done;continue;}
  if(done==0 || (errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR))return 0;
  uint64_t now=monotonic_ms();if(!now||now>=end)return 0;struct pollfd f={fd,POLLOUT,0};if(poll(&f,1,(int)(end-now))<0 && errno!=EINTR)return 0;
 }return 1;
}
int peer_matches(int fd,const Process *e){
 uid_t uid;gid_t gid;pid_t pid; audit_token_t a={0},b={0};socklen_t n=sizeof(a);
 if(getpeereid(fd,&uid,&gid)||uid!=e->uid||getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&a,&n)||n!=sizeof(a))return 0;
 n=sizeof(pid);if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&n)||n!=sizeof(pid)||pid!=e->pid||audit_token_to_pid(a)!=e->pid||audit_token_to_euid(a)!=e->uid||audit_token_to_ruid(a)!=e->uid||(uint32_t)audit_token_to_pidversion(a)!=e->version)return 0;
 Process actual;if(!process_read(pid,&actual)||!process_equal(e,&actual))return 0;
 n=sizeof(b);return !getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&b,&n)&&n==sizeof(b)&&!memcmp(&a,&b,sizeof(a));
}
int socket_create(SocketOwner *s,const char *path,uid_t uid){
 if(!s||!path||strlen(path)>=sizeof(s->path))return 0;
 memset(s,0,sizeof(*s));s->fd=-1;struct stat st;if(!lstat(path,&st)||errno!=ENOENT)return 0;
 int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return 0;struct sockaddr_un a={.sun_family=AF_UNIX};strlcpy(a.sun_path,path,sizeof(a.sun_path));
 if(bind(fd,(struct sockaddr *)&a,sizeof(a))){close(fd);return 0;}
 /* Record immediately, including failure paths; never unlink an unrecorded inode. */
 if(lstat(path,&st)||!S_ISSOCK(st.st_mode)){close(fd);return 0;}
 s->fd=fd;s->dev=st.st_dev;s->ino=st.st_ino;s->owned=1;strlcpy(s->path,path,sizeof(s->path));
 if((uid!=getuid() && chown(path,uid,(gid_t)-1))||chmod(path,0600)||!nonblocking(fd)||listen(fd,1)){socket_remove(s);return 0;}return 1;
}
int socket_remove(SocketOwner *s){
 if(s->fd>=0){close(s->fd);s->fd=-1;}if(!s->owned)return 1;struct stat st;
 if(lstat(s->path,&st)||!S_ISSOCK(st.st_mode)||st.st_dev!=s->dev||st.st_ino!=s->ino)return 0;
 if(unlink(s->path))return 0;s->owned=0;return 1;
}
