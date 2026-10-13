#include "process.h"
#include <libproc.h>
#include <limits.h>
#include <string.h>
/* Darwin SPI: xnu bsd/sys/proc_info_private.h, flavor 17 (APSL 2.0).
   No fallback on an incompatible kernel; exact 56-byte result required. */
#define PROC_PIDUNIQIDENTIFIERINFO 17
struct proc_uniqidentifierinfo {uint8_t uuid[16]; uint64_t unique,parent; int32_t version,parent_version; uint64_t r2,r3;};
_Static_assert(sizeof(struct proc_uniqidentifierinfo)==56,"Darwin process SPI");
int scalar(const char *s,uint64_t max,uint64_t *out){
 if(!s || !*s || (s[0]=='0' && s[1]))return 0;
 uint64_t n=0;for(;*s;s++){if(*s<'0'||*s>'9')return 0;unsigned d=*s-'0';if(d>max || n>(max-d)/10)return 0;n=n*10+d;}*out=n;return 1;
}
int process_read(pid_t pid,Process *out){
 struct proc_bsdinfo a={0},b={0};struct proc_uniqidentifierinfo u={0},v={0};
 if(pid<=0 || !out || proc_pidinfo(pid,PROC_PIDUNIQIDENTIFIERINFO,0,&u,sizeof(u))!=sizeof(u) ||
 proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&a,sizeof(a))!=sizeof(a) ||
 proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b) ||
 proc_pidinfo(pid,PROC_PIDUNIQIDENTIFIERINFO,0,&v,sizeof(v))!=sizeof(v) ||
 a.pbi_uid!=a.pbi_ruid || a.pbi_uid!=b.pbi_uid || b.pbi_uid!=b.pbi_ruid ||
 a.pbi_start_tvsec!=b.pbi_start_tvsec || a.pbi_start_tvusec!=b.pbi_start_tvusec ||
 !a.pbi_start_tvsec || a.pbi_start_tvusec>=1000000 || u.version<=0 || u.version!=v.version || u.unique!=v.unique)return 0;
 *out=(Process){pid,a.pbi_uid,a.pbi_start_tvsec,(uint32_t)a.pbi_start_tvusec,(uint32_t)u.version};return 1;
}
int process_equal(const Process *a,const Process *b){return a->pid==b->pid && a->uid==b->uid && a->sec==b->sec && a->usec==b->usec && a->version==b->version;}
