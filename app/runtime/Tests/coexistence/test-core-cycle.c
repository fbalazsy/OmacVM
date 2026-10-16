/* Real ordinary TU + coordinator + real QOM/USB/QDict/BH, inert USB exports. */
#include "qemu/osdep.h"
#include "qemu/main-loop.h"
#include "system/system.h"
#include "system/runstate.h"
#include "hw/core/qdev-properties.h"
#include "hw/core/sysbus.h"
#include "qapi/qmp-registry.h"
#include "qobject/qjson.h"
#include "host-libusb.c"
#include "host-coexistence.c"
struct libusb_device { unsigned long id; int addr, refs, opens, closes, submits; };
struct libusb_device_handle { libusb_device *dev; };
static libusb_device devices[3]={{55,1},{56,2},{57,3}};
static bool release_error, attach_error, close_reenter;
static bool stream_error, halt_error;
static bool config_error, alt_error, reset_error;
static bool submit_error;
static bool claim_error;
static int init_calls, reset_calls, config_frees;
static USBHostDevice *target;
static struct libusb_transfer *pending[64];
static unsigned pending_count;
static bool callback_close;
static bool attach_close;
static bool abort_dispatch;
static uint64_t callback_epoch;
static USBPacket *held_native_packet;
static struct libusb_endpoint_descriptor endpoints[] = {
 {.bEndpointAddress=0x81,.bmAttributes=2,.wMaxPacketSize=64},
 {.bEndpointAddress=0x01,.bmAttributes=2,.wMaxPacketSize=64}};
