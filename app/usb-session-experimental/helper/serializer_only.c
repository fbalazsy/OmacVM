#include "transport.h"
#include <sys/socket.h>
#include <fcntl.h>
#include <assert.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include "usbredirparser.h"
typedef struct {unsigned char bytes[512],incoming[80];size_t n,input_pos;} Serialized;
static int serialized_read(void *ctx,uint8_t *data,int count){Serialized *s=ctx;size_t n=sizeof(s->incoming)-s->input_pos;if(n>(size_t)count)n=(size_t)count;memcpy(data,s->incoming+s->input_pos,n);s->input_pos+=n;return (int)n;}
static int serialized_write(void *ctx,uint8_t *data,int count){Serialized *s=ctx;assert(count>=0 && s->n+(size_t)count<=sizeof(s->bytes));memcpy(s->bytes+s->n,data,(size_t)count);s->n+=(size_t)count;return count;}
static void parser_log(void *ctx,int level,const char *msg){(void)ctx;(void)level;(void)msg;}
static int feed(Gate *g,const unsigned char *p,size_t n){int rc=0;for(size_t i=0;i<n;i++){rc=gate_byte(g,p[i]);if(rc<0)return rc;if(rc==1 && i+1<n)gate_consume(g);}return rc;}
static void serializer_control_regression(void){
 const unsigned statuses[]={0,1,255};
 for(unsigned wide=0;wide<2;wide++)for(unsigned s=0;s<3;s++)for(unsigned request=0;request<7;request++){
  Serialized wire={0};struct usbredirparser *p=usbredirparser_create();assert(p);p->priv=&wire;p->write_func=serialized_write;p->read_func=serialized_read;p->log_func=parser_log;
  uint32_t caps[USB_REDIR_CAPS_SIZE]={0};if(wide)usbredirparser_caps_set_cap(caps,usb_redir_cap_64bits_ids);usbredirparser_init(p,"QEMU-equivalent",caps,USB_REDIR_CAPS_SIZE,0);
  assert(!usbredirparser_do_write(p));Gate g;gate_init(&g);assert(feed(&g,wire.bytes,wire.n)==1);gate_consume(&g);assert(wire.n==sizeof(wire.incoming));memcpy(wire.incoming,wire.bytes,wire.n);assert(!usbredirparser_do_read(p));wire.n=0;
  /* QEMU fills all request fields but leaves status unspecified. Seed each
     possible representative stack byte, then fill exactly those request fields. */
  struct usb_redir_control_packet_header h;memset(&h,(int)statuses[s],sizeof(h));
  h.endpoint=0x80;h.request=request==1?1:6;h.requesttype=request==1?0xa1:0x80;h.value=0x100;h.index=0;h.length=18;
  if(request==2)h.requesttype=0xc0; /* vendor */
  if(request==3)h.endpoint=0x81;   /* wrong control endpoint */
  if(request==4){h.requesttype=0x81;h.index=1;} /* wrong interface */
  if(request==5)h.length=4097;    /* allocation bound */
  if(request==6)h.request=7;      /* SET_DESCRIPTOR denied */
  usbredirparser_send_control_packet(p,42,&h,NULL,0);assert(!usbredirparser_do_write(p));
  assert(wire.n==(wide?26u:22u) && wire.bytes[(wide?16:12)+3]==statuses[s]);
  int rc=feed(&g,wire.bytes,wire.n);fprintf(stderr,"serializer->gate ids=%u status=%u case=%u result=%d\n",wide?64:32,statuses[s],request,rc);
  assert(request<2?rc==1:rc==-1);
  usbredirparser_destroy(p);
 }
 puts("PASS maintained parser serializer -> gate: GET_DESCRIPTOR/GET_REPORT status 0/1/255; vendor/endpoint/interface/length/request still denied");
}
int main(void){serializer_control_regression();return 0;}
