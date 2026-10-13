#ifndef BALDUR_SESSION_SOCKET_H
#define BALDUR_SESSION_SOCKET_H
/* Only supervisor binds/unlinks. Helper inherits fd 3; no cleanup-report race. */
#define BALDUR_SUPERVISED_SOCKET 1
#define BALDUR_LISTENER_FD 3
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
typedef struct {int fd,active,bound,known;dev_t dev;ino_t ino;} SessionSocket;
static inline int session_socket_create(SessionSocket *s,int dir,const char *name,const char *path,uid_t uid,gid_t gid){
 struct stat st;struct sockaddr_un addr={0};
 if(s->active || s->bound)return -1;
 if(!fstatat(dir,name,&st,AT_SYMLINK_NOFOLLOW) || errno!=ENOENT)return -1;
 addr.sun_family=AF_UNIX;addr.sun_len=sizeof(addr);
 if(snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/%s",path,name)>=(int)sizeof(addr.sun_path))return -1;
 s->fd=socket(AF_UNIX,SOCK_STREAM,0);if(s->fd<0)return -1;s->active=1;
 if(fcntl(s->fd,F_SETFD,FD_CLOEXEC) || fcntl(s->fd,F_SETFL,O_NONBLOCK))return -1;
 if(bind(s->fd,(struct sockaddr *)&addr,sizeof(addr)))return -1;
 s->bound=1; /* unknown inode after bind failure remains quarantined */
 if(fstatat(dir,name,&st,AT_SYMLINK_NOFOLLOW) || !S_ISSOCK(st.st_mode) || st.st_nlink!=1)return -1;
 s->dev=st.st_dev;s->ino=st.st_ino;s->known=1;
 if(fchownat(dir,name,uid,gid,AT_SYMLINK_NOFOLLOW) || fchmodat(dir,name,0600,AT_SYMLINK_NOFOLLOW) || listen(s->fd,1))return -1;
 return 0;
}
static inline int session_socket_clean(SessionSocket *s,int dir,const char *name,int child_owned){
 if(child_owned)return -1; /* only actual waitpid reap releases deletion authority */
 if(s->active){close(s->fd);s->active=0;}
 if(s->bound){
  struct stat st;if(!s->known)return -1;
  if(fstatat(dir,name,&st,AT_SYMLINK_NOFOLLOW)){
   if(errno!=ENOENT)return -1;
  }else{
   if(!S_ISSOCK(st.st_mode) || st.st_nlink!=1 || st.st_dev!=s->dev || st.st_ino!=s->ino)return -1;
   if(unlinkat(dir,name,0))return -1;
  }
  if(fsync(dir))return -1;
  s->bound=0;
 }
 return 0;
}
static inline int session_socket_validate(int fd,const char *path,uid_t uid){
 struct stat st;struct sockaddr_un addr={0};socklen_t size=sizeof(addr),n=sizeof(int);int type=0;
 if(fstat(fd,&st) || !S_ISSOCK(st.st_mode) || getsockname(fd,(struct sockaddr *)&addr,&size) || addr.sun_family!=AF_UNIX)return -1;
 if(strnlen(addr.sun_path,sizeof(addr.sun_path))==sizeof(addr.sun_path) || strcmp(addr.sun_path,path))return -1;
 /* Darwin AF_UNIX returns ENOPROTOOPT for SO_ACCEPTCONN. The pinned parent
    calls listen before fork; validate the inherited bound stream, not this option. */
 if(getsockopt(fd,SOL_SOCKET,SO_TYPE,&type,&n) || type!=SOCK_STREAM)return -1;
 if(lstat(path,&st) || !S_ISSOCK(st.st_mode) || st.st_nlink!=1 || st.st_uid!=uid || (st.st_mode&07777)!=0600)return -1;
 return 0;
}
#endif
