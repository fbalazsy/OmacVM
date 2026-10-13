#import "session.h"
#import "protocol.h"
#import "supervisor.h"
#import "backend.h"
#include "security.h"
#include "io.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/file.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
static int wait_request(int fd,NSString *attempt,uid_t uid,NSDictionary **out,unsigned ms){
 Line l={0};uint64_t end=monotonic_ms()+ms;
 while(!interrupted&&monotonic_ms()<end){int n=line_read(fd,&l);if(n<0)return 0;if(n==1){*out=request_parse([NSData dataWithBytes:l.data length:l.used],attempt,uid,0);return *out!=nil;}struct pollfd f={fd,POLLIN,0};poll(&f,1,20);}return 0;
}
static int device_lock(int run,uint32_t location,const char *attempt){
 char name[48];snprintf(name,sizeof(name),"physical-%08x.lock",location);
 int fd=openat(run,name,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return -1;struct stat s;
 if(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_uid!=0||(s.st_mode&07777)!=0600||s.st_nlink!=1||flock(fd,LOCK_EX|LOCK_NB)||s.st_size!=0){close(fd);return -1;}
 /* Dirty marker is durable before USB can be opened. A killed supervisor
    leaves quarantine, not an unlocked reusable physical-device grant. */
 if(write(fd,attempt,36)!=36||fsync(fd)){close(fd);return -1;}return fd;
}
static pid_t spawn_worker(const char *self,const char *attempt,uid_t uid,int listener,int channel){
 Process p;if(!process_read(getpid(),&p))return -1;
 int l=fcntl(listener,F_DUPFD_CLOEXEC,10),c=fcntl(channel,F_DUPFD_CLOEXEC,10);if(l<0||c<0){if(l>=0)close(l);if(c>=0)close(c);return -1;}
 char user[24],pid[24],sec[32],usec[24],version[24];snprintf(user,sizeof(user),"%u",uid);snprintf(pid,sizeof(pid),"%d",p.pid);snprintf(sec,sizeof(sec),"%llu",(unsigned long long)p.sec);snprintf(usec,sizeof(usec),"%u",p.usec);snprintf(version,sizeof(version),"%u",p.version);
 char *argv[]={(char *)self,"--worker",(char *)attempt,user,pid,sec,usec,version,NULL};char *env[]={"PATH=/usr/bin:/bin",NULL};
 posix_spawn_file_actions_t actions;posix_spawnattr_t attr;pid_t child=-1;
 if(posix_spawn_file_actions_init(&actions)){close(l);close(c);return -1;}
 if(posix_spawnattr_init(&attr)){posix_spawn_file_actions_destroy(&actions);close(l);close(c);return -1;}
 int rc=posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT);
 rc|=posix_spawn_file_actions_adddup2(&actions,l,3);rc|=posix_spawn_file_actions_adddup2(&actions,c,4);
 for(int i=0;i<3;i++)rc|=posix_spawn_file_actions_addopen(&actions,i,"/dev/null",i?O_WRONLY:O_RDONLY,0);
 if(!rc)rc=posix_spawn(&child,self,&actions,&attr,argv,env);
 posix_spawnattr_destroy(&attr);posix_spawn_file_actions_destroy(&actions);close(l);close(c);return rc?-1:child;
}
int session_main(const char *attempt,uid_t uid,const Process *app,const char *self){
 NSString *uuid=@(attempt);ProcessSeal appseal;if(!seal_process(app,&appseal))return 65;
 int root=secure_directory(INSTALL_ROOT,0);if(root<0)return 65;
 int created=mkdirat(root,"run",0711)==0;if(!created&&errno!=EEXIST){close(root);return 65;}close(root);
 int run=secure_directory(RUN_ROOT,0);if(run<0)return 65;if(created&&fchmod(run,0711)){close(run);return 65;}
 struct stat runstat;if(fstat(run,&runstat)||(runstat.st_mode&07777)!=0711){close(run);return 65;}
 /* An unknown existing attempt is never repaired or recursively removed. */
 if(mkdirat(run,attempt,0711)){close(run);return 65;}
 int dir=openat(run,attempt,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(dir<0||fchmod(dir,0711)||flock(dir,LOCK_EX|LOCK_NB)){if(dir>=0)close(dir);close(run);return 65;}
 char controlpath[104],usbpath[104];snprintf(controlpath,sizeof(controlpath),RUN_ROOT "/%s/control.sock",attempt);snprintf(usbpath,sizeof(usbpath),RUN_ROOT "/%s/usb.sock",attempt);
 SocketOwner control={.fd=-1},usb={.fd=-1};int client=-1,lock=-1,pair[2]={-1,-1},result=65;pid_t child=-1;NSDictionary *request=nil;uint64_t end=monotonic_ms()+30000;
 if(!socket_create(&control,controlpath,uid))goto done;
 while(!interrupted&&monotonic_ms()<end&&seal_live(&appseal)){
  struct pollfd f={control.fd,POLLIN,0};poll(&f,1,20);if(!(f.revents&POLLIN))continue;
  client=accept(control.fd,NULL,NULL);if(client<0){if(errno==EAGAIN||errno==EINTR)continue;break;}
  if(!nonblocking(client)||!peer_matches(client,app)){close(client);client=-1;continue;}break;
 }
 if(client<0)goto done;close(control.fd);control.fd=-1;
 if(!wait_request(client,uuid,uid,&request,10000)||!peer_matches(client,app)||!seal_live(&appseal)){emit_event(client,uuid,@"failed",@{@"message":@"Invalid or expired control handshake"});goto done;}
 if([request[@"command"] isEqual:@"cancel"]){emit_event(client,uuid,@"releasing",nil);emit_event(client,uuid,@"released",@{@"hid_restored":@NO});result=0;goto done;}
 Process qemu=request_process(request[@"qemu"]);ProcessSeal seal;
 if(!seal_process(&qemu,&seal)){emit_event(client,uuid,@"failed",@{@"message":@"Selected VM process changed"});goto done;}
 lock=device_lock(run,[request[@"device"][@"location"] unsignedIntValue],attempt);
 if(lock<0){emit_event(client,uuid,@"failed",@{@"message":@"Physical device busy or quarantined"});goto done;}
 if(!socket_create(&usb,usbpath,uid)||socketpair(AF_UNIX,SOCK_STREAM,0,pair)||!nonblocking(pair[0])||!nonblocking(pair[1]))goto before_spawn_failed;
 child=spawn_worker(self,attempt,uid,usb.fd,pair[1]);if(child<0)goto before_spawn_failed;
 close(pair[1]);pair[1]=-1;close(usb.fd);usb.fd=-1;
 {
  NSMutableData *data=[[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL] mutableCopy];[data appendBytes:"\n" length:1];
  if(!seal_live(&seal)||!peer_matches(client,app)||!send_bounded(pair[0],data.bytes,data.length,100))shutdown(pair[0],SHUT_WR);
  result=supervise(client,pair[0],child,&usb,app,&qemu,uuid);child=-1;
 }
 goto done;
 before_spawn_failed:
 if(socket_remove(&usb)){result=0;emit_event(client,uuid,@"failed",@{@"message":@"Native worker startup failed before capture"});}
 else emit_event(client,uuid,@"uncertain",@{@"message":@"Native socket cleanup unproven"});
 done:
 if(pair[0]>=0)close(pair[0]);if(pair[1]>=0)close(pair[1]);
 if(!socket_remove(&usb))result=1;if(!socket_remove(&control))result=1;
 if(lock>=0){if(result==0){if(ftruncate(lock,0)||fsync(lock))result=1;}close(lock);}
 if(client>=0)close(client);close(dir);close(run);
 /* Root-owned empty attempt directory intentionally remains as a replay
    tombstone. Only explicit maintenance may remove it after review. */
 return result;
}
int worker_main(const char *attempt,uid_t uid,const Process *parent){
 if(parent->uid!=0||!peer_matches(4,parent)||!nonblocking(3)||!nonblocking(4))return 3;
 char path[104];snprintf(path,sizeof(path),RUN_ROOT "/%s/usb.sock",attempt);struct sockaddr_un a={0};socklen_t n=sizeof(a);struct stat s;int listening=0;n=sizeof(listening);
 if(getsockopt(3,SOL_SOCKET,SO_ACCEPTCONN,&listening,&n)||!listening)return 3;n=sizeof(a);
 if(getsockname(3,(struct sockaddr *)&a,&n)||a.sun_family!=AF_UNIX||strcmp(a.sun_path,path)||lstat(path,&s)||!S_ISSOCK(s.st_mode)||s.st_uid!=uid||(s.st_mode&0777)!=0600)return 3;
 NSDictionary *request=nil;if(!wait_request(4,@(attempt),uid,&request,10000)||![request[@"command"] isEqual:@"capture"]||!peer_matches(4,parent))return 3;
 return backend_run(request,4,3,parent);
}
