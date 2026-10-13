/* Pure producer/consumer test: no process, USB or QMP operations. */
#define identity_policy activation_identity_policy
#include "../activation/activation_policy.c"
#undef identity_policy
#include "../helper/policy.h"
#include <assert.h>
int main(void){
 Request a={.pid=123,.sec=456,.usec=789,.lease=120,.version=7,.deadline_ns=9000000000},b=a;b.version=8;
 char x[513],y[513];Manifest m;
 assert(manifest_format(&a,x,sizeof x)&&manifest_format(&b,y,sizeof y));
 assert(strcmp(x,y)!=0); /* review's serialization-loss probe, reversed */
 assert(!strncmp(x,"BALDUR2\n",8));assert(manifest_parse(x,strlen(x),&m));
 x[6]='1';assert(!manifest_parse(x,strlen(x),&m));
 a.lease=0;a.deadline_ns=0;assert(manifest_format(&a,x,sizeof x));assert(manifest_parse(x,strlen(x),&m));assert(m.lease==0 && m.deadline_ns==0 && m.version==7);
 a.deadline_ns=1;assert(manifest_format(&a,x,sizeof x));assert(!manifest_parse(x,strlen(x),&m));
 puts("PASS R1 generation serialized; producer/consumer session0 + diagnostic BALDUR2; old schema/mixed zero deadline rejected");
}
