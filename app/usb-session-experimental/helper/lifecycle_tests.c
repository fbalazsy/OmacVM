#include "lifecycle.h"
#include <assert.h>
#include <stdio.h>
typedef struct {int fail,stopat,n;Stage seen[32];} Probe;
static int step(void *p,Stage s){Probe *q=p;q->seen[q->n++]=s;return (int)s==q->fail;}
static int stop(void *p){Probe *q=p;return q->n==q->stopat;}
static int count(Probe *p,Stage s){int n=0;for(int i=0;i<p->n;i++)n+=p->seen[i]==s;return n;}
int main(void) {
 for(int failure=-1;failure<=ST_LOOP;failure++){
  Probe p={.fail=failure,.stopat=-1};Ops o={&p,step,stop};int r=lifecycle(&o);assert(r==(failure>=0));
  assert(count(&p,ST_SOCKET_CLOSE)==1);
  assert(count(&p,ST_EXIT)==(failure<0 || failure>=ST_INIT));
  assert(count(&p,ST_HOST_CLOSE)==(failure<0 || failure>=ST_HOST));
  assert(count(&p,ST_HANDLE_CLOSE)==(failure>=ST_OPEN && failure<ST_HANDOFF));
  if(failure>=0 && failure<ST_INIT)assert(!count(&p,ST_INIT));
 }
 for(int stopat=0;stopat<=ST_LOOP;stopat++){
  Probe p={.fail=-1,.stopat=stopat};Ops o={&p,step,stop};assert(lifecycle(&o));assert(count(&p,ST_SOCKET_CLOSE)==1);assert(!count(&p,ST_LOOP));
 }
 puts("PASS lifecycle actual coordinator: failures/cancellation each stage, consumed handle never double-close, no USB before auth+scan");
}
