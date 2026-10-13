#include "lifecycle.h"
int lifecycle(Ops *o){
 if(!o || !o->step || !o->stop)return 1;
 int rc=0,init=0,handle=0,host=0;
 for(Stage s=ST_AUTH;s<=ST_LOOP;s++){
  if(o->stop(o->ctx)){rc=1;break;}
  if(s==ST_INIT)init=1;
  if(s==ST_OPEN)handle=1;
  if(s==ST_HOST)host=1;
  /* set_device takes ownership even on failure; never close that pointer here. */
  if(s==ST_HANDOFF)handle=0;
  if(o->step(o->ctx,s)){rc=1;break;}
 }
 if(host && o->step(o->ctx,ST_HOST_CLOSE))rc=1;
 if(handle && o->step(o->ctx,ST_HANDLE_CLOSE))rc=1;
 if(init && o->step(o->ctx,ST_EXIT))rc=1;
 if(o->step(o->ctx,ST_SOCKET_CLOSE))rc=1;
 return rc;
}
