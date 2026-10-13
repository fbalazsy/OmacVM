/* OFFLINE: fake metadata/argv; actual FD operations only on this workspace. */
#include "native_platform.c"
#include <assert.h>
int main(void) {
 errno=ENOENT;int here=open(".",O_RDONLY|O_DIRECTORY);assert(here>=0);
 assert(protected_file(here,"native_test.c",0555,1)<0);assert(errno==EACCES);close(here);
 struct stat st={.st_uid=0,.st_mode=S_IFREG|0555,.st_nlink=1,.st_flags=UF_IMMUTABLE};
 assert(secure_metadata(&st,0555,1));st.st_uid=4242;assert(!secure_metadata(&st,0555,1));st.st_uid=0;
 st.st_mode=S_IFREG|0755;assert(!secure_metadata(&st,0555,1));st.st_mode=S_IFLNK|0555;assert(!secure_metadata(&st,0555,1));st.st_mode=S_IFREG|0555;
 st.st_nlink=2;assert(!secure_metadata(&st,0555,1));st.st_nlink=1;st.st_flags=0;assert(!secure_metadata(&st,0555,1));
 assert(secure_dir("/nonexistent/fixture-owned-path")<0);
 const char *ok[]={QEMU_PATH,"-name","OmacVM Fixture","-qmp",QMP_ARG,"-drive",DISK_ARG,"-netdev",FAST_ARG};
 assert(argv_policy(9,ok));const char *wrong[11];memcpy(wrong,ok,sizeof(ok));wrong[2]="Other";assert(!argv_policy(9,wrong));
 memcpy(wrong,ok,sizeof(ok));wrong[9]="-qmp";wrong[10]=QMP_ARG;assert(!argv_policy(11,wrong));
 memcpy(wrong,ok,sizeof(ok));wrong[8]="user,id=fast";assert(!argv_policy(9,wrong));
 memcpy(wrong,ok,sizeof(ok));wrong[9]="-snapshot";assert(!argv_policy(10,wrong));
 char buf[4096];int argc=9;memcpy(buf,&argc,sizeof(argc));size_t pos=sizeof(argc);memcpy(buf+pos,QEMU_REAL,sizeof(QEMU_REAL));pos+=sizeof(QEMU_REAL);buf[pos++]=0;
 for(int i=0;i<9;i++){size_t n=strlen(ok[i])+1;memcpy(buf+pos,ok[i],n);pos+=n;}
 assert(procargs_policy(buf,pos));assert(!procargs_policy(buf,pos-1));assert(!procargs_policy(buf,2));
 argc=1000000;memcpy(buf,&argc,sizeof(argc));assert(!procargs_policy(buf,pos));
 puts("PASS native OFFLINE: metadata/symlinks/hardlinks, protected ancestry, exact argv, truncated procargs; no VM/USB APIs invoked");
}
