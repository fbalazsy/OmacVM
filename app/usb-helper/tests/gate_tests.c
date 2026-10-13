#include "../gate.h"
#include <stdio.h>
#include <string.h>
extern void gate_init(Gate *,const HIDPolicy *) __attribute__((weak_import));
extern int gate_byte(Gate *,uint8_t) __attribute__((weak_import));
extern void gate_consume(Gate *) __attribute__((weak_import));
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);return 1;}count++;}while(0)
static int frame(Gate *g,unsigned type,const uint8_t *p,unsigned n){uint8_t h[16]={type,0,0,0,n&255,n>>8,0,0};int rc=0;for(unsigned i=0;i<g->header;i++)if((rc=gate_byte(g,h[i]))<0)return rc;for(unsigned i=0;i<n;i++)if((rc=gate_byte(g,p[i]))<0)return rc;return rc;}
int main(void){unsigned count=0;CHECK(gate_init && gate_byte && gate_consume);HIDPolicy p={.configuration=7,.interface=3,.in_ep=0x85,.in_max=32,.bytes={32,32,0}};Gate g;gate_init(&g,&p);uint8_t hello[68]={0};memcpy(hello,"fixture",7);CHECK(frame(&g,0,hello,68)==1);gate_consume(&g);
 uint8_t cfg=7;CHECK(frame(&g,6,&cfg,1)==1);gate_consume(&g);
 for(unsigned i=0;i<100000;i++){CHECK(frame(&g,7,NULL,0)==1);gate_consume(&g);}
 uint8_t req[]={0,9,0x21,0,0,2,3,0,32,0};uint8_t data[42]={0};memcpy(data,req,10);CHECK(frame(&g,100,data,42)==1);gate_consume(&g);
 data[6]=0;CHECK(frame(&g,100,data,42)==-1);
 printf("gate: %u assertions PASS (100000 frames; no cumulative cutoff)\n",count);return 0;}
