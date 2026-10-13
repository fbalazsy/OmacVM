#include "../io.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern int line_read(int,Line *) __attribute__((weak_import));
extern int socket_create(SocketOwner *,const char *,uid_t) __attribute__((weak_import));
extern int socket_remove(SocketOwner *) __attribute__((weak_import));
extern int peer_matches(int,const Process *) __attribute__((weak_import));
extern int send_bounded(int,const void *,size_t,unsigned) __attribute__((weak_import));
extern int nonblocking(int) __attribute__((weak_import));
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);return 1;}count++;}while(0)
int main(void){unsigned count=0;CHECK(line_read && socket_create && socket_remove && peer_matches && send_bounded && nonblocking);
 int f[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,f));CHECK(nonblocking(f[0]) && nonblocking(f[1]));
 Line l={0};CHECK(write(f[1],"abc",3)==3);CHECK(line_read(f[0],&l)==0 && l.used==3);
 CHECK(write(f[1],"\ndef\n",5)==5);CHECK(line_read(f[0],&l)==1 && !strcmp(l.data,"abc"));l.used=0;
 CHECK(line_read(f[0],&l)==1 && !strcmp(l.data,"def"));l.used=0;close(f[1]);CHECK(line_read(f[0],&l)==-1);close(f[0]);
 CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,f));CHECK(nonblocking(f[0]) && nonblocking(f[1]));int large=65536;setsockopt(f[1],SOL_SOCKET,SO_SNDBUF,&large,sizeof(large));char big[16385];memset(big,'a',sizeof(big));CHECK(write(f[1],big,sizeof(big))==sizeof(big));l.used=0;CHECK(line_read(f[0],&l)==-1);close(f[0]);close(f[1]);
 char dir[104];CHECK(getenv("TMPDIR"));CHECK(snprintf(dir,sizeof(dir),"%s/uio-XXXXXX",getenv("TMPDIR"))<(int)sizeof(dir)-3);CHECK(mkdtemp(dir));char path[104];snprintf(path,sizeof(path),"%s/s",dir);
 SocketOwner s={.fd=-1},other={.fd=-1};CHECK(socket_create(&s,path,getuid()));CHECK(!socket_create(&other,path,getuid()));
 int c=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un a={.sun_family=AF_UNIX};strlcpy(a.sun_path,path,sizeof(a.sun_path));CHECK(!connect(c,(struct sockaddr *)&a,sizeof(a)));int p=accept(s.fd,NULL,NULL);CHECK(p>=0);Process me;CHECK(process_read(getpid(),&me));CHECK(peer_matches(p,&me));me.version++;CHECK(!peer_matches(p,&me));close(c);close(p);
 CHECK(!unlink(path));int sentinel=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);CHECK(sentinel>=0);close(sentinel);CHECK(!socket_remove(&s));CHECK(!access(path,F_OK));CHECK(!unlink(path));CHECK(!rmdir(dir));
 CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,f));CHECK(nonblocking(f[0]) && nonblocking(f[1]));int size=1024;setsockopt(f[0],SOL_SOCKET,SO_SNDBUF,&size,sizeof(size));while(write(f[0],big,sizeof(big))>0){}CHECK(!send_bounded(f[0],"x",1,30));close(f[0]);close(f[1]);
 printf("io: %u assertions PASS\n",count);return 0;}
