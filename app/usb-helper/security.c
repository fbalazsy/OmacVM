#include "security.h"
#include <libproc.h>
#include <sys/acl.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <limits.h>
#include <CommonCrypto/CommonDigest.h>
#define ROOT_PATH "/Library/PrivilegedHelperTools/org.omacvm.usb"
static int same_stat(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_size==b->st_size&&a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;}
int seal_process(const Process *expected,ProcessSeal *s){
 Process p,q;if(!process_read(expected->pid,&p)||!process_equal(expected,&p))return 0;
 memset(s,0,sizeof(*s));if(proc_pidpath(p.pid,s->path,sizeof(s->path))<=0)return 0;
 int fd=open(s->path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);if(fd<0)return 0;int ok=!fstat(fd,&s->st)&&S_ISREG(s->st.st_mode);close(fd);
 if(!ok||!process_read(p.pid,&q)||!process_equal(&p,&q))return 0;s->process=p;return 1;
}
int seal_live(const ProcessSeal *s){ProcessSeal a;return seal_process(&s->process,&a)&&!strcmp(a.path,s->path)&&same_stat(&a.st,&s->st);}
static int acl_safe(int fd){
 acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);if(!acl)return errno==ENOENT;
 acl_entry_t e;int rc=acl_get_entry(acl,ACL_FIRST_ENTRY,&e),ok=1;
 /* Darwin returns 0 for an entry and -1/EINVAL for end, unlike Linux's 1/0. */
 while(rc==0){acl_tag_t tag;if(acl_get_tag_type(e,&tag)||tag!=ACL_EXTENDED_DENY){ok=0;break;}rc=acl_get_entry(acl,ACL_NEXT_ENTRY,&e);}
 if(rc<0&&errno!=EINVAL&&errno!=ENOENT)ok=0;acl_free(acl);return ok;
}
int secure_directory(const char *path,uid_t owner){
 if(!path||path[0]!='/'||strlen(path)>=PATH_MAX)return -1;int fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 const char *p=path+1;while(*p){const char *slash=strchr(p,'/');size_t n=slash?(size_t)(slash-p):strlen(p);char part[NAME_MAX+1];
  if(!n||n>NAME_MAX||(n==1&&p[0]=='.')||(n==2&&p[0]=='.'&&p[1]=='.')){close(fd);return -1;}memcpy(part,p,n);part[n]=0;
  int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(fd);fd=next;if(fd<0)return -1;struct stat s;
  if(fstat(fd,&s)||s.st_uid!=owner||(s.st_mode&0022)||!acl_safe(fd)){close(fd);return -1;}
  if(!slash)break;p=slash+1;if(!*p){close(fd);return -1;}
 }return fd;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int self_protected(char path[4096]){
 if(proc_pidpath(getpid(),path,4096)<=0)return 0;
 const char *prefix=ROOT_PATH "/releases/";size_t n=strlen(prefix);if(strncmp(path,prefix,n)||strlen(path)!=n+64+strlen("/omacvm-usb-helper"))return 0;
 const char *sha=path+n;for(unsigned i=0;i<64;i++)if(!((sha[i]>='0'&&sha[i]<='9')||(sha[i]>='a'&&sha[i]<='f')))return 0;
 if(strcmp(sha+64,"/omacvm-usb-helper"))return 0;char directory[4096];memcpy(directory,path,n+64);directory[n+64]=0;
 int d=secure_directory(directory,0);if(d<0)return 0;int fd=openat(d,"omacvm-usb-helper",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);close(d);if(fd<0)return 0;
 struct stat a,b;int ok=!fstat(fd,&a)&&S_ISREG(a.st_mode)&&a.st_uid==0&&(a.st_mode&07777)==0555&&a.st_nlink==1&&a.st_size>0&&a.st_size<64*1024*1024&&acl_safe(fd);
 CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char buf[65536],digest[32];ssize_t got=0;off_t total=0;
 if(ok){while((got=read(fd,buf,sizeof(buf)))>0){total+=got;if(total>a.st_size){ok=0;break;}CC_SHA256_Update(&ctx,buf,(CC_LONG)got);}if(got<0||total!=a.st_size||fstat(fd,&b)||!same_stat(&a,&b))ok=0;}
 CC_SHA256_Final(digest,&ctx);close(fd);if(!ok)return 0;static const char hex[]="0123456789abcdef";
 for(unsigned i=0;i<32;i++)if(sha[i*2]!=hex[digest[i]>>4]||sha[i*2+1]!=hex[digest[i]&15])return 0;return 1;
}
#pragma clang diagnostic pop
