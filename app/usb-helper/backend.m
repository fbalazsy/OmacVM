#import "backend.h"
#import "registry.h"
#include "security.h"
#include "transport.h"
#include "cached.h"
#include "lifecycle.h"
#include "io.h"
#include "supervisor.h"
#include <sys/socket.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <string.h>
typedef struct {
 __unsafe_unretained NSDictionary *selection;
 Process parent,qemu;ProcessSeal seal;Snapshot original;HIDPolicy policy;
 int channel,listener,peer,handed,listening;uint64_t deadline;
 libusb_context *usb;libusb_device_handle *handle,*borrowed;Transport transport;
 uint8_t device[18],config[CONFIG_MAX],report[REPORT_MAX];size_t config_n,report_n;
} Runtime;
static int stop(void *p){Runtime *r=p;char b;ssize_t n=recv(r->channel,&b,1,MSG_PEEK);
 return interrupted || n==0 || n>0 || (n<0&&errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR) || !peer_matches(r->channel,&r->parent) || !seal_live(&r->seal);
}
static int exact(Runtime *r,OwnershipPhase phase){Snapshot s;return !stop(r)&&registry_scan(r->selection,&s,phase,&r->original,NULL)&&(r->peer<0||peer_matches(r->peer,&r->qemu));}
static int open_selected(Runtime *r){
 libusb_device **list=NULL;ssize_t n=libusb_get_device_list(r->usb,&list);if(n<0)return 0;libusb_device *match=NULL;unsigned matches=0;
 for(ssize_t i=0;i<n;i++){struct libusb_device_descriptor d;
  if(libusb_get_session_data(list[i])!=r->original.session||libusb_get_device_address(list[i])!=r->original.address||libusb_get_bus_number(list[i])!=([r->selection[@"location"] unsignedIntValue]>>24))continue;
  if(libusb_get_device_descriptor(list[i],&d)||d.idVendor!=[r->selection[@"vendor"] unsignedIntValue]||d.idProduct!=[r->selection[@"product"] unsignedIntValue]||d.bDeviceClass||d.bDeviceSubClass||d.bDeviceProtocol||d.bNumConfigurations!=1)continue;
  match=list[i];matches++;
 }
 int ok=matches==1 && !libusb_open(match,&r->handle);libusb_free_device_list(list,1);return ok;
}
static int serial_matches(Runtime *r,libusb_device_handle *h,uint8_t index){
 if(!index)return 0;uint8_t languages[256],raw[256];int n=libusb_get_string_descriptor(h,0,0,languages,sizeof(languages));
 if(n<4||languages[0]!=n||languages[1]!=3||(n&1))return 0;unsigned lang=languages[2]|((unsigned)languages[3]<<8);
 n=libusb_get_string_descriptor(h,index,lang,raw,sizeof(raw));if(n<4||raw[0]!=n||raw[1]!=3||(n&1))return 0;
 NSString *s=[[NSString alloc] initWithBytes:raw+2 length:n-2 encoding:NSUTF16LittleEndianStringEncoding];return s&&[s isEqual:r->selection[@"serial"]];
}
static int descriptors(Runtime *r,libusb_device_handle *h,int post){
 if(!h||stop(r))return 0;libusb_device *d=libusb_get_device(h);struct libusb_device_descriptor desc;
 if(libusb_get_session_data(d)!=r->original.session||libusb_get_device_address(d)!=r->original.address||libusb_get_device_descriptor(d,&desc)||!serial_matches(r,h,desc.iSerialNumber)||stop(r))return 0;
 uint8_t raw[18],config[CONFIG_MAX],report[REPORT_MAX];int active=0;
 if(libusb_get_configuration(h,&active)||active!=r->original.configuration)return 0;
 int n=libusb_control_transfer(h,0x80,6,0x0100,0,raw,sizeof(raw),500);
 if(n!=18||!cached_device_matches(raw,&desc)||raw[0]!=18||raw[1]!=1||raw[4]||raw[5]||raw[6]||raw[17]!=1||((unsigned)raw[8]|((unsigned)raw[9]<<8))!=[r->selection[@"vendor"] unsignedIntValue]||((unsigned)raw[10]|((unsigned)raw[11]<<8))!=[r->selection[@"product"] unsignedIntValue]||stop(r))return 0;
 n=libusb_control_transfer(h,0x80,6,0x0200,0,config,sizeof(config),500);HIDPolicy policy={0};
 if(n<0||!hid_config(config,n,&policy)||policy.interface!=r->original.interface||policy.configuration!=active||stop(r))return 0;size_t cn=n;
 n=libusb_control_transfer(h,0x81,6,0x2200,policy.interface,report,policy.report_length,500);
 if(n!=policy.report_length||!hid_report(report,n,&policy)||policy.bytes[0]>policy.in_max||(policy.out_ep&&policy.bytes[1]>policy.out_max)||n!=(int)r->report_n||memcmp(report,r->report,r->report_n)||stop(r))return 0;
 struct libusb_config_descriptor *cached=NULL;
 if(libusb_get_config_descriptor(d,0,&cached))return 0;int same=cached_config_matches(config,cn,cached);libusb_free_config_descriptor(cached);if(!same)return 0;
 if(post)return cn==r->config_n&&!memcmp(config,r->config,cn)&&!memcmp(raw,r->device,18);
 memcpy(r->device,raw,18);memcpy(r->config,config,cn);r->config_n=cn;r->policy=policy;return 1;
}
static int accept_qemu(Runtime *r){
 if(!send_bounded(r->channel,"L",1,100))return 0;r->listening=1;
 while(!stop(r)&&monotonic_ms()<r->deadline){
  struct pollfd f={r->listener,POLLIN,0};if(poll(&f,1,20)<0&&errno!=EINTR)return 0;
  if(!(f.revents&POLLIN))continue;r->peer=accept(r->listener,NULL,NULL);
  if(r->peer<0){if(errno==EAGAIN||errno==EINTR)continue;return 0;}
  close(r->listener);r->listener=-1;
  if(!nonblocking(r->peer)||!peer_matches(r->peer,&r->qemu)||!seal_live(&r->seal))return 0;
  int limit=65536;if(setsockopt(r->peer,SOL_SOCKET,SO_SNDBUF,&limit,sizeof(limit))||setsockopt(r->peer,SOL_SOCKET,SO_RCVBUF,&limit,sizeof(limit)))return 0;
  return exact(r,OWN_OPENED);
 }return 0;
}
static int event_loop(Runtime *r){
 while(!stop(r)){@autoreleasepool {
  if(!exact(r,OWN_CAPTURED)||!transport_flush(&r->transport))return 1;
  struct pollfd f={r->peer,POLLIN,0};int n=poll(&f,1,5);if(n<0&&errno!=EINTR)return 1;
  if(f.revents&(POLLHUP|POLLERR|POLLNVAL))return 1;
  if((f.revents&POLLIN)&&(!transport_read(&r->transport)||!exact(r,OWN_CAPTURED)))return 1;
  if(usbredirhost_has_data_to_write(r->transport.host)>32)return 1;
  struct timeval tv={0,0};int rc=libusb_handle_events_timeout_completed(r->usb,&tv,NULL);if(rc&&rc!=LIBUSB_ERROR_INTERRUPTED)return 1;
 }}return 0;
}
static int operation(void *p,Stage s){Runtime *r=p;
 switch(s){
 case ST_AUTH:return !peer_matches(r->channel,&r->parent)||!seal_live(&r->seal);
 case ST_SCAN:{NSData *report=nil;if(!registry_scan(r->selection,&r->original,OWN_PRE,NULL,&report)||!report.length||report.length>REPORT_MAX)return 1;memcpy(r->report,report.bytes,report.length);r->report_n=report.length;return 0;}
 case ST_INIT:return libusb_init_context(&r->usb,NULL,0)!=0;
 case ST_OPEN:return !open_selected(r);
 case ST_RECHECK:return !exact(r,OWN_OPENED)||!descriptors(r,r->handle,0)||!exact(r,OWN_OPENED)||!accept_qemu(r);
 case ST_HOST:return !transport_open(&r->transport,r->peer,r->usb,&r->policy);
 case ST_HANDOFF:{libusb_device_handle *owned=r->handle;r->handle=NULL;r->handed=1;if(usbredirhost_set_device(r->transport.host,owned)!=usb_redir_success)return 1;r->borrowed=owned;return 0;}
 case ST_POSTCHECK:{libusb_device_handle *h=r->borrowed;r->borrowed=NULL;if(!exact(r,OWN_CAPTURED)||!descriptors(r,h,1)||!exact(r,OWN_CAPTURED))return 1;return !send_bounded(r->channel,"P",1,100);}
 case ST_LOOP:return event_loop(r);
 case ST_HOST_CLOSE:r->borrowed=NULL;transport_close(&r->transport);return 0;
 case ST_HANDLE_CLOSE:if(r->handle){libusb_close(r->handle);r->handle=NULL;}return 0;
 case ST_EXIT:if(r->usb){libusb_exit(r->usb);r->usb=NULL;}return 0;
 case ST_SOCKET_CLOSE:if(r->peer>=0){close(r->peer);r->peer=-1;}if(r->listener>=0){close(r->listener);r->listener=-1;}return 0;
 default:return 1;
 }
}
int backend_run(NSDictionary *request,int channel,int listener,const Process *parent){
 Runtime r={.selection=request[@"device"],.parent=*parent,.qemu=request_process(request[@"qemu"]),.channel=channel,.listener=listener,.peer=-1,.deadline=monotonic_ms()+30000};
 if(!seal_process(&r.qemu,&r.seal))return 3;Ops ops={&r,operation,stop};(void)lifecycle(&ops);
 /* Library return/worker normal exit proves handle/context closure, not HID
    restoration. A bounded, same-generation observation is a separate flag. */
 if(!r.handed)return r.listening?2:3;
 for(unsigned i=0;i<20;i++){Snapshot after;NSData *report=nil;
  if(registry_scan(r.selection,&after,OWN_PRE,&r.original,&report)&&report.length==r.report_n&&!memcmp(report.bytes,r.report,r.report_n))return 0;
  usleep(25000);
 }return 2;
}