static struct libusb_interface_descriptor alt={.bInterfaceNumber=0,.bNumEndpoints=2,.endpoint=endpoints};
static struct libusb_interface intf={.altsetting=&alt,.num_altsetting=1};
static struct libusb_config_descriptor conf={.bNumInterfaces=1,.bConfigurationValue=1,.interface=&intf};
int libusb_init(libusb_context **c) { init_calls++;*c=(void*)&init_calls;return 0; }
int libusb_set_option(libusb_context*c,enum libusb_option o,...) { return 0; }
void libusb_set_debug(libusb_context*c,int n) {}
void libusb_set_pollfd_notifiers(libusb_context*c,libusb_pollfd_added_cb a,libusb_pollfd_removed_cb r,void*d) {}
const struct libusb_pollfd **libusb_get_pollfds(libusb_context*c) { return NULL; }
unsigned long libusb_get_session_data(libusb_device*d) { return d->id; }
libusb_device *libusb_ref_device(libusb_device*d) {d->refs++;return d;}
void libusb_unref_device(libusb_device*d) {assert(d->refs>0);d->refs--;}
ssize_t libusb_get_device_list(libusb_context*c,libusb_device***l) {*l=g_new0(libusb_device*,4);for(int i=0;i<3;i++)(*l)[i]=libusb_ref_device(&devices[i]);return 3;}
void libusb_free_device_list(libusb_device**l,int unref) {for(int i=0;l[i];i++)if(unref)libusb_unref_device(l[i]);g_free(l);}
uint8_t libusb_get_bus_number(libusb_device*d) {return 0;}
uint8_t libusb_get_device_address(libusb_device*d) {return d->addr;}
int libusb_get_device_speed(libusb_device*d) {return LIBUSB_SPEED_FULL;}
int libusb_get_port_numbers(libusb_device*d,uint8_t*p,int n) {*p=d->addr;return 1;}
int libusb_get_device_descriptor(libusb_device*d,struct libusb_device_descriptor*dd) {*dd=(struct libusb_device_descriptor){.idVendor=0xc251,.idProduct=0x1701,.bNumConfigurations=1,.bMaxPacketSize0=64};return 0;}
int libusb_get_config_descriptor(libusb_device*d,uint8_t i,struct libusb_config_descriptor**c) {if(i)return LIBUSB_ERROR_NOT_FOUND;*c=&conf;return 0;}
int libusb_get_active_config_descriptor(libusb_device*d,struct libusb_config_descriptor**c) {*c=&conf;return 0;}
void libusb_free_config_descriptor(struct libusb_config_descriptor*c) {config_frees++;}
int libusb_get_ss_endpoint_companion_descriptor(libusb_context*c,const struct libusb_endpoint_descriptor*e,struct libusb_ss_endpoint_companion_descriptor**o) {return LIBUSB_ERROR_NOT_FOUND;}
void libusb_free_ss_endpoint_companion_descriptor(struct libusb_ss_endpoint_companion_descriptor*d) {}
int libusb_open(libusb_device*d,libusb_device_handle**h) {*h=g_new0(libusb_device_handle,1);(*h)->dev=d;d->opens++;return 0;}
void libusb_close(libusb_device_handle*h) {h->dev->closes++;g_free(h);}
libusb_device *libusb_get_device(libusb_device_handle*h) {return h->dev;}
int libusb_wrap_sys_device(libusb_context*c,intptr_t fd,libusb_device_handle**h) {abort();}
int libusb_kernel_driver_active(libusb_device_handle*h,int i) {return 0;}
int libusb_detach_kernel_driver(libusb_device_handle*h,int i) {return 0;}
int libusb_attach_kernel_driver(libusb_device_handle*h,int i) {return attach_error?LIBUSB_ERROR_IO:0;}
int libusb_claim_interface(libusb_device_handle*h,int i) {return claim_error?LIBUSB_ERROR_BUSY:i?LIBUSB_ERROR_NOT_FOUND:0;}
int libusb_release_interface(libusb_device_handle*h,int i) {return release_error?LIBUSB_ERROR_IO:0;}
int libusb_reset_device(libusb_device_handle*h) {reset_calls++;return reset_error?LIBUSB_ERROR_IO:0;}
int libusb_set_configuration(libusb_device_handle*h,int c) {return config_error?LIBUSB_ERROR_IO:0;}
int libusb_set_interface_alt_setting(libusb_device_handle*h,int i,int a) {return alt_error?LIBUSB_ERROR_IO:0;}
int libusb_clear_halt(libusb_device_handle*h,unsigned char ep) {return halt_error?LIBUSB_ERROR_IO:0;}
int libusb_alloc_streams(libusb_device_handle*h,uint32_t n,unsigned char*e,int count) {return n;}
int libusb_free_streams(libusb_device_handle*h,unsigned char*e,int n) {return stream_error?LIBUSB_ERROR_IO:0;}
int libusb_get_string_descriptor_ascii(libusb_device_handle*h,uint8_t i,unsigned char*d,int n) {return 0;}
struct libusb_transfer *libusb_alloc_transfer(int n) {return g_malloc0(sizeof(struct libusb_transfer)+n*sizeof(struct libusb_iso_packet_descriptor));}
void libusb_free_transfer(struct libusb_transfer*t) {g_free(t);}
int libusb_submit_transfer(struct libusb_transfer*t) {if(submit_error)return LIBUSB_ERROR_IO;assert(pending_count<64);pending[pending_count++]=t;((libusb_device_handle*)t->dev_handle)->dev->submits++;return 0;}
int libusb_cancel_transfer(struct libusb_transfer*t) {t->status=LIBUSB_TRANSFER_CANCELLED;return 0;}
void libusb_transfer_set_stream_id(struct libusb_transfer*t,uint32_t s) {}
uint32_t libusb_transfer_get_stream_id(struct libusb_transfer*t) {return 0;}
int libusb_handle_events_timeout(libusb_context*c,struct timeval*tv) {
 if(close_reenter) {close_reenter=false;usb_host_close(target);}
 while(pending_count) {struct libusb_transfer*t=pending[--pending_count];
  if(t->status==LIBUSB_TRANSFER_COMPLETED) {memset(t->buffer,0xa5,t->length);t->actual_length=t->length;}
  t->callback(t);}return 0;
}
extern void fixture_graph(uint64_t session,bool guard,bool gone);
extern void fixture_native_init(void);
extern void fixture_native_failure(bool denied,bool close_error);
extern void fixture_native_hold(bool hold);
extern USBDevice *fixture_native_device(void);
extern void fixture_native_counts(int*o,int*c,int*r);
extern void fixture_disposal_counts(unsigned*r,unsigned*s,unsigned*c);
extern void fixture_loss_mode(unsigned mode);
void fixture_scan_race(void)
{pthread_mutex_lock(&session_lock);session_find(coex_measured.session)->epoch++;pthread_mutex_unlock(&session_lock);}
extern void fixture_native_wait(void);
extern void fixture_native_create_failure(void);
extern void fixture_postopen_failure(unsigned mode,bool close_error);
extern void fixture_identity_failure(void);
extern void fixture_foreign(void);
static void noop(USBPort*p) {}
static void detach(USBPort*p) {
 if(held_native_packet && held_native_packet->ep->dev==p->dev && usb_packet_is_inflight(held_native_packet)) {
  usb_cancel_packet(held_native_packet);
 }
}
static void attach(USBPort*p) {
 if(attach_close) {
  attach_close=false;usb_host_close(target);
  assert(target->dh && target->session); /* Open's entire frame still owns it. */
 }
}
static void complete(USBPort*p,USBPacket*q) {
 if(abort_dispatch) {abort_dispatch=false;struct timeval tv={0};libusb_handle_events_timeout(ctx,&tv);}
 if(callback_close) {
  callback_close=false;
  assert(usb_host_session_freeze(&devices[0],&callback_epoch));
  usb_host_close(target);
  assert(!usb_host_session_drained(55,callback_epoch));
 }
}
static USBPortOps pops={.attach=attach,.detach=detach,.complete=complete};
static USBBusOps bops;
static const TypeInfo controller_type={.name="coex-test-controller",.parent=TYPE_SYS_BUS_DEVICE};
int (*qemu_main)(void);
#include "core-cycle.inc"
int main(int argc,char**argv)
{
 assert(argc==2);const char*mode=argv[1];
 const char *args[]={"coex-inert-core","-machine","none","-accel","qtest","-nodefaults","-no-user-config","-display","none","-net","none","-S",NULL};
 char *qa[ARRAY_SIZE(args)];for(unsigned i=0;i<ARRAY_SIZE(args);i++)qa[i]=g_strdup(args[i]);
 qemu_init(ARRAY_SIZE(args)-1,qa);
 type_register_static(&controller_type);
 USBBus bus;USBPort ports[4];DeviceState*host=qdev_new("coex-test-controller");
 object_property_add_child(qdev_get_machine(),"test-host",OBJECT(host));
 qdev_realize(host,sysbus_get_default(),&error_abort);
 usb_bus_new(&bus,sizeof(bus),&bops,host);
 for(int i=0;i<4;i++)usb_register_port(&bus,&ports[i],NULL,i,&pops,USB_SPEED_MASK_FULL);
 if(!strcmp(mode,"cycle") || g_str_has_prefix(mode,"native-") || g_str_has_prefix(mode,"guard-gone")) {
  integrated_cycle(&bus,mode);qemu_cleanup(0);return 0;
 }
 if(!strcmp(mode,"submit-error")) {
  target=ordinary_new(&bus,1);USBPacket p;uint8_t data[60]={0};
  usb_packet_init(&p);usb_packet_setup(&p,USB_TOKEN_IN,usb_ep_get(USB_DEVICE(target),USB_TOKEN_IN,1),0,100,false,false);usb_packet_addbuf(&p,data,60);
  submit_error=true;usb_handle_packet(USB_DEVICE(target),&p);assert(p.status==USB_RET_NODEV);
  assert(QTAILQ_EMPTY(&target->requests) && !pending_count);
  usb_packet_cleanup(&p);ordinary_drop(target);qemu_cleanup(0);puts("PASS actual-core failed submit releases request without nonexistent callback");return 0;
 }
 if(!strcmp(mode,"abort-dispatch")) {
  target=ordinary_new(&bus,1);USBPacket p;uint8_t data[60]={0};
  usb_packet_init(&p);usb_packet_setup(&p,USB_TOKEN_IN,usb_ep_get(USB_DEVICE(target),USB_TOKEN_IN,1),0,100,false,false);usb_packet_addbuf(&p,data,60);
  usb_handle_packet(USB_DEVICE(target),&p);assert(p.status==USB_RET_ASYNC);abort_dispatch=true;
  uint64_t epoch;assert(usb_host_session_freeze(&devices[0],&epoch));usb_host_close(target);
  assert(usb_host_session_drained(55,epoch) && !usb_packet_is_inflight(&p));usb_packet_cleanup(&p);
  ordinary_drop(target);qemu_cleanup(0);puts("PASS actual-core abort guest completion may dispatch/free the libusb request");return 0;
 }
 if(!strcmp(mode,"callback-close")) {
  target=ordinary_new(&bus,1);callback_close=true;bulk_read(target);
  assert(usb_host_session_drained(55,callback_epoch));
  ordinary_drop(target);qemu_cleanup(0);puts("PASS actual-core callback reentrant close keeps exact dispatch reservation");return 0;
 }
 if(!strcmp(mode,"retention")) {
  for(unsigned i=0;i<10000;i++) {
   devices[2].id=1000;USBHostSession*s=usb_host_session_acquire(&devices[2]);assert(s);
   usb_host_session_release(&s);assert(!devices[2].refs && session_count==1);
  }
 }
 target=USB_HOST_DEVICE(qdev_new("usb-host"));
 qdev_prop_set_uint32(DEVICE(target),"hostbus",0);qdev_prop_set_uint32(DEVICE(target),"hostaddr",1);
 if(!strcmp(mode,"attach-close")) {
  attach_close=true;Error*err=NULL;
  assert(!qdev_realize(DEVICE(target),BUS(&bus),&err) && err);error_free(err);
  assert(!target->dh && !target->session && devices[0].closes==1);
  object_unparent(OBJECT(target));object_unref(target);qemu_cleanup(0);
  puts("PASS actual-core attach reentrant close deferred through handle frame");return 0;
 }
 qdev_realize(DEVICE(target),BUS(&bus),&error_abort);
 assert(target->dh && devices[0].opens==1 && init_calls==1);
 target->ifs[0].claimed=true;target->ifs[0].detached=true;
 if(!strcmp(mode,"claim-cleanup")) {
  claim_error=true;int before=config_frees;USBPacket p={0};usb_host_set_config(target,1,&p);
  assert(p.status==USB_RET_STALL && config_frees==before+2);
 }
 if(!strcmp(mode,"config-failure")) {
  config_error=true;target->ddesc.bNumConfigurations=2;USBPacket p={0};usb_host_set_config(target,2,&p);assert(p.status==USB_RET_STALL);
 }
 if(!strcmp(mode,"alt-failure")) {
  alt_error=true;USBPacket p={0};usb_host_set_interface(target,0,1,&p);assert(p.status==USB_RET_STALL);
 }
 if(!strcmp(mode,"reset-failure")) {
  reset_error=true;USB_DEVICE(target)->addr=1;target->allow_all_guest_resets=true;usb_host_handle_reset(USB_DEVICE(target));
 }
 if(!strcmp(mode,"stream-failure")) {
  stream_error=true;USBEndpoint*eps[]={usb_ep_get(USB_DEVICE(target),USB_TOKEN_IN,1)};
  usb_host_free_streams(USB_DEVICE(target),eps,1);
 }
 if(!strcmp(mode,"halt-failure")) {
  halt_error=true;USBPacket p={0};
  usb_host_handle_control(USB_DEVICE(target),&p,EndpointOutRequest|USB_REQ_CLEAR_FEATURE,0,1,0,NULL);
  assert(p.status==USB_RET_STALL);
 }
 if(!strcmp(mode,"restore-failure")) {release_error=attach_error=true;}
 if(!strcmp(mode,"reentrant-close")) {
  USBHostRequest*r=usb_host_req_alloc(target,NULL,false,0);
  r->xfer->user_data=r;r->xfer->callback=usb_host_req_complete_data;
  r->xfer->dev_handle=target->dh;
  assert(usb_host_submit_transfer(target,r->xfer)==0);close_reenter=true;
 }
 uint64_t epoch;assert(usb_host_session_freeze(&devices[0],&epoch));
 assert(!usb_host_session_drained(55,epoch));
 if(!strcmp(mode,"freeze-ops")) {
  USBPacket p={0};usb_host_set_config(target,1,&p);assert(!p.status);
  assert(!usb_host_session_drained(55,epoch));
  usb_host_set_interface(target,0,0,&p);assert(!p.status);
  usb_host_handle_control(USB_DEVICE(target),&p,EndpointOutRequest|USB_REQ_CLEAR_FEATURE,0,1,0,NULL);assert(!p.status);
  USBEndpoint*eps[]={usb_ep_get(USB_DEVICE(target),USB_TOKEN_IN,1)};
  assert(!usb_host_alloc_streams(USB_DEVICE(target),eps,1,2));usb_host_free_streams(USB_DEVICE(target),eps,1);
  assert(!usb_host_session_drained(55,epoch));
  target->allow_all_guest_resets=true;usb_host_handle_reset(USB_DEVICE(target));assert(!reset_calls);
 }
 if(!strcmp(mode,"exit")) {
  usb_host_exit_notifier(&target->exit,NULL);
  usb_host_exit_notifier(&target->exit,NULL);
 } else if(!strcmp(mode,"postload")) {
  usb_host_nodev(target);usb_host_post_load(target,1);
  while(target->bh_postld_pending)main_loop_wait(false);
 } else {usb_host_close(target);}
 assert(target->dh==NULL && target->dev==NULL && target->session==NULL);
 if(g_str_has_suffix(mode,"-failure") && strcmp(mode,"restore-failure")) {
  assert(!usb_host_session_drained(55,epoch));
 } else if(!strcmp(mode,"restore-failure")) {
  assert(!usb_host_session_drained(55,epoch));
  assert(target->ifs[0].claimed && target->ifs[0].detached);
 } else {assert(usb_host_session_drained(55,epoch));}
 assert(devices[0].closes==1);
 assert(reset_calls==(!strcmp(mode,"reset-failure")?1:0)); /* Never reset after freeze. */
 qdev_unrealize(DEVICE(target));assert(!target->bh_nodev && !target->bh_postld);
 object_unparent(OBJECT(target));object_unref(target);
 qemu_cleanup(0);
 printf("PASS actual-core ordinary %s closes=1 init=1\n",mode);return 0;
}
