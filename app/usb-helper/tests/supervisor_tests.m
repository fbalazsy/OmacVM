#import "../supervisor.h"
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
extern int supervise(int,int,pid_t,SocketOwner *,const Process *,const Process *,NSString *) __attribute__((weak_import));
int main(void){@autoreleasepool {assert(supervise);Process p;assert(process_read(getpid(),&p));
 for(unsigned mode=0;mode<3;mode++){
  int app[2],worker[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,app));assert(!socketpair(AF_UNIX,SOCK_STREAM,0,worker));for(int i=0;i<2;i++){assert(nonblocking(app[i]));assert(nonblocking(worker[i]));}
  char dir[104],path[104];assert(getenv("TMPDIR"));assert(snprintf(dir,sizeof(dir),"%s/usv-XXXXXX",getenv("TMPDIR"))<(int)sizeof(dir)-3);assert(mkdtemp(dir));snprintf(path,sizeof(path),"%s/s",dir);SocketOwner owner={.fd=-1};assert(socket_create(&owner,path,getuid()));
  pid_t child=fork();assert(child>=0);if(!child){close(app[0]);close(app[1]);close(worker[0]);close(owner.fd);if(mode==2)_exit(9);assert(write(worker[1],"LP",2)==2);for(unsigned i=0;i<500;i++){char c;ssize_t n=read(worker[1],&c,1);if(n==0||n==1)_exit(2);usleep(1000);}_exit(9);}
  close(worker[1]);if(mode==1){close(app[1]);app[1]=-1;}else {const char *cancel="{\"schema\":1,\"command\":\"cancel\",\"attempt\":\"01234567-89ab-cdef-0123-456789abcdef\"}\n";assert(write(app[1],cancel,strlen(cancel))==(ssize_t)strlen(cancel));}
  int result=supervise(app[0],worker[0],child,&owner,&p,&p,@"01234567-89ab-cdef-0123-456789abcdef");assert(result==(mode==2?1:0));assert(access(path,F_OK)!=0);int st;assert(waitpid(child,&st,WNOHANG)==-1);
  if(app[1]>=0){char output[4096]={0};ssize_t n=read(app[1],output,sizeof(output)-1);assert(n>0);assert(strstr(output,"releasing"));assert(strstr(output,mode==2?"uncertain":"released"));assert(!strstr(output,"postcheck"));close(app[1]);}close(app[0]);close(worker[0]);assert(!rmdir(dir));
 }
 puts("supervisor PASS: cancel-before-late-postcheck, control EOF, clean reap, abnormal child uncertainty, own socket removal");return 0;}}
