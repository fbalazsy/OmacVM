#include "activation_flow.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct {int fail,stage,polls,cancel,term,killed,clean,spawned,ready,quarantined,ack;double now,term_at,kill_at;} Fake;
static int step(void *ctx,Stage s) {Fake *f=ctx;
 if(s==CANCEL)return f->cancel==1 || (f->cancel==2 && f->polls>0) || (f->cancel==3 && f->stage==REAUTH);
 if(s==TERM){f->term++;f->term_at=f->now;return 0;}
 if(s==KILL){f->killed++;f->kill_at=f->now;return f->fail==99?-1:0;}
 if(s==CLEAN){f->clean++;return 0;}
 if(s==QUARANTINE){f->quarantined++;return 0;}
 if(s==EXEC_ACK)return f->ack;
 if(s==PAUSE){f->now+=.05;return 0;}
 if(s==READY)f->ready++;
 f->stage=s;if(f->fail==(int)s)return -1;
 if(s==SPAWN)f->spawned++;
 return 0;
}
static ChildResult wait_fake(void *ctx){Fake *f=ctx;f->polls++;return (ChildResult){.kind=f->fail==99?CHILD_ERROR:(f->polls>3?CHILD_REAPED:CHILD_RUNNING)};}
static double clockfn(void *ctx){return ((Fake *)ctx)->now;}
int main(void){
 Fake f={.ack=1};Ops o={&f,step,clockfn,wait_fake};assert(activation_flow(&o,5)==0);assert(f.clean==1&&!f.term&&!f.killed&&f.ready==1);
 for(int s=AUTH;s<=READY;s++){f=(Fake){.fail=s,.ack=1};assert(activation_flow(&o,5)!=0);assert(f.clean==1);if(s<=SPAWN)assert(!f.term);else assert(f.term==1);}
 f=(Fake){.cancel=2,.ack=1};assert(activation_flow(&o,5)==1);assert(f.term==1&&!f.killed&&f.clean==1&&!f.ready);
 for(int cancel=1;cancel<=3;cancel+=2){f=(Fake){.cancel=cancel,.ack=1};assert(activation_flow(&o,5)!=0);assert(!f.spawned&&!f.term&&!f.ready&&f.clean==1);}
 f=(Fake){.fail=99,.ack=1};assert(activation_flow(&o,5)==125);assert(!f.term&&!f.killed&&!f.clean&&f.quarantined==1&&f.now<=5.1);
 f=(Fake){.ack=-1};assert(activation_flow(&o,5)==1);assert(!f.ready&&f.term==1&&f.clean==1);
 f=(Fake){.ack=0};assert(activation_flow(&o,5)==1);assert(!f.ready&&f.clean==1); /* death before exec acknowledgement */
 assert(activation_flow(&o,121)==64);
 puts("PASS flow: every setup failure; pre-spawn/after-REAUTH cancellation; exec failure/death; typed reaping; wait/kill quarantine");
}
