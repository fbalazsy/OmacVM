#include "activation_flow.h"
#include <math.h>
int activation_flow(const Ops *o,unsigned lease) {
 if(!o||!o->step||!o->clock||!o->wait||(lease && lease<5)||lease>120)return 64;
 int owned=0,rc=1,terminating=0,killed=0,pending=1,wait_uncertain=0;double deadline=lease?o->clock(o->ctx)+lease:INFINITY,kill_at=deadline-1;
 for(Stage s=AUTH;s<=SPAWN;s++){
  if(o->step(o->ctx,CANCEL)!=0 || o->clock(o->ctx)>=deadline-3)goto stop;
  if(o->step(o->ctx,s))goto stop;
  if(s==SPAWN)owned=1;
 }
 rc=0;
 stop:
 if(owned){
  for(;;){
   ChildResult w=o->wait(o->ctx);
   if(w.kind==CHILD_REAPED){owned=0;if(w.status||pending)rc=1;break;}
   if(w.kind==CHILD_ERROR){rc=1;wait_uncertain=1;if(!lease){o->step(o->ctx,QUARANTINE);return 125;}}
   double now=o->clock(o->ctx);
   if(!terminating && !rc && pending && o->step(o->ctx,CANCEL)==0 && now<deadline-3){
    int ack=o->step(o->ctx,EXEC_ACK);
    if(ack<0)rc=1;
    else if(ack>0){pending=0;if(o->step(o->ctx,READY))rc=1;}
   }
   if(!wait_uncertain && !terminating && (rc || o->step(o->ctx,CANCEL)!=0 || now>=deadline-3)){
    terminating=1;if(!lease)deadline=now+3;if(now+2<kill_at)kill_at=now+2;
    if(o->step(o->ctx,TERM))rc=1;
   }
   if(!wait_uncertain && terminating && !killed && now>=kill_at){killed=1;rc=124;if(o->step(o->ctx,KILL))rc=1;}
   if(now>=deadline){o->step(o->ctx,QUARANTINE);return 125;}
   if(o->step(o->ctx,PAUSE))rc=1;
  }
 }
 if(owned){o->step(o->ctx,QUARANTINE);return 125;}
 if(o->step(o->ctx,CLEAN)){o->step(o->ctx,QUARANTINE);return 125;}
 return rc;
}
