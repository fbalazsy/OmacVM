/* Real ordinary-user socket/child regression; never production entrypoints. */
#define main forbidden_entry
#include "../activation/activation_native.c"
#undef main
#include <assert.h>
#include <sys/un.h>
static Runtime fresh(int dir){Runtime r={.dir=-1,.lock=-1,.manifest=-1,.helper=-1,.run=dup(dir)};return r;}
int main(void){
 assert(getuid()!=0 && geteuid()!=0);
 const char *path="."; /* relative AF_UNIX name in owned fixture cwd */
 int dir=open(".",O_RDONLY|O_DIRECTORY);assert(dir>=0);
 Runtime r=fresh(dir);
#ifdef BALDUR_SUPERVISED_SOCKET
 assert(!session_socket_create(&r.socket,r.run,"usb.sock",path,getuid(),getgid()));
#endif
#ifdef BALDUR_SUPERVISED_SOCKET
 r.spawned=1;
#endif
 r.child=fork();assert(r.child>=0);if(!r.child){
#ifndef BALDUR_SUPERVISED_SOCKET
 /* Old helper creates and then exits abnormally before socket_cleanup. */
 int fd=socket(AF_UNIX,SOCK_STREAM,0);assert(fd>=0);struct sockaddr_un a={0};a.sun_family=AF_UNIX;
 assert(snprintf(a.sun_path,sizeof(a.sun_path),"%s/usb.sock",path)<(int)sizeof(a.sun_path));
 assert(!bind(fd,(struct sockaddr *)&a,sizeof(a)));close(fd);
#endif
 _exit(23);}
 ChildResult w;do {w=child_wait(&r);usleep(1000);}while(w.kind==CHILD_RUNNING);
 assert(w.kind==CHILD_REAPED && w.status==23 && !r.child);
 assert(!step(&r,CLEAN));
 struct stat st;assert(fstatat(dir,"usb.sock",&st,AT_SYMLINK_NOFOLLOW)<0 && errno==ENOENT);
 close(dir);puts("PASS abnormal native child reap cleans exact owned AF_UNIX inode");return 0;
}
