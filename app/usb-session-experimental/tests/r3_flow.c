/* Review WAIT_ERROR/KILL_ERROR probes converted to assertions. Pure fakes. */
#include "../activation/activation_flow.h"
#include <assert.h>
#include <stdio.h>
typedef struct {int mode,live,term,kills,clean_live,clean;double now;} Fake;
static double tick(void *p){return ((Fake *)p)->now;}
static int cb(void *p,Stage s){Fake *f=p;switch(s){
case SPAWN:f->live=1;return 0;
case WAIT:assert(0);return -1;
case TERM:f->term++;return 0;
case KILL:f->kills++;return -1;
case CLEAN:f->clean++;f->clean_live=f->live;return 0;
case PAUSE:f->now+=.05;return 0;
default:return 0;
}}
static ChildResult wait_fake(void *p){Fake *f=p;return (ChildResult){.kind=f->mode==1?CHILD_ERROR:CHILD_RUNNING,.error=5};}
int main(void){for(int mode=1;mode<=2;mode++){Fake f={.mode=mode};Ops o={&f,cb,tick,wait_fake};int rc=activation_flow(&o,5);assert(!f.clean_live && !f.clean);assert(rc==125);assert(f.now<=5.1);if(mode==1)assert(!f.term&&!f.kills);else assert(f.term&&f.kills);}puts("PASS R3 wait/kill uncertainty retains ownership; bounded observation, quarantine not released");}
