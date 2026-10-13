#pragma once
/* Included by activation_native.c and offline native_test.c. No USB linkage. */
#include "activation_policy.h"
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <bsm/libbsm.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include "darwin_unique.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/acl.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int secure_metadata(const struct stat *s,mode_t mode,int immutable) {
 return s->st_uid==0 && S_ISREG(s->st_mode) && (s->st_mode&07777)==mode && s->st_nlink==1 && (!immutable || (s->st_flags&UF_IMMUTABLE));
}
int no_acl(int fd) {
 acl_t a=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);if(!a){int saved=errno;struct stat st;return saved==ENOENT && !fstat(fd,&st);}
 acl_entry_t entry;int which=ACL_FIRST_ENTRY,ok=1,n;
 while((n=acl_get_entry(a,which,&entry))==0){acl_tag_t tag;which=ACL_NEXT_ENTRY;if(acl_get_tag_type(entry,&tag)||tag!=ACL_EXTENDED_DENY){ok=0;break;}}
 if(n<0 && errno!=EINVAL && errno!=ENOENT)ok=0;acl_free(a);return ok;
}
int secure_dir(const char *path) {
 if(!path || *path!='/' || strlen(path)>=PATH_MAX)return -1;
 int fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 const char *p=path+1;
 for(;;){struct stat s;if(fstat(fd,&s) || s.st_uid || !S_ISDIR(s.st_mode) || (s.st_mode&0022) || !no_acl(fd)){close(fd);return -1;}
  if(!*p)return fd;
  const char *slash=strchr(p,'/');size_t n=slash?(size_t)(slash-p):strlen(p);char name[NAME_MAX+1];
  if(!n || n>NAME_MAX || (n==1&&p[0]=='.') || (n==2&&!memcmp(p,"..",2))){close(fd);return -1;}
  memcpy(name,p,n);name[n]=0;int next=openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(fd);if(next<0)return -1;fd=next;p+=n;if(*p)p++;
 }
}
int protected_file(int dir,const char *name,mode_t mode,int imm) {
 int fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 struct stat s;if(fstat(fd,&s)||!secure_metadata(&s,mode,imm)||!no_acl(fd)){close(fd);errno=EACCES;return -1;}return fd;
}
int same_file(const struct stat *a,const struct stat *b) {
 return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_size==b->st_size && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec && a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
int hash_fd(int fd,char out[65]) {
 struct stat a,b;unsigned char bytes[65536],digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_CTX ctx;
 if(fstat(fd,&a)||!S_ISREG(a.st_mode)||lseek(fd,0,SEEK_SET)<0 || !CC_SHA256_Init(&ctx))return 0;
 ssize_t n;while((n=read(fd,bytes,sizeof(bytes)))>0)if(!CC_SHA256_Update(&ctx,bytes,(CC_LONG)n))return 0;
 if(n<0||fstat(fd,&b)||!same_file(&a,&b)||!CC_SHA256_Final(digest,&ctx))return 0;
 for(unsigned i=0;i<sizeof(digest);i++)snprintf(out+i*2,3,"%02x",digest[i]);return 1;
}
int argv_policy(int argc,const char *const *args) {
 static const char *const expected[]=PROFILE_ARGV;
 if(!args || argc!=(int)(sizeof(expected)/sizeof(expected[0])))return 0;
 for(int i=0;i<argc;i++)if(!args[i] || strcmp(args[i],expected[i]))return 0;
 int name=0,qmp=0,disk=0,fast=0;
 for(int i=1;i<argc;i++){
  if(!strcmp(args[i],"-name")){if(++i>=argc || strcmp(args[i],VM_NAME) || name++)return 0;}
  else if(!strcmp(args[i],"-qmp")){if(++i>=argc || strcmp(args[i],QMP_ARG) || qmp++)return 0;}
  else if(!strcmp(args[i],"-drive")){if(++i>=argc)return 0;if(!strcmp(args[i],DISK_ARG))disk++;}
  else if(!strcmp(args[i],"-netdev")){if(++i>=argc || strcmp(args[i],FAST_ARG) || fast++)return 0;}
 }
 return name==1 && qmp==1 && disk==1 && fast==1;
}
int procargs_policy(const char *buf,size_t len) {
 if(len<=sizeof(int))return 0;int argc;memcpy(&argc,buf,sizeof(argc));if(argc<1||argc>4096)return 0;
 const char *p=buf+sizeof(int),*end=buf+len,*z=memchr(p,0,(size_t)(end-p));if(!z)return 0;
 p=z+1;while(p<end&&!*p)p++;
 const char *args[4096];for(int i=0;i<argc;i++){if(p>=end)return 0;args[i]=p;z=memchr(p,0,(size_t)(end-p));if(!z)return 0;p=z+1;}
 return argv_policy(argc,args);
}
int process_args(pid_t pid) {
 int mib[]={CTL_KERN,KERN_PROCARGS2,pid};size_t len=262144;char *buf=malloc(len);if(!buf)return 0;
 int ok=!sysctl(mib,3,buf,&len,NULL,0) && procargs_policy(buf,len);free(buf);return ok;
}
int signing(pid_t pid,const audit_token_t *token,char hex[41]) {
 CFTypeRef value=token?(CFTypeRef)CFDataCreate(NULL,(const UInt8 *)token,sizeof(*token)):(CFTypeRef)CFNumberCreate(NULL,kCFNumberIntType,&pid);
 if(!value)return 0;const void *keys[]={token?kSecGuestAttributeAudit:kSecGuestAttributePid},*vals[]={value};
 CFDictionaryRef attrs=CFDictionaryCreate(NULL,keys,vals,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);CFRelease(value);if(!attrs)return 0;
 SecCodeRef code=NULL;SecStaticCodeRef stat=NULL;CFDictionaryRef info=NULL;int ok=0;
 if(SecCodeCopyGuestWithAttributes(NULL,attrs,kSecCSDefaultFlags,&code)!=errSecSuccess || SecCodeCheckValidity(code,kSecCSStrictValidate,NULL)!=errSecSuccess || SecCodeCopyStaticCode(code,kSecCSDefaultFlags,&stat)!=errSecSuccess || SecStaticCodeCheckValidity(stat,kSecCSStrictValidate|kSecCSCheckAllArchitectures,NULL)!=errSecSuccess || SecCodeCopySigningInformation(stat,kSecCSSigningInformation,&info)!=errSecSuccess)goto done;
 CFDataRef hash=CFDictionaryGetValue(info,kSecCodeInfoUnique);if(!hash || CFGetTypeID(hash)!=CFDataGetTypeID() || CFDataGetLength(hash)!=20)goto done;
 const UInt8 *bytes=CFDataGetBytePtr(hash);for(unsigned i=0;i<20;i++)snprintf(hex+i*2,3,"%02x",bytes[i]);
 ok=SecCodeCheckValidity(code,kSecCSStrictValidate,NULL)==errSecSuccess;
 done:if(info)CFRelease(info);if(stat)CFRelease(stat);if(code)CFRelease(code);CFRelease(attrs);return ok;
}
int snapshot(pid_t pid,const audit_token_t *token,Identity *i) {
 memset(i,0,sizeof(*i));struct proc_bsdinfo b={0},after={0};struct proc_uniqidentifierinfo u={0},v={0};
 if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b) || b.pbi_uid!=PROFILE_UID || b.pbi_ruid!=PROFILE_UID || proc_pidinfo(pid,PROC_PIDUNIQIDENTIFIERINFO,0,&u,sizeof(u))!=sizeof(u))return 0;
 char actual[PROC_PIDPATHINFO_MAXSIZE],resolved[PATH_MAX],alias[PATH_MAX];
 if(proc_pidpath(pid,actual,sizeof(actual))<=0 || (strcmp(actual,QEMU_PATH)&&strcmp(actual,QEMU_REAL)) || !realpath(actual,resolved) || strcmp(resolved,QEMU_REAL) || !realpath(QEMU_PATH,alias) || strcmp(alias,QEMU_REAL))return 0;
 int fd=open(QEMU_REAL,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return 0;struct stat a,c;
 int ok=!fstat(fd,&a) && hash_fd(fd,i->sha) && !stat(QEMU_REAL,&c) && same_file(&a,&c);close(fd);if(!ok)return 0;
 i->pid=(uint32_t)pid;i->uid=b.pbi_uid;i->ruid=b.pbi_ruid;i->sec=b.pbi_start_tvsec;i->usec=b.pbi_start_tvusec;i->version=u.p_idversion;
 strcpy(i->path,QEMU_PATH);i->argv=process_args(pid);i->signature=signing(pid,token,i->cdhash);
 if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,sizeof(after))!=sizeof(after) || proc_pidinfo(pid,PROC_PIDUNIQIDENTIFIERINFO,0,&v,sizeof(v))!=sizeof(v))return 0;
 return b.pbi_start_tvsec==after.pbi_start_tvsec && b.pbi_start_tvusec==after.pbi_start_tvusec && after.pbi_uid==PROFILE_UID && after.pbi_ruid==PROFILE_UID && u.p_uniqueid==v.p_uniqueid && u.p_idversion==v.p_idversion;
}
int authenticate(const Request *r,const audit_token_t *token) {
 Identity a,b;return snapshot((pid_t)r->pid,token,&a) && snapshot((pid_t)r->pid,token,&b) && identity_policy(r,&a,&b);
}
int authenticate_peer(int fd,const Request *r) {
 uid_t uid;gid_t gid;pid_t pid; socklen_t len=sizeof(pid);audit_token_t a,b;
 if(getpeereid(fd,&uid,&gid)||uid!=PROFILE_UID||getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&len)||len!=sizeof(pid)||pid!=(pid_t)r->pid)return 0;
 len=sizeof(a);if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&a,&len)||len!=sizeof(a)||audit_token_to_pid(a)!=pid||audit_token_to_euid(a)!=PROFILE_UID||audit_token_to_ruid(a)!=PROFILE_UID||(uint32_t)audit_token_to_pidversion(a)!=r->version||!authenticate(r,&a))return 0;
 len=sizeof(b);return !getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&b,&len) && len==sizeof(b) && !memcmp(&a,&b,sizeof(a));
}
