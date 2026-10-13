/* Real user fork/exec/AF_UNIX/reap; only exec target replaced with this fixture.
 * Never root, USB, proc inspection, production entrypoints or live QMP. */
#include <unistd.h>
#include <assert.h>
static char executable[1024];static const char *fixture_mode;static int supervise,cancel_write=-1;
static int fixture_exec(const char *,char *const [],char *const []);
#define execve fixture_exec
#define main forbidden_entry
#include "../activation/activation_native.c"
#undef main
#undef execve
static int fixture_exec(const char *path,char *const args[],char *const env[]){
 assert(!strcmp(path,HELPER) && !strcmp(args[1],"--serve"));
 char *const av[]={executable,"--fixture",(char *)fixture_mode,NULL};
 return execve(executable,av,env);
}
static Runtime fresh(void){return (Runtime){.dir=-1,.lock=-1,.manifest=-1,.helper=-1,.run=open(".",O_RDONLY|O_DIRECTORY)};}
static ChildResult reap(Runtime *r){
 ChildResult w;unsigned attempts=0;
 do{w=child_wait(r);usleep(1000);assert(++attempts<10000);}while(w.kind==CHILD_RUNNING);
 assert(w.kind==CHILD_REAPED && !r->child);return w;
}
static void create(Runtime *r){assert(r->run>=0);assert(!session_socket_create(&r->socket,r->run,"usb.sock",".",getuid(),getgid()));}
static void absent(void){struct stat st;assert(lstat("usb.sock",&st)<0 && errno==ENOENT);}
static int offline_step(void *ctx,Stage s){
 if(supervise){
  if(s==AUTH||s==PREPARE||s==PUBLISH||s==REAUTH)return 0;
  if(s==READY){assert(!close(cancel_write));cancel_write=-1;}
  return step(ctx,s);
 }
 if(s==AUTH||s==PREPARE||s==PUBLISH||s==REAUTH||s==SPAWN||s==READY||s==CANCEL)return 0;
 if(s==EXEC_ACK)return 1;
 return step(ctx,s);
}
int main(int argc,char **argv){
 assert(getuid()!=0 && geteuid()!=0);alarm(30);
 if(argc==3 && !strcmp(argv[1],"--fixture")){
  int valid=session_socket_validate(3,"./usb.sock",getuid());
  if(valid){struct stat st={0};struct sockaddr_un a={0};socklen_t n=sizeof(a);int fs=fstat(3,&st),gs=getsockname(3,(struct sockaddr *)&a,&n);dprintf(1,"fixture validation=%d fstat=%d mode=%o getsockname=%d path=%s errno=%d\n",valid,fs,st.st_mode,gs,a.sun_path,errno);}
  assert(!valid);
  if(!strcmp(argv[2],"hang")){for(;;)pause();}
  return atoi(argv[2]);
 }
 assert(realpath(argv[0],executable));
 const char *modes[]={"0","1","23","124","hang","hang"};
 for(unsigned i=0;i<sizeof(modes)/sizeof(modes[0]);i++){
  Runtime r=fresh();create(&r);fixture_mode=modes[i];
  assert(!step(&r,SPAWN));int ack;
  do{ack=step(&r,EXEC_ACK);usleep(1000);}while(!ack);
  assert(ack==1 && r.spawned && r.child>0);
  assert(step(&r,CLEAN)<0);assert(!access("usb.sock",F_OK));
  if(i>=4){usleep(30000);assert(!step(&r,i==4?TERM:KILL));}
  ChildResult w=reap(&r);assert(w.status==(i==4?143:i==5?137:atoi(modes[i])));
  assert(r.child_status==w.status && r.reaped);assert(!step(&r,CLEAN));absent();
 }
 /* Real cancellation-pipe EOF drives production flow TERM/reap/cleanup. */
 int input=dup(STDIN_FILENO),control[2];assert(input>=0 && !pipe(control));
 assert(dup2(control[0],STDIN_FILENO)==STDIN_FILENO);close(control[0]);cancel_write=control[1];
 Runtime stopped_runtime=fresh();create(&stopped_runtime);fixture_mode="hang";supervise=1;
 Ops stopped_ops={&stopped_runtime,offline_step,clock_now,child_wait};
 assert(activation_flow(&stopped_ops,0)==1);assert(stopped_runtime.reaped && stopped_runtime.child_status==143);absent();
 assert(dup2(input,STDIN_FILENO)==STDIN_FILENO);close(input);supervise=0;
 /* Exact old inode retained under another name; replacement must not be unlinked. */
 Runtime r=fresh();create(&r);assert(!rename("usb.sock","retained.sock"));
 SessionSocket other={0};assert(!session_socket_create(&other,r.run,"usb.sock",".",getuid(),getgid()));
 assert(step(&r,CLEAN)<0);assert(!access("usb.sock",F_OK));
 r.lock=open("activation.lock",O_CREAT|O_EXCL|O_RDWR,0600);assert(r.lock>=0);assert(!flock(r.lock,LOCK_EX|LOCK_NB));
 r.child=fork();assert(r.child>=0);if(!r.child)_exit(1);r.spawned=1;
 Ops ops={&r,offline_step,clock_now,child_wait};assert(activation_flow(&ops,0)==125);
 char marker[32]={0};assert(pread(r.lock,marker,sizeof(marker)-1,0)>0);assert(!strcmp(marker,"UNCONFIRMED\n"));
 assert(!access("usb.sock",F_OK) && !access("retained.sock",F_OK));
 int contender=open("activation.lock",O_RDWR);assert(contender>=0);assert(flock(contender,LOCK_EX|LOCK_NB)<0 && errno==EWOULDBLOCK);close(contender);
 assert(!session_socket_clean(&other,r.run,"usb.sock",0));assert(!unlink("retained.sock"));
 close(r.run);close(r.lock);assert(!unlink("activation.lock"));
 /* Unknown inode and preoccupied name are never adopted or deleted. */
 r=fresh();create(&r);r.socket.known=0;assert(step(&r,CLEAN)<0);
 SessionSocket refused={0};assert(session_socket_create(&refused,r.run,"usb.sock",".",getuid(),getgid())<0);
 assert(!session_socket_clean(&refused,r.run,"usb.sock",0));assert(!access("usb.sock",F_OK));
 assert(!unlink("usb.sock"));close(r.run);
 /* A symlink replacement remains untouched. */
 r=fresh();create(&r);assert(!rename("usb.sock","retained.sock"));assert(!symlink("retained.sock","usb.sock"));
 assert(step(&r,CLEAN)<0);struct stat st;assert(!lstat("usb.sock",&st) && S_ISLNK(st.st_mode));
 assert(!unlink("usb.sock") && !unlink("retained.sock"));close(r.run);
 /* Missing own socket is safe only after reap; wrong inherited descriptor rejected. */
 r=fresh();create(&r);assert(session_socket_validate(r.run,"./usb.sock",getuid())<0);
 assert(session_socket_validate(r.socket.fd,"./wrong.sock",getuid())<0);
 assert(!unlink("usb.sock"));assert(!step(&r,CLEAN));absent();
 alarm(0);puts("PASS native real handoff/reap statuses 0,1,23,124,143,137; EOF cancellation; reconnect; live-child refusal; replaced/unknown/symlink quarantine; inherited-fd guards");
}
