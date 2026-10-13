/* OFFLINE ONLY: real workspace file IO, FAKE root ownership/immutable flags.
   Includes actual publication/cleanup functions, NEVER invokes activation main. */
#include "native_platform.c"
#include <assert.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
static int flags_by_fd[4096],fail_rename,fail_freeze,short_write,freeze_calls;
static int fake_fstat(int fd,struct stat *st){int rc=fstat(fd,st);if(!rc){st->st_uid=0;st->st_flags=flags_by_fd[fd];}return rc;}
static int fake_flags(int fd,unsigned flags){freeze_calls++;if(fail_freeze&&flags){errno=EPERM;return -1;}flags_by_fd[fd]=(int)flags;return 0;}
static int fake_protected(int dir,const char *name,mode_t mode,int immutable){int fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;struct stat s;if(fstat(fd,&s)||!S_ISREG(s.st_mode)||(s.st_mode&07777)!=mode||s.st_nlink!=1){close(fd);errno=EACCES;return -1;}flags_by_fd[fd]=immutable?UF_IMMUTABLE:0;return fd;}
static int fake_rename(int a,const char *s,int b,const char *t){if(fail_rename){errno=EIO;return -1;}return renameat(a,s,b,t);}
static ssize_t fake_write(int fd,const void *buf,size_t n){return write(fd,buf,short_write?n-1:n);}
#define fstat fake_fstat
#define fchflags fake_flags
#define protected_file fake_protected
#define renameat fake_rename
#define write fake_write
#define main never_run_activation_main
#include "activation_native.c"
#undef main
#undef write
#undef renameat
#undef protected_file
#undef fchflags
#undef fstat
static void one(int old,int rename_failure,int freeze_failure,int write_failure) {
 char path[]="build/manifest-fake-XXXXXX";assert(mkdtemp(path));int dir=open(path,O_RDONLY|O_DIRECTORY);assert(dir>=0);
 if(old){int fd=openat(dir,"peer.conf",O_WRONLY|O_CREAT|O_EXCL,0400);assert(fd>=0);assert(write(fd,"STALE\n",6)==6);close(fd);}
 Runtime r={.req={.pid=12345,.sec=1000000000,.usec=1,.lease=120},.dir=dir,.manifest=-1,.helper=-1,.run=-1,.lock=-1};
 memset(flags_by_fd,0,sizeof(flags_by_fd));fail_rename=rename_failure;fail_freeze=freeze_failure;short_write=write_failure;freeze_calls=0;
 clock_now(&r);int rc=publish(&r);if((rc==0)!=(!rename_failure&&!freeze_failure&&!write_failure))fprintf(stderr,"manifest case old=%d rename=%d freeze=%d write=%d rc=%d errno=%d temp=%d published=%d flags=%d acl=%d\n",old,rename_failure,freeze_failure,write_failure,rc,errno,r.temp,r.published,flags_by_fd[r.manifest],no_acl(r.manifest));assert((rc==0)==(!rename_failure&&!freeze_failure&&!write_failure));
 if(!rc){assert(r.published&&!r.temp);assert(flags_by_fd[r.manifest]==UF_IMMUTABLE);int fd=openat(dir,"peer.conf",O_RDONLY);char got[513]={0},want[513];assert(fd>=0);assert(read(fd,got,512)>0);close(fd);assert(manifest_format(&r.req,want,sizeof(want)));assert(!strcmp(got,want));}
 fail_freeze=0;assert(cleanup_manifest(&r)==0);
 dir=open(path,O_RDONLY|O_DIRECTORY);assert(dir>=0);
 if(old && (rename_failure||write_failure)){int fd=openat(dir,"peer.conf",O_RDONLY);assert(fd>=0);char data[7]={0};assert(read(fd,data,6)==6&&!strcmp(data,"STALE\n"));close(fd);assert(!unlinkat(dir,"peer.conf",0));}
 else {struct stat st;assert(fstatat(dir,"peer.conf",&st,AT_SYMLINK_NOFOLLOW)<0&&errno==ENOENT);}
 struct stat st;assert(fstatat(dir,".peer.next",&st,AT_SYMLINK_NOFOLLOW)<0&&errno==ENOENT);close(dir);assert(!rmdir(path));
}
int main(void){
 for(int old=0;old<2;old++){one(old,0,0,0);one(old,1,0,0);one(old,0,1,0);one(old,0,0,1);}
 /* Mismatched cleanup inode must leave replacement untouched. */
 char path[]="build/manifest-fake-XXXXXX";assert(mkdtemp(path));int dir=open(path,O_RDONLY|O_DIRECTORY);assert(dir>=0);
 Runtime r={.req={.pid=12345,.sec=1,.lease=5},.dir=dir,.manifest=-1,.helper=-1,.run=-1,.lock=-1};short_write=fail_rename=fail_freeze=0;
 clock_now(&r);assert(!publish(&r));assert(!renameat(dir,"peer.conf",dir,"ours"));int replacement=openat(dir,"peer.conf",O_CREAT|O_WRONLY|O_EXCL,0400);assert(replacement>=0);close(replacement);
 assert(cleanup_manifest(&r)<0);dir=open(path,O_RDONLY|O_DIRECTORY);assert(dir>=0);assert(!unlinkat(dir,"peer.conf",0));assert(!unlinkat(dir,"ours",0));close(dir);assert(!rmdir(path));
 puts("PASS actual manifest transaction with FAKE root/immutability: replace, short write, rename/freeze failures, inode-specific cleanup; no root operations");
}
