#include "../hid.h"
#include <stdio.h>
#include <string.h>
extern int hid_report(const uint8_t *,size_t,HIDPolicy *) __attribute__((weak_import));
extern int hid_config(const uint8_t *,size_t,HIDPolicy *) __attribute__((weak_import));
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);return 1;}count++;}while(0)
int main(void){unsigned count=0;CHECK(hid_report && hid_config);HIDPolicy h={0};
 uint8_t report[]={0x06,0x23,0xff,0x09,1,0xa1,1,0x15,0,0x26,0xff,0,0x75,8,0x95,32,0x09,1,0x81,2,0x09,2,0x91,2,0xc0};
 CHECK(hid_report(report,sizeof(report),&h));CHECK(h.bytes[0]==32 && h.bytes[1]==32 && !h.bytes[2]);
 report[2]=1;CHECK(!hid_report(report,sizeof(report),&h));report[2]=0xff;
 report[15]=65;CHECK(!hid_report(report,sizeof(report),&h));report[15]=32;
 CHECK(!hid_report(report,sizeof(report)-1,&h));
 uint8_t config[]={9,2,34,0,1,7,0,0x80,50,9,4,3,0,1,3,0,0,0,9,0x21,0x11,1,0,1,0x22,sizeof(report),0,7,5,0x85,3,32,0,1};
 CHECK(hid_config(config,sizeof(config),&h));CHECK(h.configuration==7 && h.interface==3 && h.in_ep==0x85 && h.in_max==32);
 config[16]=1;CHECK(!hid_config(config,sizeof(config),&h));config[16]=0;
 config[12]=1;CHECK(!hid_config(config,sizeof(config),&h));config[12]=0;
 config[4]=2;CHECK(!hid_config(config,sizeof(config),&h));config[4]=1;
 config[30]=2;CHECK(!hid_config(config,sizeof(config),&h));config[30]=3;
 config[29]=5;CHECK(!hid_config(config,sizeof(config),&h));
 printf("hid: %u assertions PASS\n",count);return 0;}
