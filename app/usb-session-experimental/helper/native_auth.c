#include "native_auth.h"
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <bsm/libbsm.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <libproc.h>
#include "darwin_unique.h"
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <limits.h>
int secure_dir(const char *absolute) {
 if(!absolute || absolute[0]!='/' || strlen(absolute)>=PATH_MAX)return -1;
 int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(fd<0)return -1;
 const char *p=absolute+1;
 while(*p){const char *slash=strchr(p,'/');size_t n=slash?(size_t)(slash-p):strlen(p);char part[NAME_MAX+1];
  if(!n || n>NAME_MAX || (n==1 && p[0]=='.') || (n==2 && p[0]=='.' && p[1]=='.')){close(fd);return -1;}
  memcpy(part,p,n);part[n]=0;int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);close(fd);fd=next;
  struct stat st;if(fd<0)return -1;if(fstat(fd,&st) || !protected_node(st.st_uid,st.st_mode,st.st_nlink,1,0)){close(fd);return -1;}
  if(!slash)break;p=slash+1;if(!*p){close(fd);return -1;}
 }
 return fd;
}
int load_manifest(Manifest *m) {
 int dir=secure_dir(MANIFEST_DIR);if(dir<0)return 0;
 int fd=openat(dir,MANIFEST_FILE,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);close(dir);if(fd<0)return 0;
 struct stat a,b;char data[513];int ok=0;ssize_t n;
 if(fstat(fd,&a) || !protected_node(a.st_uid,a.st_mode,a.st_nlink,0,(a.st_flags&(UF_IMMUTABLE|SF_IMMUTABLE))!=0) || a.st_size<=0 || a.st_size>512)goto done;
 n=read(fd,data,sizeof(data));if(n!=a.st_size || fstat(fd,&b) || a.st_ino!=b.st_ino || a.st_dev!=b.st_dev || a.st_size!=b.st_size || a.st_mtimespec.tv_sec!=b.st_mtimespec.tv_sec || a.st_mtimespec.tv_nsec!=b.st_mtimespec.tv_nsec)goto done;
 ok=manifest_parse(data,(size_t)n,m);
 done:close(fd);return ok;
}
int executable_protected(void) {
 static const char full[]="/Library/PrivilegedHelperTools/org.omacvm.usb-session-experimental-helper";
 char path[PROC_PIDPATHINFO_MAXSIZE];if(proc_pidpath(getpid(),path,sizeof(path))<=0 || strcmp(path,full))return 0;
 int d=secure_dir("/Library/PrivilegedHelperTools");if(d<0)return 0;
 int fd=openat(d,"org.omacvm.usb-session-experimental-helper",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);close(d);if(fd<0)return 0;
 struct stat s;int ok=!fstat(fd,&s) && s.st_uid==0 && S_ISREG(s.st_mode) && (s.st_mode&07777)==0555 && s.st_nlink==1 && (s.st_flags&(UF_IMMUTABLE|SF_IMMUTABLE));close(fd);return ok;
}
int peer_auth(int fd,const Manifest *m) {
 if(fd<0 || !m)return 0;
 uid_t uid;gid_t gid;pid_t pid=0;audit_token_t token={0},again={0};socklen_t len=sizeof(token);
 if(getpeereid(fd,&uid,&gid) || uid!=PROFILE_UID || getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&len) || len!=sizeof(token))return 0;
 len=sizeof(pid);if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&len) || len!=sizeof(pid) || pid!=(pid_t)m->pid || audit_token_to_pid(token)!=pid || audit_token_to_euid(token)!=PROFILE_UID || audit_token_to_ruid(token)!=PROFILE_UID)return 0;
 if((uint32_t)audit_token_to_pidversion(token)!=m->version)return 0;
 struct proc_uniqidentifierinfo first={0},last={0};
 if(proc_pidinfo(pid,PROC_PIDUNIQIDENTIFIERINFO,0,&first,sizeof(first))!=sizeof(first) || (uint32_t)first.p_idversion!=m->version)return 0;
 struct proc_bsdinfo before={0},after={0};if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&before,sizeof(before))!=sizeof(before) || before.pbi_uid!=PROFILE_UID || before.pbi_ruid!=PROFILE_UID)return 0;
 CFDataRef data=CFDataCreate(NULL,(const UInt8 *)&token,sizeof(token));if(!data)return 0;
 const void *keys[]={kSecGuestAttributeAudit},*values[]={data};
 CFDictionaryRef attrs=CFDictionaryCreate(NULL,keys,values,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);CFRelease(data);
 SecCodeRef code=NULL;SecStaticCodeRef stat=NULL;CFDictionaryRef info=NULL;int ok=0;
 if(!attrs)return 0;
 if(SecCodeCopyGuestWithAttributes(NULL,attrs,kSecCSDefaultFlags,&code)!=errSecSuccess || SecCodeCheckValidity(code,kSecCSStrictValidate,NULL)!=errSecSuccess || SecCodeCopyStaticCode(code,kSecCSDefaultFlags,&stat)!=errSecSuccess || SecCodeCopySigningInformation(stat,kSecCSSigningInformation,&info)!=errSecSuccess)goto done;
 CFDataRef hash=CFDictionaryGetValue(info,kSecCodeInfoUnique);
 if(!hash || CFGetTypeID(hash)!=CFDataGetTypeID() || CFDataGetLength(hash)!=20)goto done;
 len=sizeof(again);
 if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&again,&len) || len!=sizeof(again) || memcmp(&token,&again,sizeof(token)) || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,sizeof(after))!=sizeof(after) || before.pbi_start_tvsec!=after.pbi_start_tvsec || before.pbi_start_tvusec!=after.pbi_start_tvusec || after.pbi_uid!=PROFILE_UID || after.pbi_ruid!=PROFILE_UID)goto done;
 if(proc_pidinfo(pid,PROC_PIDUNIQIDENTIFIERINFO,0,&last,sizeof(last))!=sizeof(last) || (uint32_t)last.p_idversion!=m->version || first.p_uniqueid!=last.p_uniqueid)goto done;
 ok=peer_policy(m,audit_token_to_ruid(token),audit_token_to_euid(token),(unsigned)pid,before.pbi_start_tvsec,before.pbi_start_tvusec,CFDataGetBytePtr(hash));
 done:if(info)CFRelease(info);if(stat)CFRelease(stat);if(code)CFRelease(code);CFRelease(attrs);return ok;
}
