#include "../io.h"
#include "../security.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <assert.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
int main(void){char dir[104],path[104];assert(getenv("TMPDIR"));assert(snprintf(dir,sizeof(dir),"%s/uex-XXXXXX",getenv("TMPDIR"))<(int)sizeof(dir)-3);assert(mkdtemp(dir));snprintf(path,sizeof(path),"%s/s",dir);SocketOwner listener={.fd=-1};assert(socket_create(&listener,path,getuid()));
 pid_t child=fork();assert(child>=0);if(!child){close(listener.fd);int fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un a={.sun_family=AF_UNIX};strlcpy(a.sun_path,path,sizeof(a.sun_path));assert(!connect(fd,(struct sockaddr *)&a,sizeof(a)));assert(write(fd,"R",1)==1);char b;assert(read(fd,&b,1)==1);execl("/bin/sleep","sleep","5",NULL);_exit(9);}
 int peer=-1;for(unsigned i=0;i<1000&&peer<0;i++){peer=accept(listener.fd,NULL,NULL);if(peer<0)usleep(1000);}assert(peer>=0);char b;assert(read(peer,&b,1)==1);Process before,after;ProcessSeal seal;assert(process_read(child,&before));assert(peer_matches(peer,&before));assert(seal_process(&before,&seal));assert(write(peer,"G",1)==1);
 int changed=0;for(unsigned i=0;i<1000;i++){if(process_read(child,&after)&&after.version!=before.version){changed=1;break;}usleep(1000);}assert(changed);assert(after.pid==before.pid&&after.sec==before.sec&&after.usec==before.usec);assert(!peer_matches(peer,&before));/* Darwin may refresh LOCAL_PEERTOKEN on exec. Production never replaces the original expected identity. */assert(!seal_live(&seal));assert(!kill(child,SIGTERM));int status;assert(waitpid(child,&status,0)==child);close(peer);assert(socket_remove(&listener));assert(!rmdir(dir));puts("exec PASS: real same-PID exec revokes the original expected peer generation and executable snapshot");return 0;}
