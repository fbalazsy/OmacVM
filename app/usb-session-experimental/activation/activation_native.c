/* One-shot native root supervisor. No USB, QMP, shells or user code in root. */
#include "native_platform.c"
#include "activation_flow.h"
#include <sys/file.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include "bounded_output.h"
#include "continuous_clock.h"
#include "session_socket.h"
static volatile sig_atomic_t interrupted;
static void on_signal(int s){interrupted=s;}

static int self_protected(void) {
 char path[PROC_PIDPATHINFO_MAXSIZE];if(proc_pidpath(getpid(),path,sizeof(path))<=0||strcmp(path,ACTIVATOR))return 0;
 int dir=secure_dir(INSTALL_DIR);if(dir<0)return 0;int fd=protected_file(dir,"org.omacvm.usb-session-experimental-activate",0555,1);close(dir);if(fd<0)return 0;close(fd);return 1;
}
static int existing_helper(void) {
 int capacity=proc_listallpids(NULL,0);if(capacity<=0||capacity>1000000)return -1;capacity+=1024;
 pid_t *pids=calloc((size_t)capacity,sizeof(pid_t));if(!pids)return -1;
 int n=proc_listallpids(pids,capacity*(int)sizeof(pid_t)),found=0;
 if(n<=0||n>=capacity)found=-1;
 for(int i=0;i<n&&found==0;i++){char p[PROC_PIDPATHINFO_MAXSIZE];if(proc_pidpath(pids[i],p,sizeof(p))>0&&!strcmp(p,HELPER))found=1;}
 free(pids);return found;
}
typedef struct {Request req;int dir,lock,manifest,run,helper,published,temp,execfd,exec_pending;struct stat inode;pid_t child;SessionSocket socket;int spawned,reaped,child_status;} Runtime;
static double clock_now(void *context){
 Runtime *r=context;uint64_t now=continuous_ns();if(!now){interrupted=1;return 1e30;}
 if(r->req.lease && !r->req.deadline_ns)r->req.deadline_ns=now+(uint64_t)r->req.lease*1000000000;
 return (double)now/1e9;
}
static int same_inode_at(int dir,const char *name,int fd) {
 struct stat a,b;return !fstat(fd,&a)&&!fstatat(dir,name,&b,AT_SYMLINK_NOFOLLOW)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&S_ISREG(b.st_mode)&&b.st_nlink==1;
}
static int cleanup_manifest(Runtime *r) {
 if(session_socket_clean(&r->socket,r->run,"usb.sock",r->child>0))return -1;
 int rc=0;if(r->exec_pending){close(r->execfd);r->exec_pending=0;}if(r->manifest>=0){const char *name=r->published?"peer.conf":".peer.next";
  if(r->temp || r->published){if(!same_inode_at(r->dir,name,r->manifest)||fchflags(r->manifest,0)||unlinkat(r->dir,name,0))rc=-1;else if(fsync(r->dir))rc=-1;}
  if(rc)return rc; /* keep descriptors/arbitration for durable quarantine */
  close(r->manifest);r->manifest=-1;
 }
 if(r->helper>=0)close(r->helper);if(r->run>=0)close(r->run);if(r->lock>=0)close(r->lock);if(r->dir>=0)close(r->dir);return rc;
}
static int prepare(Runtime *r) {
 r->dir=secure_dir(STATE_DIR);r->run=secure_dir(SOCKET_DIR);if(r->dir<0||r->run<0)return -1;
 struct stat st;if(fstat(r->run,&st)||(st.st_mode&07777)!=0711)return -1;
 r->lock=openat(r->dir,"activation.lock",O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0600);
 if(r->lock<0||fstat(r->lock,&st)||!secure_metadata(&st,0600,0)||!no_acl(r->lock)||flock(r->lock,LOCK_EX|LOCK_NB)||fstat(r->lock,&st)||st.st_size!=0)return -1;
 if(existing_helper()!=0)return -1;
 if(!fstatat(r->run,"usb.sock",&st,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)return -1;
 int bin=secure_dir(INSTALL_DIR);if(bin<0)return -1;r->helper=protected_file(bin,"org.omacvm.usb-session-experimental-helper",0555,1);close(bin);
 char hash[65];if(r->helper<0||!hash_fd(r->helper,hash)||strcmp(hash,HELPER_SHA))return -1;
 return session_socket_create(&r->socket,r->run,"usb.sock",SOCKET_DIR,PROFILE_UID,PROFILE_GID);
}
static int publish(Runtime *r) {
 char body[513];if(!deadline_valid(continuous_ns(),r->req.deadline_ns,r->req.lease)||!manifest_format(&r->req,body,sizeof(body)))return -1;
 r->manifest=openat(r->dir,".peer.next",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0400);if(r->manifest<0)return -1;r->temp=1;
 size_t len=strlen(body);if(write(r->manifest,body,len)!=(ssize_t)len||fchmod(r->manifest,0400)||fsync(r->manifest)||fstat(r->manifest,&r->inode)||!secure_metadata(&r->inode,0400,0)||!no_acl(r->manifest))return -1;
 /* Existing stale root-only peer.conf is replaced, never relaxed/reused. */
 int old=protected_file(r->dir,"peer.conf",0400,1);
 if(old<0&&errno!=ENOENT)return -1;
 if(old>=0){struct stat s;if(fstat(old,&s)||s.st_size<=0||s.st_size>512||!same_inode_at(r->dir,"peer.conf",old)||fchflags(old,0)){close(old);return -1;}}
 if(renameat(r->dir,".peer.next",r->dir,"peer.conf")){if(old>=0){(void)fchflags(old,UF_IMMUTABLE);close(old);}return -1;}
 r->published=1;r->temp=0;if(old>=0)close(old);
 /* macOS forbids rename of an already-immutable inode: atomic content rename,
    then immutable freeze inside root-only ancestry, BEFORE any helper exec. */
 if(fchflags(r->manifest,UF_IMMUTABLE)||fsync(r->manifest)||fsync(r->dir)||!same_inode_at(r->dir,"peer.conf",r->manifest))return -1;
 struct stat final;if(fstat(r->manifest,&final)||!secure_metadata(&final,0400,1))return -1;return 0;
}
static ChildResult child_wait(void *context) {
 Runtime *r=context;int status=0;
 if(r->child<=0)return (ChildResult){CHILD_ERROR,0,ECHILD};
 pid_t n=waitpid(r->child,&status,WNOHANG);
 if(n<0)return (ChildResult){errno==EINTR?CHILD_RUNNING:CHILD_ERROR,0,errno};
 if(!n)return (ChildResult){CHILD_RUNNING,0,0};
 if(n!=r->child)return (ChildResult){CHILD_ERROR,0,ECHILD};
 if(!WIFEXITED(status)&&!WIFSIGNALED(status))return (ChildResult){CHILD_RUNNING,0,0};
 r->child=0;r->reaped=1;r->child_status=WIFEXITED(status)?WEXITSTATUS(status):128+WTERMSIG(status);
 return (ChildResult){CHILD_REAPED,r->child_status,0};
}
static int quarantine(Runtime *r) {
 /* Durable refusal bit in the stable arbitration inode; never unlink the lock.
    If storage cannot record it, retain live arbitration in this process. */
 const char marker[]="UNCONFIRMED\n";
 int marked=r->lock>=0 && pwrite(r->lock,marker,sizeof(marker)-1,0)==sizeof(marker)-1 && !fsync(r->lock);
 for(;;){
  /* Do not orphan an uncertain child by returning to main/exit. No further
     signals after wait uncertainty: even numeric PID ownership is uncertain. */
  if(r->child>0)(void)child_wait(r);
  if(marked && !r->child)return 0;
  struct timespec delay={1,0};nanosleep(&delay,NULL);
 } /* fail closed: observer+lock retained, not a capture lease renewal */
}
static int step(void *context,Stage stage) {
 Runtime *r=context;
 switch(stage){
 case AUTH:case REAUTH:return authenticate(&r->req,NULL)?0:-1;
 case PREPARE:return prepare(r);
 case PUBLISH:return publish(r);
 case SPAWN:{
  /* The pinned helper is immutable in root-only ancestry; no fd/path race for profile UID. */
  int ack[2];if(pipe(ack))return -1;
  if(fcntl(ack[0],F_SETFD,FD_CLOEXEC)||fcntl(ack[1],F_SETFD,FD_CLOEXEC)||fcntl(ack[0],F_SETFL,O_NONBLOCK)){close(ack[0]);close(ack[1]);return -1;}
  r->child=fork();if(r->child<0){r->child=0;close(ack[0]);close(ack[1]);return -1;}
  if(!r->child){
   close(ack[0]);signal(SIGINT,SIG_DFL);signal(SIGTERM,SIG_DFL);signal(SIGHUP,SIG_DFL);signal(SIGPIPE,SIG_DFL);
   unsigned char failure=126;
   /* stderr/vendor diagnostics go to null. stdout is only bounded_output
      structured evidence into the controller pipe, never blocking stdio. */
   int nullfd=open("/dev/null",O_RDWR);
   if(nullfd<0||dup2(nullfd,0)<0||dup2(nullfd,2)<0)goto exec_failed;
   long maxfd=sysconf(_SC_OPEN_MAX);if(maxfd<3||maxfd>1048576)goto exec_failed;
   if(!r->socket.active || dup2(r->socket.fd,BALDUR_LISTENER_FD)<0 || fcntl(BALDUR_LISTENER_FD,F_SETFD,0))goto exec_failed;
   for(int fd=3;fd<maxfd;fd++)if(fd!=ack[1] && fd!=BALDUR_LISTENER_FD)close(fd);
   char *const args[]={HELPER,"--serve",NULL};char *const env[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin","HOME=/var/root",NULL};
   execve(HELPER,args,env);failure=127;
   exec_failed:(void)write(ack[1],&failure,1);_exit(failure);
  }
  r->spawned=1;close(ack[1]);r->execfd=ack[0];r->exec_pending=1;return 0;
 }
 case EXEC_ACK:{
  if(!r->exec_pending)return -1;
  unsigned char failure;ssize_t n=read(r->execfd,&failure,1);
  if(n<0 && (errno==EAGAIN||errno==EINTR))return 0;
  close(r->execfd);r->exec_pending=0;r->execfd=-1;return n==0?1:-1;
 }
 case READY:return bounded_output(STDOUT_FILENO,"{\"activation\":\"started\",\"lease\":%u}\n",r->req.lease);
 case WAIT:return -1; /* Use typed child_wait only. */
 case CANCEL:{struct pollfd fd={STDIN_FILENO,POLLIN|POLLHUP,0};if(interrupted)return 1;int n=poll(&fd,1,0);return n<0?(errno==EINTR?0:-1):(n>0);}
 case TERM:return r->child>0 && kill(r->child,SIGTERM) && errno!=ESRCH?-1:0;
 case KILL:return r->child>0 && kill(r->child,SIGKILL)?-1:0;
 case PAUSE:{struct timespec delay={0,50000000};nanosleep(&delay,NULL);return 0;}
 case CLEAN:
  if(r->child>0 || (r->spawned && !r->reaped) || cleanup_manifest(r))return -1;
  (void)bounded_output(STDOUT_FILENO,"{\"activation\":\"released\",\"child_status\":%d}\n",r->spawned?r->child_status:-1);return 0;
 case QUARANTINE:return quarantine(r);
 }
 return -1;
}
static int parse_version(const char *text,Request *r) {
 if(!text||!*text||(*text=='0'&&text[1]))return 0;uint64_t n=0;
 for(const char *p=text;*p;p++){if(*p<'0'||*p>'9')return 0;n=n*10+(unsigned)(*p-'0');if(n>UINT32_MAX)return 0;}r->version=(uint32_t)n;return 1;
}
int main(int argc,const char *argv[]) {
 umask(077);Request r={0};int ordinary=getuid()==PROFILE_UID&&geteuid()==PROFILE_UID;
 if(argc==3&&!strcmp(argv[1],"--inspect")&&ordinary){
  if(!request_parse(argv[2],"1","0","120",&r)||!self_protected())goto refuse;
  Identity a,b;if(!snapshot((pid_t)r.pid,NULL,&a))goto refuse;r.sec=a.sec;r.usec=a.usec;r.version=a.version;
  if(!snapshot((pid_t)r.pid,NULL,&b)||!identity_policy(&r,&a,&b))goto refuse;
  bounded_output(STDOUT_FILENO,"{\"pid\":%u,\"sec\":%llu,\"usec\":%u,\"version\":%u,\"qmp\":\"%s\"}\n",r.pid,(unsigned long long)r.sec,r.usec,r.version,QMP_PATH);return 0;
 }
 if(argc==7&&!strcmp(argv[1],"--peer")&&ordinary){
  Request fdreq;if(!request_parse(argv[2],"1","0","5",&fdreq)||!request_parse(argv[3],argv[4],argv[5],"120",&r)||!parse_version(argv[6],&r)||!self_protected()||!authenticate_peer((int)fdreq.pid,&r))goto refuse;return 0;
 }
 const char *sudo_uid=getenv("SUDO_UID");
 if(argc!=7||strcmp(argv[1],"--activate")||getuid()!=0||geteuid()!=0||!sudo_uid||strcmp(sudo_uid,PROFILE_UID_TEXT))goto refuse;
 if(PROFILE_FIXTURE)goto refuse;
 if(!request_parse(argv[2],argv[3],argv[4],argv[6],&r)||!parse_version(argv[5],&r)||!self_protected())goto refuse;
 struct stat input;if(fstat(STDIN_FILENO,&input)||!S_ISFIFO(input.st_mode))goto refuse;
 struct rlimit core={0,0};if(setrlimit(RLIMIT_CORE,&core)||chdir("/"))goto refuse;
 struct sigaction sa={0};sigemptyset(&sa.sa_mask);sa.sa_handler=on_signal;
 if(sigaction(SIGINT,&sa,NULL)||sigaction(SIGTERM,&sa,NULL)||sigaction(SIGHUP,&sa,NULL))goto refuse;signal(SIGPIPE,SIG_IGN);
 Runtime runtime={.req=r,.dir=-1,.lock=-1,.manifest=-1,.run=-1,.helper=-1};Ops ops={&runtime,step,clock_now,child_wait};
 int rc=activation_flow(&ops,r.lease);bounded_output(STDERR_FILENO,"activation-exit=%d; USB/HID restoration is not verified by activator\n",rc);return rc;
 refuse:bounded_output(STDERR_FILENO,"refuse: exact installed identity required; no USB initialized\n");return 64;
}
