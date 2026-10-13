#include "hid.h"
#include <string.h>
static unsigned le16(const uint8_t *p){return p[0]|((unsigned)p[1]<<8);}
int hid_config(const uint8_t *p,size_t n,HIDPolicy *out){
 if(!p||!out||n>CONFIG_MAX||n<34 || p[0]!=9||p[1]!=2||le16(p+2)!=n||p[4]!=1||!p[5]||!(p[7]&0x80)||(p[7]&31))return 0;
 const uint8_t *i=p+9,*h=p+18;
 if(i[0]!=9||i[1]!=4||i[2]>31||i[3]||i[4]<1||i[4]>2||i[5]!=3||i[6]||i[7]||n!=27u+7u*i[4])return 0;
 if(h[0]!=9||h[1]!=0x21||h[5]!=1||h[6]!=0x22||!le16(h+7)||le16(h+7)>REPORT_MAX)return 0;
 HIDPolicy x={.configuration=p[5],.interface=i[2],.report_length=le16(h+7)};
 for(unsigned a=0;a<i[4];a++){
  const uint8_t *e=p+27+7*a;unsigned ep=e[2],max=le16(e+4);
  if(e[0]!=7||e[1]!=5||!(ep&15)||(ep&0x70)||e[3]!=3||!max||max>64||!e[6])return 0;
  if(ep&0x80){if(x.in_ep)return 0;x.in_ep=ep;x.in_max=max;}
  else {if(x.out_ep)return 0;x.out_ep=ep;x.out_max=max;}
 }
 if(!x.in_ep)return 0;*out=x;return 1;
}
int hid_report(const uint8_t *p,size_t n,HIDPolicy *out){
 if(!p||!out||!n||n>REPORT_MAX)return 0;
 unsigned page=0,size=0,count=0,depth=0,collections=0,usage=0;uint32_t bits[3]={0};
 for(size_t a=0;a<n;){
  uint8_t tag=p[a++];unsigned len=tag&3;if(len==3)len=4;
  if(tag==0xfe||len>n-a)return 0;uint32_t v=0;for(unsigned b=0;b<len;b++)v|=(uint32_t)p[a++]<<(8*b);
  switch(tag&0xfc){
  case 0x04: if(len!=2||v<0xff00||v>0xffff)return 0;page=v;break;
  case 0x08:case 0x18:case 0x28:if(!page||!len||len>2)return 0;usage=1;break;
  case 0x14:case 0x24: /* logical minimum / maximum */ if(!len)return 0;break;
  case 0x74:if(!len||v<1||v>32)return 0;size=v;break;
  case 0x94:if(!len||!v||v>512)return 0;count=v;break;
  case 0xa0:if(len!=1||v!=1||depth||collections||!page||!usage)return 0;depth=1;collections++;usage=0;break;
  case 0xc0:if(len||depth!=1)return 0;depth=0;usage=0;break;
  case 0x80:case 0x90:case 0xb0:{
   if(!depth||!page||!size||!count||!len||len>2||v>0x1ff||!usage)return 0;
   unsigned idx=(tag&0xfc)==0x80?0:((tag&0xfc)==0x90?1:2);
   uint32_t add=size*count;if(add>512||bits[idx]>512-add)return 0;bits[idx]+=add;usage=0;break;
  }
  default:return 0; /* Report IDs, push/pop, physical collections, long/unknown items unsupported. */
  }
 }
 if(depth||collections!=1||!bits[0])return 0;
 for(unsigned i=0;i<3;i++){if(bits[i]%8)return 0;out->bytes[i]=(uint16_t)(bits[i]/8);}return 1;
}
