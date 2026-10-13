#include "policy.h"
#include "usbredirproto.h"
#include <string.h>
#include <math.h>
static uint32_t le32(const uint8_t *p){return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static unsigned le16(const uint8_t *p){return p[0]|((unsigned)p[1]<<8);}
void gate_init(Gate *g){memset(g,0,sizeof(*g));g->header=12;g->need=12;}
static int payload(Gate *g) {
 uint32_t type=le32(g->data);size_t n=g->need-g->header;const uint8_t *p=g->data+g->header;
 if(!g->hello)return type==usb_redir_hello && n==68 && !(le32(p+64)&~255u) && memchr(p,0,64);
 switch(type){
 case usb_redir_reset: case usb_redir_get_configuration: case usb_redir_cancel_data_packet:
 case usb_redir_filter_reject:case usb_redir_device_disconnect_ack:return n==0;
 case usb_redir_set_configuration:return n==1 && p[0]==1;
 case usb_redir_set_alt_setting:return n==2 && !p[0] && !p[1];
 case usb_redir_get_alt_setting:return n==1 && !p[0];
 case usb_redir_start_interrupt_receiving:case usb_redir_stop_interrupt_receiving:return n==1 && p[0]==0x81;
 case usb_redir_filter_filter:
  if(!n || n>512 || p[n-1] || memchr(p,0,n-1))return 0;
  for(size_t i=0;i<n-1;i++)if(!strchr("0123456789abcdefABCDEFxX-:,|",p[i]))return 0;
  return 1;
 case usb_redir_control_packet: {
  /* USBredir status is response-only; a guest request's byte is unspecified.
     Ignore it without relaxing any request/length/direction policy. */
  if(n<10 || (p[0]!=0 && p[0]!=0x80) || (p[2]&0x80)!=p[0])return 0;
  unsigned len=le16(p+8),index=le16(p+6),recipient=p[2]&31,typebits=p[2]&0x60;
  if(len>4096 || recipient>2 || (recipient==1 && index!=0) || (recipient==2 && index!=0x81 && index!=0) || typebits==0x60)return 0;
  /* No SET_DESCRIPTOR, raw SET_CONFIGURATION/SET_INTERFACE, or vendor device commands. */
  if(typebits==0 && p[1]!=0 && p[1]!=1 && p[1]!=3 && p[1]!=5 && p[1]!=6 && p[1]!=8 && p[1]!=10)return 0;
  if(typebits==0x40)return 0;
  if(typebits==0x20 && (recipient!=1 || (p[1]!=1 && p[1]!=2 && p[1]!=3 && p[1]!=9 && p[1]!=10 && p[1]!=11)))return 0;
  return n==10+(p[0]?0:len);
 }
 default:return 0;
 }
}
int gate_byte(Gate *g,uint8_t b) {
 if(!g || g->failed)return -1;
 if(g->used>=sizeof(g->data) || g->used>=g->need){g->failed=1;return -1;}
 g->data[g->used++]=b;
 if(g->used==g->header){
  uint32_t n=le32(g->data+4),type=le32(g->data);
  if(n>sizeof(g->data)-g->header || (!g->hello && type!=usb_redir_hello) || (g->hello && type==usb_redir_hello)) {g->failed=1;return -1;}
  g->need=g->header+n;
 }
 if(g->used<g->need)return 0;
 if(!payload(g)){g->failed=1;return -1;}
 if(g->count<UINT32_MAX)g->count++;return 1;
}
void gate_consume(Gate *g) {
 if(!g || g->failed || g->used!=g->need){if(g)g->failed=1;return;}
 if(!g->hello){g->hello=1;g->header=(le32(g->data+12+64)&(1u<<usb_redir_cap_64bits_ids))?16:12;}
 g->used=0;g->need=g->header;
}
int lease_live(double n,double s,unsigned d,int stopped){return !stopped && d>0 && d<=120 && isfinite(n) && isfinite(s) && n>=s && n-s<d;}
