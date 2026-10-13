#include "policy.h"
#include <string.h>
#include <sys/stat.h>
static int literal(const char **p,const char *end,const char *s) {
 size_t n=strlen(s);if((size_t)(end-*p)<n || memcmp(*p,s,n))return 0;*p+=n;return 1;
}
static int decimal(const char **p,const char *end,uint64_t max,uint64_t *out) {
 if(*p==end || **p<'0' || **p>'9')return 0;
 const char *start=*p;uint64_t v=0;
 while(*p<end && **p>='0' && **p<='9') {unsigned d=(unsigned)(**p-'0');if(v>(max-d)/10 || d>max)return 0;v=v*10+d;(*p)++;}
 if(*p-start>1 && *start=='0')return 0;*out=v;return literal(p,end,"\n");
}
static int hexbytes(const char **p,const char *end,unsigned char *out,size_t n) {
 if((size_t)(end-*p)<n*2)return 0;
 memset(out,0,n);
 for(size_t i=0;i<n*2;i++){unsigned char c=(unsigned char)*(*p)++;unsigned v;
  if(c>='0' && c<='9')v=c-'0';else if(c>='a' && c<='f')v=c-'a'+10;else return 0;
  out[i/2]|=(uint8_t)(v<<((1-i%2)*4));
 }return 1;
}
int manifest_parse(const char *s,size_t n,Manifest *out) {
 if(!s || !out || n>512 || memchr(s,0,n))return 0;
 const char *p=s,*end=s+n;uint64_t pid,sec,usec,lease,version,deadline_ns;Manifest m={0};
 if(!literal(&p,end,"BALDUR2\npid=") || !decimal(&p,end,0x7fffffff,&pid) || pid<2 ||
 !literal(&p,end,"start_sec=") || !decimal(&p,end,UINT64_C(0x7fffffffffffffff),&sec) || !sec ||
 !literal(&p,end,"start_usec=") || !decimal(&p,end,999999,&usec) ||
 !literal(&p,end,"version=") || !decimal(&p,end,UINT32_MAX,&version) ||
 !literal(&p,end,"cdhash=") || end-p<40)return 0;
 unsigned any=0;
 for(unsigned i=0;i<40;i++){unsigned char c=(unsigned char)*p++;unsigned v;
 if(c>='0' && c<='9')v=c-'0';else if(c>='a' && c<='f')v=c-'a'+10;else return 0;
 m.cdhash[i/2]|=(uint8_t)(v << ((1-i%2)*4));any|=v;}
 if(!any || !literal(&p,end,"\ndevice=") || !hexbytes(&p,end,m.device,sizeof(m.device)) ||
 !literal(&p,end,"\nconfig=") || !hexbytes(&p,end,m.config,sizeof(m.config)) ||
 !literal(&p,end,"\nlease=") || !decimal(&p,end,120,&lease) || (lease && lease<5) || !literal(&p,end,"deadline_ns=") || !decimal(&p,end,UINT64_MAX,&deadline_ns) || (lease? !deadline_ns:deadline_ns!=0) || p!=end)return 0;
 static const unsigned char device[]=PROFILE_DEVICE_BYTES;
 if(memcmp(m.device,device,sizeof(device)) || !config_policy(m.config,sizeof(m.config)))return 0;
 m.deadline_ns=deadline_ns;m.version=(uint32_t)version;m.pid=(uint32_t)pid;m.sec=sec;m.usec=(uint32_t)usec;m.lease=(uint32_t)lease;*out=m;return 1;
}
int peer_policy(const Manifest *m,unsigned u,unsigned e,unsigned p,uint64_t s,unsigned us,const unsigned char h[20]) {
 return m && h && u==PROFILE_UID && e==PROFILE_UID && p==m->pid && s==m->sec && us==m->usec && !memcmp(h,m->cdhash,20);
}
int protected_node(unsigned u,unsigned mode,unsigned links,int directory,int immutable) {
 if(u)return 0;
 if(directory)return S_ISDIR(mode) && !(mode & 0022) && !(mode & 07000);
 return S_ISREG(mode) && (mode & 07777)==0400 && links==1 && immutable;
}
