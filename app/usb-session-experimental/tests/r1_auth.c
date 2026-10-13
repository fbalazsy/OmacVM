/* Actual peer_auth with fake peer/process syscalls; signing uses own test image only.
 * No socket creation, no helper main, no USB. */
#include <Security/Security.h>
#include <sys/socket.h>
#include <libproc.h>
#include <bsm/libbsm.h>
#include <unistd.h>
#include <assert.h>
#include <string.h>
#include "../helper/darwin_unique.h"
static unsigned token_version=7,live_version=7,proc_calls,exec_during;
static int f_peer(int fd,uid_t *u,gid_t *g){assert(fd==99);*u=4242;*g=20;return 0;}
static int f_sock(int fd,int level,int opt,void *out,socklen_t *len){
 (void)level;assert(fd==99);
 if(opt==LOCAL_PEERPID){*(pid_t *)out=123;*len=sizeof(pid_t);return 0;}
 assert(opt==LOCAL_PEERTOKEN);audit_token_t t={{0,4242,20,4242,20,123,0,token_version}};memcpy(out,&t,sizeof t);*len=sizeof t;return 0;
}
static int f_proc(int pid,int flavor,uint64_t arg,void *out,int size){
 (void)arg;assert(pid==123);memset(out,0,(size_t)size);
 if(flavor==PROC_PIDTBSDINFO){struct proc_bsdinfo *b=out;b->pbi_uid=b->pbi_ruid=4242;b->pbi_start_tvsec=456;b->pbi_start_tvusec=789;}
 else {assert(flavor==PROC_PIDUNIQIDENTIFIERINFO);struct proc_uniqidentifierinfo *u=out;u->p_uniqueid=42;u->p_idversion=live_version+(exec_during && proc_calls++>0);}
 return size;
}
static OSStatus f_guest(SecCodeRef host,CFDictionaryRef attrs,SecCSFlags flags,SecCodeRef *code){(void)host;(void)attrs;(void)flags;return SecCodeCopySelf(0,code);}
#define getpeereid f_peer
#define getsockopt f_sock
#define proc_pidinfo f_proc
#define SecCodeCopyGuestWithAttributes f_guest
#include "../helper/native_auth.c"
int main(void){
 Manifest m={.pid=123,.sec=456,.usec=789,.version=7};
 SecCodeRef c=NULL;SecStaticCodeRef s=NULL;CFDictionaryRef info=NULL;
 assert(!SecCodeCopySelf(0,&c));assert(!SecCodeCopyStaticCode(c,0,&s));assert(!SecCodeCopySigningInformation(s,kSecCSSigningInformation,&info));
 CFDataRef h=CFDictionaryGetValue(info,kSecCodeInfoUnique);assert(h&&CFDataGetLength(h)==20);memcpy(m.cdhash,CFDataGetBytePtr(h),20);
 CFRelease(info);CFRelease(s);CFRelease(c);
 assert(peer_auth(99,&m));
 token_version=live_version=8;assert(!peer_auth(99,&m)); /* reexec after REAUTH, before accept */
 token_version=7;assert(!peer_auth(99,&m)); /* old socket token, live process reexec during traffic */
 live_version=7;exec_during=1;proc_calls=0;assert(!peer_auth(99,&m)); /* interleaving inside auth */
 puts("PASS R1 actual auth: accept/ongoing same-PID same-build exec rejected, including stale socket token");
}
