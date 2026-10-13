#include "policy.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static unsigned rng=0x13579bdf;
static unsigned next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
int main(void){
 /* Deterministic corpus: random headers/lengths, well-framed mutated payloads, truncation, replay. */
 for(unsigned round=0;round<50000;round++){
  Gate g;gate_init(&g);unsigned char hello[80]={0};hello[4]=68;hello[12]='Q';hello[76]=32;
  if(round%2){for(unsigned i=0;i<80;i++)assert(gate_byte(&g,hello[i])==(i==79));gate_consume(&g);}
  unsigned n=next()%4200;for(unsigned i=0;i<n;i++){int r=gate_byte(&g,(unsigned char)next());if(r<0){assert(gate_byte(&g,0)==-1);break;}if(r==1)gate_consume(&g);}
  Manifest m;char text[257];for(unsigned i=0;i<sizeof(text);i++)text[i]=(char)next();assert(!manifest_parse(text,next()%257,&m));
 }
 puts("PASS deterministic 50000 IPC/manifest malformed corpus cases");return 0;
}
