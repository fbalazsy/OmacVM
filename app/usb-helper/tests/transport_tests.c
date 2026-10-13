#include "../transport.h"
#include "../io.h"
#include <sys/socket.h>
#include <assert.h>
#include <unistd.h>
#include <stdio.h>
extern int transport_open(Transport *,int,libusb_context *,const HIDPolicy *) __attribute__((weak_import));
extern int transport_read(Transport *) __attribute__((weak_import));
extern int transport_flush(Transport *) __attribute__((weak_import));
extern void transport_close(Transport *) __attribute__((weak_import));
int main(void){assert(transport_open && transport_read && transport_flush && transport_close);
 int pair[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));assert(nonblocking(pair[0])&&nonblocking(pair[1]));HIDPolicy h={.configuration=7,.interface=3,.in_ep=0x85,.in_max=32,.bytes={32,32,0}};
 Transport t;assert(transport_open(&t,pair[0],NULL,&h));assert(transport_flush(&t));unsigned char output[4096];ssize_t n=recv(pair[1],output,sizeof(output),0);assert(n==80&&output[0]==0&&output[4]==68);
 unsigned char hello[80]={0};hello[4]=68;hello[12]='Q';hello[76]=0x20;
 for(size_t i=0;i<sizeof(hello);i++){assert(send(pair[1],hello+i,1,0)==1);assert(transport_read(&t));}assert(t.gate.hello&&!t.failed);
 unsigned char bad[16]={101};assert(send(pair[1],bad,sizeof(bad),0)==sizeof(bad));assert(!transport_read(&t));transport_close(&t);transport_close(&t);close(pair[0]);close(pair[1]);
 assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));assert(nonblocking(pair[0])&&nonblocking(pair[1]));assert(transport_open(&t,pair[0],NULL,&h));close(pair[1]);assert(!transport_read(&t));transport_close(&t);close(pair[0]);
 puts("transport PASS: real usbredirhost hello, fragmented input, bulk refusal, EOF, idempotent host close; no libusb context/device");return 0;}
