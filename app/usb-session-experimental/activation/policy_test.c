#include "activation_policy.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) {
 Request r={0}; char text[513];
 assert(request_parse("12345","1000000000","12345","120",&r));
 assert(!request_parse("012345","1","0","120",&r));
 assert(!request_parse("0","1","0","120",&r));
 assert(!request_parse("12345","1","1000000","120",&r));
 assert(!request_parse("12345","1","0","121",&r));
 assert(!request_parse("12345","1","0","4",&r));
 assert(!request_parse("12345","-1","0","5",&r));
 assert(!request_parse("2147483648","1","0","5",&r));
 assert(!request_parse("12345","18446744073709551616","0","5",&r));
 assert(request_parse("12345","1000000000","12345","120",&r));
 Identity good={.pid=12345,.uid=4242,.ruid=4242,.sec=1000000000,.usec=12345,.signature=1,.argv=1};
 strcpy(good.path,QEMU_PATH);strcpy(good.sha,QEMU_SHA);strcpy(good.cdhash,QEMU_CDHASH);
 assert(identity_policy(&r,&good,&good));
 Identity bad=good;bad.version++;assert(!identity_policy(&r,&good,&bad));
 bad=good;bad.pid++;assert(!identity_policy(&r,&good,&bad));
 bad=good;bad.sec++;assert(!identity_policy(&r,&good,&bad));
 bad=good;bad.usec++;assert(!identity_policy(&r,&bad,&good));
 bad=good;bad.uid=0;assert(!identity_policy(&r,&bad,&bad));
 bad=good;bad.ruid=0;assert(!identity_policy(&r,&bad,&bad));
 bad=good;bad.cdhash[0]^=1;assert(!identity_policy(&r,&bad,&bad));
 bad=good;bad.sha[1]^=1;assert(!identity_policy(&r,&good,&bad));
 bad=good;bad.signature=0;assert(!identity_policy(&r,&bad,&bad));
 bad=good;bad.argv=0;assert(!identity_policy(&r,&good,&bad));
 bad=good;strcpy(bad.path,"/tmp/OmacVM");assert(!identity_policy(&r,&good,&bad));
 assert(manifest_format(&r,text,sizeof(text)));
 char want[513];snprintf(want,sizeof(want),"BALDUR2\npid=12345\nstart_sec=1000000000\nstart_usec=12345\nversion=0\ncdhash=%s\ndevice=%s\nconfig=%s\nlease=120\ndeadline_ns=0\n",QEMU_CDHASH,DEVICE_HEX,CONFIG_HEX);
 assert(!strcmp(text,want));assert(strlen(text)<=512);assert(!manifest_format(&r,text,10));
 puts("PASS policy: exact identity, stale PID/reexec/hash/argv, strict request, fixed descriptor manifest (offline)");
}
