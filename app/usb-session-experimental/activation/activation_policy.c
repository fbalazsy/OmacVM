#include "activation_policy.h"
#include <stdio.h>
#include <string.h>
#include <limits.h>
static int number(const char *s,uint64_t max,uint64_t *out) {
 if(!s || !*s || (s[0]=='0' && s[1]))return 0;
 uint64_t n=0;for(;*s;s++){if(*s<'0'||*s>'9')return 0;unsigned d=(unsigned)(*s-'0');if(n>(max-d)/10 || d>max)return 0;n=n*10+d;}
 *out=n;return 1;
}
int request_parse(const char *p,const char *s,const char *u,const char *l,Request *out) {
 uint64_t pid,sec,usec,lease;
 if(!out || !number(p,INT_MAX,&pid)||!pid||!number(s,UINT64_MAX,&sec)||!sec||!number(u,999999,&usec)||!number(l,120,&lease)||(lease && lease<5))return 0;
 *out=(Request){.pid=(uint32_t)pid,.usec=(uint32_t)usec,.lease=(uint32_t)lease,.sec=sec};return 1;
}
static int exact(const Request *r,const Identity *i) {
 return i && i->pid==r->pid && i->sec==r->sec && i->usec==r->usec && i->version==r->version && i->uid==PROFILE_UID && i->ruid==PROFILE_UID && i->signature && i->argv && !strcmp(i->path,QEMU_PATH) && !strcmp(i->sha,QEMU_SHA) && !strcmp(i->cdhash,QEMU_CDHASH);
}
int identity_policy(const Request *r,const Identity *a,const Identity *b){return r && exact(r,a) && exact(r,b);}
int manifest_format(const Request *r,char *out,size_t n) {
 if(!r||!out||(r->lease && r->lease<5)||r->lease>120)return 0;
 int k=snprintf(out,n,"BALDUR2\npid=%u\nstart_sec=%llu\nstart_usec=%u\nversion=%u\ncdhash=%s\ndevice=%s\nconfig=%s\nlease=%u\ndeadline_ns=%llu\n",r->pid,(unsigned long long)r->sec,r->usec,r->version,QEMU_CDHASH,DEVICE_HEX,CONFIG_HEX,r->lease,(unsigned long long)r->deadline_ns);
 return k>0 && (size_t)k<n && k<=512;
}
