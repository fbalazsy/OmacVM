#import "supervisor.h"
#include <sys/wait.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
volatile sig_atomic_t interrupted;
int emit_event(int fd,NSString *attempt,NSString *event,NSDictionary *extra){
 NSMutableDictionary *d=[@{@"schema":@1,@"attempt":attempt,@"event":event} mutableCopy];if(extra)[d addEntriesFromDictionary:extra];
 NSMutableData *data=[[NSJSONSerialization dataWithJSONObject:d options:0 error:NULL] mutableCopy];if(!data||data.length>1024)return 0;[data appendBytes:"\n" length:1];return send_bounded(fd,data.bytes,data.length,100);
}
int supervise(int control,int channel,pid_t child,SocketOwner *usb,const Process *app,const Process *qemu,NSString *attempt){
 Line line={0};int cancelling=0,listening=0,postcheck=0,reaped=0,status=0,uncertain=0,term=0,killed=0;uint64_t start=monotonic_ms(),cancel_at=0;
 for(;;){@autoreleasepool {
  Process a,q;uint64_t now=monotonic_ms();
  if(!cancelling){int n=line_read(control,&line);
   if(n!=0||interrupted||!process_read(app->pid,&a)||!process_equal(app,&a)||!process_read(qemu->pid,&q)||!process_equal(qemu,&q)||!peer_matches(control,app)||(!postcheck&&now-start>30000)){
    /* Any further command, malformed input or EOF cancels; never recapture. */
    if(n==1)(void)request_parse([NSData dataWithBytes:line.data length:line.used],attempt,app->uid,1);
    cancelling=1;cancel_at=now;emit_event(control,attempt,@"releasing",nil);shutdown(channel,SHUT_WR);
   }
  }
  char bytes[8];ssize_t n=recv(channel,bytes,sizeof(bytes),0);
  if(n>0){for(ssize_t i=0;i<n;i++){
   if(bytes[i]=='L'&&!listening&&!postcheck){listening=1;if(!cancelling&&!emit_event(control,attempt,@"listening",nil))cancelling=1;}
   else if(bytes[i]=='P'&&listening&&!postcheck){postcheck=1;if(!cancelling&&!emit_event(control,attempt,@"postcheck",nil))cancelling=1;}
   else {uncertain=1;cancelling=1;}
  }}else if(n<0&&errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR){uncertain=1;cancelling=1;}
  if(cancelling&&!cancel_at){cancel_at=now;emit_event(control,attempt,@"releasing",nil);shutdown(channel,SHUT_WR);}
  pid_t waited=waitpid(child,&status,WNOHANG);
  if(waited==child){reaped=1;break;}
  if(waited<0&&errno!=EINTR){
   /* Error is never reaped. Keep arbitration and quarantine; no PID signalling
      once child ownership is lost (ECHILD could mean a reaped/reused PID). */
   emit_event(control,attempt,@"uncertain",@{@"message":@"Worker wait ownership unavailable; root quarantine retained"});
   for(;;)pause();
  }
  if(n==0&&!cancelling){cancelling=1;cancel_at=now;emit_event(control,attempt,@"releasing",nil);}
  if(cancelling&&now-cancel_at>8000&&!term){if(kill(child,SIGTERM)&&errno!=ESRCH)uncertain=1;term=1;}
  if(cancelling&&now-cancel_at>10000&&!killed){if(kill(child,SIGKILL)&&errno!=ESRCH)uncertain=1;killed=1;uncertain=1;emit_event(control,attempt,@"uncertain",@{@"message":@"Worker exceeded cleanup deadline; awaiting confirmed reap"});}
  struct pollfd f={channel,POLLIN,0};poll(&f,1,20);
 }}
 int clean=reaped&&WIFEXITED(status)&&(WEXITSTATUS(status)==0||WEXITSTATUS(status)==2||WEXITSTATUS(status)==3)&&!uncertain&&!term&&!killed;
 int removed=socket_remove(usb);
 if(!clean||!removed){if(!cancelling)emit_event(control,attempt,@"releasing",nil);emit_event(control,attempt,@"uncertain",@{@"message":@"Worker release or socket ownership not proven"});return 1;}
 if(WEXITSTATUS(status)==3&&!listening&&!cancelling){emit_event(control,attempt,@"failed",@{@"message":@"Device or process policy refused before capture"});return 0;}
 if(!cancelling)emit_event(control,attempt,@"releasing",nil);
 emit_event(control,attempt,@"released",@{@"hid_restored":@(WEXITSTATUS(status)==0)});return 0;
}
