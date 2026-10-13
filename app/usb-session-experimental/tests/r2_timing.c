/* Absolute cooperative budget: fake clock advances, no sleeping/processes. */
#include "../activation/activation_flow.h"
#include <assert.h>
#include <stdio.h>
typedef struct {double now,term_at,kill_at;int spawned,term,killed,clean,slow,cancel,ready;} F;
static int cb(void *p,Stage s){F *f=p;switch(s){
 case AUTH:if(f->slow)f->now+=10;return 0;
 case SPAWN:f->spawned=1;return 0;
 case EXEC_ACK:return 1;
 case READY:f->ready++;return 0;
 case CANCEL:return f->cancel;
 case TERM:f->term++;f->term_at=f->now;return 0;
 case KILL:f->killed++;f->kill_at=f->now;return 0;
 case PAUSE:f->now+=.01;return 0;
 case CLEAN:f->clean++;return 0;
 default:return 0;
}}
static double now(void *p){return ((F *)p)->now;}
static ChildResult waitfn(void *p){return (ChildResult){.kind=((F *)p)->killed?CHILD_REAPED:CHILD_RUNNING,.status=137};}
int main(void){unsigned leases[]={5,10,120};for(unsigned i=0;i<3;i++){
 F f={0};Ops o={&f,cb,now,waitfn};assert(activation_flow(&o,leases[i])!=0);assert(f.clean&&f.term==1&&f.killed==1);
 assert(f.term_at<leases[i]-2.9&&f.kill_at<leases[i]-.9&&f.now<=leases[i]);
 }
 F f={.slow=1};Ops o={&f,cb,now,waitfn};assert(activation_flow(&o,5)!=0);assert(!f.spawned&&f.clean);
 puts("PASS cooperative absolute budgets 5/10/120 include TERM/KILL/reap reserve; slow setup never spawns after useful deadline");
}
