#include "policy.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void test_invocation(void) {
 const char *ok[]={"helper","--serve"};
 assert(invocation(2,ok,0,0));
 assert(!invocation(2,ok,4242,4242)); assert(!invocation(2,ok,4242,0));
 assert(!invocation(1,ok,0,0));
 const char *bad[]={"helper","--serve","--pid","123"}; assert(!invocation(4,bad,0,0));
 const char *b[]={"helper","--inspect"}; assert(!invocation(2,b,0,0));
 puts("PASS invocation: root-only, no setuid, no user-selected targets");
}
static const unsigned char report[]={0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x15,0x00,0x26,0xff,0x00,0x75,0x08,0x95,0x20,0x09,0x01,0x81,0x02,0x95,0x20,0x09,0x01,0x91,0x02,0x95,0x01,0x09,0x01,0xb1,0x02,0xc0};
static void test_identity(void) {
 assert(identity_policy(0x1209,0xffff,0x12340000,0,0,0,1,"SYNTHETIC-ONLY","SyntheticVendorHID"));
 unsigned v[]={0x1209,0xffff,0x12340000,0,0,0,1};
 for(unsigned i=0;i<7;i++){unsigned old=v[i];v[i]^=1;assert(!identity_policy(v[0],v[1],v[2],v[3],v[4],v[5],v[6],"SYNTHETIC-ONLY","SyntheticVendorHID"));v[i]=old;}
 assert(!identity_policy(0x1209,0xffff,0x12340000,0,0,0,1,"fixture","SyntheticVendorHID"));
 assert(!identity_policy(0x1209,0xffff,0x12340000,0,0,0,1,"SYNTHETIC-ONLYx","SyntheticVendorHID"));
 assert(!identity_policy(0x1209,0xffff,0x12340000,0,0,0,1,"SYNTHETIC-ONLY","Keyboard"));
 assert(report_policy(report,sizeof(report)));
 for(size_t i=0;i<sizeof(report);i++){unsigned char x[sizeof(report)];memcpy(x,report,sizeof(x));x[i]^=1;assert(!report_policy(x,sizeof(x)));}
 assert(!report_policy(report,sizeof(report)-1)); assert(!report_policy(NULL,33));
 /* Fixture only: fields unconstrained by the recorded live evidence are not claimed as measured. */
 unsigned char cfg[]=PROFILE_CONFIG_BYTES;
 assert(config_policy(cfg,sizeof(cfg)));
 unsigned positions[]={0,1,2,3,4,5,9,10,11,12,13,14,15,16,18,19,23,24,25,26,27,28,29,30,31,32,33};
 for(unsigned i=0;i<sizeof(positions)/sizeof(*positions);i++){unsigned j=positions[i];cfg[j]^=1;assert(!config_policy(cfg,sizeof(cfg)));cfg[j]^=1;}
 assert(!config_policy(cfg,sizeof(cfg)-1));assert(!config_policy(NULL,34));
 puts("PASS identity: full fixed identity, every report byte, config/interface/EP constraints");
}
static void test_manifest_peer(void) {
 const char *text="BALDUR2\npid=123\nstart_sec=456\nstart_usec=789\nversion=7\ncdhash=0123456789abcdef0123456789abcdef01234567\ndevice=12011001000000400912ffff000101020301\nconfig=09022200010100803209040000010300000009210001000122210007058103400001\nlease=120\ndeadline_ns=9000000000\n";
 Manifest m; assert(manifest_parse(text,strlen(text),&m));assert(m.pid==123 && m.sec==456 && m.usec==789 && m.lease==120);
 for(size_t i=0;i<strlen(text);i++)assert(!manifest_parse(text,i,&m));
 char b[512];snprintf(b,sizeof(b),"%sx",text);assert(!manifest_parse(b,strlen(b),&m));
 memcpy(b,text,strlen(text));b[12]=0;assert(!manifest_parse(b,strlen(text),&m));
 const char *bad[]={"BALDUR2\npid=0\nstart_sec=456\nstart_usec=789\nversion=7\ncdhash=0123456789abcdef0123456789abcdef01234567\ndevice=12011001000000400912ffff000101020301\nconfig=09022200010100803209040000010300000009210001000122210007058103400001\nlease=120\ndeadline_ns=9000000000\n","BALDUR2\npid=123\nstart_sec=456\nstart_usec=1000000\nversion=7\ncdhash=0123456789abcdef0123456789abcdef01234567\ndevice=12011001000000400912ffff000101020301\nconfig=09022200010100803209040000010300000009210001000122210007058103400001\nlease=120\ndeadline_ns=9000000000\n","BALDUR2\npid=123\nstart_sec=456\nstart_usec=789\nversion=7\ncdhash=0123456789abcdef0123456789abcdef01234567\ndevice=12011001000000400912ffff000101020301\nconfig=09022200010100803209040000010300000009210001000122210007058103400001\nlease=121\n"};
 for(unsigned i=0;i<3;i++)assert(!manifest_parse(bad[i],strlen(bad[i]),&m));
 assert(manifest_parse(text,strlen(text),&m));
 assert(peer_policy(&m,4242,4242,123,456,789,m.cdhash));
 assert(!peer_policy(&m,0,4242,123,456,789,m.cdhash));assert(!peer_policy(&m,4242,0,123,456,789,m.cdhash));
 assert(!peer_policy(&m,4242,4242,124,456,789,m.cdhash));assert(!peer_policy(&m,4242,4242,123,457,789,m.cdhash));assert(!peer_policy(&m,4242,4242,123,456,790,m.cdhash));
 unsigned char h[20];memcpy(h,m.cdhash,20);h[0]^=1;assert(!peer_policy(&m,4242,4242,123,456,789,h));
 assert(protected_node(0,0100400,1,0,1));assert(!protected_node(4242,0100400,1,0,1));
 assert(!protected_node(0,0100644,1,0,1));assert(!protected_node(0,0100400,2,0,1));assert(!protected_node(0,0100400,1,0,0));assert(!protected_node(0,0120400,1,0,1));
 assert(protected_node(0,0040711,2,1,0));assert(!protected_node(0,0040777,2,1,0));assert(!protected_node(4242,0040711,2,1,0));
 puts("PASS manifest/peer: strict parsing, no trailing/NUL, PID+start+UID+CDHash, immutable root metadata");
}
static int feed(Gate *g,const unsigned char *p,size_t n){int r=0;for(size_t i=0;i<n;i++){r=gate_byte(g,p[i]);if(r<0)return r;assert(!r || i+1==n);}return r;}
static void hello(Gate *g){unsigned char h[80]={0};h[4]=68;h[12]='Q';h[76]=0x20;assert(feed(g,h,sizeof(h))==1);gate_consume(g);}
static void test_gate(void) {
 Gate g;gate_init(&g);hello(&g);assert(g.header==16);
 unsigned char reset[16]={3};assert(feed(&g,reset,16)==1);gate_consume(&g);
 unsigned char start[17]={15};start[4]=1;start[16]=0x81;assert(feed(&g,start,17)==1);gate_consume(&g);
 start[16]=0x82;assert(feed(&g,start,17)==-1);assert(gate_byte(&g,0)==-1);
 gate_init(&g);unsigned char huge[12]={0};memset(huge+4,0xff,4);assert(feed(&g,huge,12)==-1);
 gate_init(&g);hello(&g);unsigned char bulk[16]={101};assert(feed(&g,bulk,16)==-1);
 gate_init(&g);hello(&g);unsigned char c[26]={100};c[4]=10;c[16]=0x80;c[17]=6;c[18]=0x80;c[25]=1;assert(feed(&g,c,26)==1);gate_consume(&g);
 c[25]=0x80;assert(feed(&g,c,26)==-1);
 gate_init(&g);hello(&g);c[25]=1;c[16]=0;assert(feed(&g,c,26)==-1);
 gate_init(&g);hello(&g);unsigned char setconf[17]={6};setconf[4]=1;setconf[16]=2;assert(feed(&g,setconf,17)==-1);
 gate_init(&g);hello(&g);for(unsigned i=1;i<100001;i++){assert(feed(&g,reset,16)==1);gate_consume(&g);}assert(feed(&g,reset,16)==1);
 gate_init(&g);hello(&g);unsigned char dup[16]={0};assert(feed(&g,dup,16)==-1);
 assert(lease_live(110,100,120,0));assert(!lease_live(220,100,120,0));assert(!lease_live(99,100,120,0));assert(!lease_live(101,100,121,0));assert(!lease_live(101,100,120,1));
 puts("PASS IPC/lifecycle: fragmented bounded frames, malformed lengths/direction, endpoint/config/bulk denial, sticky fail, quota, monotonic lease");
}
int main(void) {test_invocation();test_identity();test_manifest_peer();test_gate();return 0;}
