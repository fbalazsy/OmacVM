/* Framing algorithm derived from reviewed native usbredir gate; bounds are
 * descriptor-derived, with no transport lifetime or total frame limit. */
#include "gate.h"
#include "usbredirproto.h"
#include <string.h>
static uint32_t le32(const uint8_t *p){return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static unsigned le16(const uint8_t *p){return p[0]|((unsigned)p[1]<<8);}
void gate_init(Gate *g,const HIDPolicy *p){memset(g,0,sizeof(*g));g->header=g->need=12;g->policy=*p;}
static int payload(Gate *g){
 uint32_t type=le32(g->data);size_t n=g->need-g->header;const uint8_t *p=g->data+g->header;HIDPolicy *h=&g->policy;
 if(!g->hello)return type==usb_redir_hello && n==68 && !(le32(p+64)&~255u) && memchr(p,0,64);
 switch(type){
 case usb_redir_reset:case usb_redir_get_configuration:case usb_redir_cancel_data_packet:case usb_redir_filter_reject:case usb_redir_device_disconnect_ack:return n==0;
 case usb_redir_set_configuration:return n==1 && p[0]==h->configuration;
 case usb_redir_set_alt_setting:return n==2 && p[0]==h->interface && !p[1];
 case usb_redir_get_alt_setting:return n==1 && p[0]==h->interface;
 case usb_redir_start_interrupt_receiving:case usb_redir_stop_interrupt_receiving:return n==1 && p[0]==h->in_ep;
 case usb_redir_filter_filter:
  if(!n||n>512||p[n-1]||memchr(p,0,n-1))return 0;
  for(size_t i=0;i<n-1;i++)if(!strchr("0123456789abcdefABCDEFxX-:,|",p[i]))return 0;return 1;
 case usb_redir_interrupt_packet:return h->out_ep && n>=4 && p[0]==h->out_ep && le16(p+2)<=h->out_max && le16(p+2)==h->bytes[1] && n==4u+le16(p+2);
 case usb_redir_control_packet:{
  if(n<10||(p[0]!=0&&p[0]!=0x80)||(p[2]&0x80)!=p[0])return 0;
  unsigned len=le16(p+8),index=le16(p+6),value=le16(p+4),rt=p[2],request=p[1];
  if(len>REPORT_MAX||n!=10u+(p[0]?0:len))return 0;
  if(rt==0x80 && request==6)return (value>>8)>=1 && (value>>8)<=3; /* device/config/string */
  if(rt==0x81 && request==6)return index==h->interface && ((value>>8)==0x21||(value>>8)==0x22) && !(value&255);
  if(rt==0x80 && request==8)return !value&&!index&&len==1;
  if(rt==0x81 && request==10)return !value&&index==h->interface&&len==1;
  if((rt==0x80||rt==0x81||rt==0x82) && request==0)return !value&&len==2&&((rt==0x80&&!index)||(rt==0x81&&index==h->interface)||(rt==0x82&&(index==h->in_ep||(h->out_ep&&index==h->out_ep))));
  if(rt==0x02 && request==1)return !value&&!len&&(index==h->in_ep||(h->out_ep&&index==h->out_ep));
  if(index!=h->interface)return 0;
  if((rt==0xa1&&request==1)||(rt==0x21&&request==9)){
   unsigned kind=value>>8;if((value&255)||kind<1||kind>3||!h->bytes[kind-1])return 0;
   if(rt==0x21 && kind==1)return 0;return len==h->bytes[kind-1];
  }
  if(rt==0xa1 && request==2)return !value&&len==1;
  if(rt==0x21 && request==10)return !(value&255)&&!len;
  /* No boot SET_PROTOCOL, vendor commands, address/config/descriptor writes. */
  return 0;
 }
 default:return 0;
 }
}
int gate_byte(Gate *g,uint8_t b){
 if(!g||g->failed)return -1;if(g->used>=sizeof(g->data)||g->used>=g->need){g->failed=1;return -1;}g->data[g->used++]=b;
 if(g->used==g->header){uint32_t n=le32(g->data+4),t=le32(g->data);if(n>sizeof(g->data)-g->header||(!g->hello&&t!=usb_redir_hello)||(g->hello&&t==usb_redir_hello)){g->failed=1;return -1;}g->need=g->header+n;}
 if(g->used<g->need)return 0;if(!payload(g)){g->failed=1;return -1;}return 1;
}
void gate_consume(Gate *g){
 if(!g||g->failed||g->used!=g->need){if(g)g->failed=1;return;}
 if(!g->hello){g->hello=1;g->header=(le32(g->data+76)&(1u<<usb_redir_cap_64bits_ids))?16:12;}g->used=0;g->need=g->header;
}
