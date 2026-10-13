#include "transport.h"
#include <sys/socket.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
static void log_cb(void *p,int level,const char *message){(void)p;(void)level;(void)message; /* Never block root on diagnostic output. */}
static int read_cb(void *p,uint8_t *data,int count){
 Transport *t=p;if(t->failed || count<0)return -1;if(!t->available)return 0;
 size_t left=t->gate.used-t->pos,n=(size_t)count;if(n>left)n=left;memcpy(data,t->gate.data+t->pos,n);t->pos+=n;return (int)n;
}
/* flags=0: buffer is borrowed; parser retains/frees it, including partial writes. */
static int write_cb(void *p,uint8_t *data,int count){
 Transport *t=p;if(t->failed || count<0 || count>65536)return -1;
 ssize_t n=send(t->fd,data,(size_t)count,MSG_DONTWAIT);
 if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR))return 0;
 if(n<=0){t->failed=1;return -1;}return (int)n;
}
int transport_open(Transport *t,int fd,libusb_context *ctx,const HIDPolicy *policy){
 memset(t,0,sizeof(*t));t->fd=fd;gate_init(&t->gate,policy);
 int yes=1;if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes)))return 0;
 t->host=usbredirhost_open(ctx,NULL,log_cb,read_cb,write_cb,t,"omacvm-usb-v1",usbredirparser_error,0);
 return t->host!=NULL && !t->failed;
}
int transport_read(Transport *t){
 if(!t->host || t->failed)return 0;
 uint8_t buf[FRAME_MAX];size_t want=t->gate.need-t->gate.used;
 ssize_t n=recv(t->fd,buf,want,MSG_DONTWAIT);
 if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR))return 1;
 if(n<=0){t->failed=1;return 0;}
 int ready=0;for(ssize_t i=0;i<n;i++){ready=gate_byte(&t->gate,buf[i]);if(ready<0){t->failed=1;return 0;}}
 if(!ready)return 1;
 t->available=1;t->pos=0;int rc=usbredirhost_read_guest_data(t->host);t->available=0;
 if(rc || t->pos!=t->gate.used){t->failed=1;return 0;}
 gate_consume(&t->gate);return !t->failed && !t->gate.failed;
}
int transport_flush(Transport *t){
 if(!t->host || t->failed || usbredirhost_has_data_to_write(t->host)>64){t->failed=1;return 0;}
 if(usbredirhost_has_data_to_write(t->host) && usbredirhost_write_guest_data(t->host)){t->failed=1;return 0;}
 return !t->failed;
}
void transport_close(Transport *t){if(t->host){usbredirhost_close(t->host);t->host=NULL;}}
