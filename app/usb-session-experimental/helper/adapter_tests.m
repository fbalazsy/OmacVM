/* Compile-time dependency injection ONLY in this test translation unit. No USB initialization. */
#define libusb_get_device fake_get_device
#define libusb_get_device_descriptor fake_get_descriptor
#define libusb_get_session_data fake_get_session
#define libusb_get_string_descriptor_ascii fake_string
#define libusb_get_configuration fake_configuration
#define libusb_control_transfer fake_control
#define libusb_init_context fake_init
#define usbredirhost_set_device fake_set_device
#define libusb_close fake_close
#define transport_close fake_transport_close
#define registry_scan fake_registry_scan
#define peer_auth fake_peer_auth
#define main candidate_main
#include "main.m"
#undef main
#include <assert.h>
static int init_calls,variant,set_calls,registry_calls,control_calls,set_result=usb_redir_ioerror,host_owns,close_calls;
void fake_close(libusb_device_handle *h){(void)h;close_calls++;}
void fake_transport_close(Transport *t){(void)t;if(host_owns){host_owns=0;close_calls++;}}
static OwnershipPhase expected_phase;
static const Snapshot *expected_original;
int fake_peer_auth(int fd,const Manifest *m){(void)fd;(void)m;return 1;}
int fake_registry_scan(Snapshot *out,OwnershipPhase phase,const Snapshot *original){
 assert(phase==expected_phase && original==expected_original);registry_calls++;if(out)*out=(Snapshot){.session=42};return 1;
}
libusb_device *fake_get_device(libusb_device_handle *h){return (libusb_device *)h;}
unsigned long fake_get_session(libusb_device *d){(void)d;return variant==1?43:42;}
int fake_get_descriptor(libusb_device *d,struct libusb_device_descriptor *out){(void)d;memset(out,0,sizeof(*out));out->iProduct=1;out->iSerialNumber=2;return 0;}
int fake_string(libusb_device_handle *h,uint8_t index,unsigned char *data,int n){(void)h;const char *s=index==1?"SyntheticVendorHID":variant==2?"fixture":"SYNTHETIC-ONLY";strlcpy((char *)data,s,(size_t)n);return (int)strlen(s);}
int fake_configuration(libusb_device_handle *h,int *out){(void)h;*out=variant==3?2:1;return 0;}
int fake_control(libusb_device_handle *h,uint8_t bm,uint8_t request,uint16_t value,uint16_t index,unsigned char *data,uint16_t length,unsigned timeout){
 assert(h==(void *)1);control_calls++;assert(request==6 && !index && timeout==500);
 const unsigned char config[]=PROFILE_CONFIG_BYTES;
 const unsigned char report[]={0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x15,0x00,0x26,0xff,0x00,0x75,0x08,0x95,0x20,0x09,0x01,0x81,0x02,0x95,0x20,0x09,0x01,0x91,0x02,0x95,0x01,0x09,0x01,0xb1,0x02,0xc0};
 static const unsigned char device_fixture[]=PROFILE_DEVICE_BYTES;
 if(value==0x100){assert(bm==0x80 && length==18);memcpy(data,device_fixture,length);}
 else if(value==0x200){assert(bm==0x80 && length==34);memcpy(data,config,length);if(variant==4)data[14]=9;}
 else {assert(value==0x2200 && bm==0x81 && length==33);memcpy(data,report,length);if(variant==5)data[2]=1;}
 return variant==6?length-1:length;
}
int fake_init(libusb_context **ctx,const struct libusb_init_option options[],int n){(void)ctx;(void)options;(void)n;init_calls++;return -1;}
int fake_set_device(struct usbredirhost *host,libusb_device_handle *h){(void)host;assert(h==(void *)1);set_calls++;host_owns=set_result==usb_redir_success;if(!host_owns)close_calls++;return set_result;}
static int reached_loop;
static int adapter_step(void *ctx,Stage s){
 if(s==ST_HANDOFF || s==ST_POSTCHECK || s==ST_HOST_CLOSE || s==ST_HANDLE_CLOSE)return operation(ctx,s);
 if(s==ST_LOOP)reached_loop++;
 return 0;
}
static int never_stop(void *ctx){(void)ctx;return 0;}
int main(void){@autoreleasepool {
 Runtime r={0};r.handle=(void *)1;r.original.session=42;
 const unsigned char df[]=PROFILE_DEVICE_BYTES;
 const unsigned char cf[]=PROFILE_CONFIG_BYTES;
 memcpy(r.manifest.device,df,sizeof(df));memcpy(r.manifest.config,cf,sizeof(cf));
 assert(descriptor_check(&r,r.handle));
 for(size_t i=0;i<sizeof(df);i++){r.manifest.device[i]^=1;assert(!descriptor_check(&r,r.handle));r.manifest.device[i]^=1;}
 for(size_t i=0;i<sizeof(cf);i++){r.manifest.config[i]^=1;assert(!descriptor_check(&r,r.handle));r.manifest.config[i]^=1;}
 for(variant=1;variant<=6;variant++)assert(!descriptor_check(&r,r.handle));variant=0;
 expected_phase=OWN_PRE;expected_original=NULL;assert(!operation(&r,ST_SCAN));
 expected_phase=OWN_OPENED;expected_original=&r.original;assert(!operation(&r,ST_RECHECK));assert(registry_calls==3);
 expected_phase=OWN_CAPTURED;assert(operation(&r,ST_POSTCHECK)); /* no successful handoff, no borrowed handle */
 assert(operation(&r,ST_HANDOFF)==1 && r.handle==NULL && r.handed && set_calls==1);
 /* Successful own capture/reset must re-read on the SAME host-owned handle.
    These USB returns remain synthetic fixtures, not measurements. */
 set_result=usb_redir_success;r.handle=(void *)1;assert(!operation(&r,ST_HANDOFF));assert(!r.handle && host_owns);
 control_calls=0;assert(!operation(&r,ST_POSTCHECK));assert(control_calls==3 && host_owns);
 assert(!operation(&r,ST_HOST_CLOSE));assert(!operation(&r,ST_HANDLE_CLOSE));assert(close_calls==2);
 Ops ops={&r,adapter_step,never_stop};
 for(variant=0;variant<=6;variant++){
  r.handle=(void *)1;close_calls=0;control_calls=0;reached_loop=0;
  assert(lifecycle(&ops)==(variant!=0));assert(reached_loop==(variant==0));
  assert(close_calls==1 && !r.handle && !r.borrowed_check && !host_owns);
  if(!variant)assert(control_calls==3);
 }
 variant=0;
 for(size_t i=0;i<sizeof(df)+sizeof(cf);i++){
  unsigned char *pin=i<sizeof(df)?&r.manifest.device[i]:&r.manifest.config[i-sizeof(df)];
  *pin^=1;r.handle=(void *)1;close_calls=0;reached_loop=0;
  assert(lifecycle(&ops));assert(!reached_loop && close_calls==1 && !host_owns && !r.borrowed_check);*pin^=1;
 }
 puts("PASS postcapture actual adapter+coordinator: same borrowed host-owned handle; 3 raw reads; every device/config pin byte and bad report/session/string/config/short read deny before loop; close once on every outcome");
 assert(init_calls==0); /* Entry point NEVER invoked, including refusal mode. */
}return 0;}
