#import <Foundation/Foundation.h>
#include "policy.h"
#include "lifecycle.h"
#include "native_auth.h"
#include "native_registry.h"
#include "transport.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include "continuous_clock.h"
#include "../activation/bounded_output.h"
#include "../activation/session_socket.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static volatile sig_atomic_t stopped;
static void stop_signal(int s){stopped=s;}
/* Last-resort wall-clock bound: does not claim successful USB cleanup. */
static void hard_deadline(int s){(void)s;_exit(124);}

typedef struct {Manifest manifest;Snapshot original;double start;int listener,peer,dir;libusb_context *usb;libusb_device_handle *handle;/* Borrowed only between successful handoff and postcheck; host owns it. */libusb_device_handle *borrowed_check;Transport transport;int handed;} Runtime;
static int stop(void *p){Runtime *r=p;uint64_t now=continuous_ns();return stopped || !now || (r->manifest.lease && (r->manifest.deadline_ns<3000000000 || now>=r->manifest.deadline_ns-3000000000));}
static int socket_cleanup(Runtime *r){
 int rc=0;if(r->peer>=0){close(r->peer);r->peer=-1;}if(r->listener>=0){close(r->listener);r->listener=-1;}
 /* Supervisor retains the exact inode until confirmed child reap. */
 if(r->dir>=0){close(r->dir);r->dir=-1;}return rc;
}
static int accept_peer(Runtime *r){
 r->dir=secure_dir(FIXED_DIR);if(r->dir<0)return 1;struct stat st;
 if(fstat(r->dir,&st) || (st.st_mode&07777)!=0711)return 1;
 if(session_socket_validate(BALDUR_LISTENER_FD,FIXED_SOCKET,PROFILE_UID))return 1;
 r->listener=BALDUR_LISTENER_FD;
 if(fcntl(r->listener,F_SETFD,FD_CLOEXEC) || fcntl(r->listener,F_SETFL,O_NONBLOCK))return 1;

 fprintf(stderr,"socket-ready: %s; no USB initialized\n",FIXED_SOCKET);
 while(!stop(r)){
  struct pollfd pollfd={r->listener,POLLIN,0};int n=poll(&pollfd,1,50);
  if(n<0){if(errno==EINTR)continue;return 1;}if(!n)continue;
  r->peer=accept(r->listener,NULL,NULL);if(r->peer<0){if(errno==EAGAIN || errno==EINTR)continue;return 1;}
  close(r->listener);r->listener=-1;
  if(fcntl(r->peer,F_SETFD,FD_CLOEXEC) || fcntl(r->peer,F_SETFL,O_NONBLOCK))return 1;
  int limit=65536;if(setsockopt(r->peer,SOL_SOCKET,SO_SNDBUF,&limit,sizeof(limit)) || setsockopt(r->peer,SOL_SOCKET,SO_RCVBUF,&limit,sizeof(limit)))return 1;
  return !peer_auth(r->peer,&r->manifest);
 }
 return 1;
}
static int open_target(Runtime *r){
 libusb_device **list=NULL;ssize_t n=libusb_get_device_list(r->usb,&list);if(n<0)return 1;
 libusb_device *match=NULL;unsigned count=0;
 for(ssize_t i=0;i<n;i++){
  struct libusb_device_descriptor d;if(libusb_get_device_descriptor(list[i],&d))continue;
  if(d.idVendor!=PROFILE_VID || d.idProduct!=PROFILE_PID)continue;
  count++;
  if(libusb_get_session_data(list[i])==r->original.session && libusb_get_bus_number(list[i])==PROFILE_BUS && libusb_get_device_address(list[i])==r->original.address && !d.bDeviceClass && !d.bDeviceSubClass && !d.bDeviceProtocol && d.bNumConfigurations==1)match=list[i];
 }
 int rc=1;if(count==1 && match)rc=libusb_open(match,&r->handle)!=0;
 libusb_free_device_list(list,1);return rc;
}
static int descriptor_check(Runtime *r,libusb_device_handle *handle){
 if(!handle)return 0;libusb_device *d=libusb_get_device(handle);struct libusb_device_descriptor desc;
 if(libusb_get_session_data(d)!=r->original.session || libusb_get_device_descriptor(d,&desc) || !desc.iProduct || !desc.iSerialNumber)return 0;
 unsigned char serial[64]={0},product[64]={0},config[34],report[33];
 int ns=libusb_get_string_descriptor_ascii(handle,desc.iSerialNumber,serial,sizeof(serial));
 int np=libusb_get_string_descriptor_ascii(handle,desc.iProduct,product,sizeof(product));
 if(ns!=(int)sizeof(PROFILE_SERIAL)-1 || np!=(int)sizeof(PROFILE_PRODUCT)-1 || memcmp(serial,PROFILE_SERIAL,sizeof(PROFILE_SERIAL)) || memcmp(product,PROFILE_PRODUCT,sizeof(PROFILE_PRODUCT)))return 0;
 int active=0;if(libusb_get_configuration(handle,&active) || active!=1)return 0;
 unsigned char raw_device[18];
 int n=libusb_control_transfer(handle,0x80,LIBUSB_REQUEST_GET_DESCRIPTOR,0x0100,0,raw_device,sizeof(raw_device),500);
 if(n!=sizeof(raw_device) || memcmp(raw_device,r->manifest.device,sizeof(raw_device)))return 0;
 n=libusb_control_transfer(handle,0x80,LIBUSB_REQUEST_GET_DESCRIPTOR,0x0200,0,config,sizeof(config),500);
 if(n!=sizeof(config) || !config_policy(config,sizeof(config)) || memcmp(config,r->manifest.config,sizeof(config)))return 0;
 n=libusb_control_transfer(handle,0x81,LIBUSB_REQUEST_GET_DESCRIPTOR,0x2200,0,report,sizeof(report),500);
 return n==sizeof(report) && report_policy(report,sizeof(report));
}
static int still_exact(Runtime *r,OwnershipPhase phase){Snapshot s;return peer_auth(r->peer,&r->manifest) && registry_scan(&s,phase,&r->original);}
static int event_loop(Runtime *r){
 while(!stop(r)){
  @autoreleasepool {
   if(!still_exact(r,OWN_CAPTURED) || !transport_flush(&r->transport))return 1;
   struct pollfd p={r->peer,POLLIN,0};int n=poll(&p,1,5);if(n<0 && errno!=EINTR)return 1;
   if(n>0 && (p.revents&(POLLHUP|POLLERR|POLLNVAL)))return 1;
   if(n>0 && (p.revents&POLLIN)){
    if(!transport_read(&r->transport) || !still_exact(r,OWN_CAPTURED))return 1;
   }
   /* Limit output accumulation while guest is stalled. */
   if(usbredirhost_has_data_to_write(r->transport.host)>32)return 1;
   struct timeval tv={0,0};int rc=libusb_handle_events_timeout_completed(r->usb,&tv,NULL);
   if(rc && rc!=LIBUSB_ERROR_INTERRUPTED)return 1;
  }
 }
 return 0;
}
static int operation(void *p,Stage s){
 Runtime *r=p;int rc=0;fprintf(stderr,"stage=%d\n",s);
 switch(s){
 case ST_AUTH:return accept_peer(r);
 case ST_SCAN:return !registry_scan(&r->original,OWN_PRE,NULL);
 case ST_INIT:return libusb_init_context(&r->usb,NULL,0)!=0;
 case ST_OPEN:return open_target(r);
 case ST_RECHECK:return !still_exact(r,OWN_OPENED) || !descriptor_check(r,r->handle) || !still_exact(r,OWN_OPENED);
 case ST_HOST:return !transport_open(&r->transport,r->peer,r->usb);
 case ST_HANDOFF:{
  libusb_device_handle *owned=r->handle;r->handle=NULL;r->borrowed_check=NULL;r->handed=1;
  if(usbredirhost_set_device(r->transport.host,owned)!=usb_redir_success)return 1;
  /* No guest reads/event service occurs until ST_POSTCHECK consumes this borrow. */
  r->borrowed_check=owned;return 0;
 }
 case ST_POSTCHECK:{
  libusb_device_handle *borrowed=r->borrowed_check;r->borrowed_check=NULL;
  int valid=still_exact(r,OWN_CAPTURED) && descriptor_check(r,borrowed) && still_exact(r,OWN_CAPTURED);
  if(!valid)fputs("postcapture-reject: original registry/peer/raw descriptor pins required; host retains cleanup ownership\n",stderr);
  if(valid && bounded_output(STDOUT_FILENO,"{\"helper\":\"postcheck\"}\n"))return 1;
  return !valid;
 }
 case ST_LOOP:fprintf(stderr,"ready: root USB owner; authenticated profile UID peer; passthrough NOT YET verified\n");return event_loop(r);
 case ST_HOST_CLOSE:r->borrowed_check=NULL;transport_close(&r->transport);break;
 case ST_HANDLE_CLOSE:if(r->handle){libusb_close(r->handle);r->handle=NULL;}break;
 case ST_EXIT:if(r->usb){libusb_exit(r->usb);r->usb=NULL;}break;
 case ST_SOCKET_CLOSE:rc=socket_cleanup(r);break;
 default:return 1;
 }
 return rc;
}
int main(int argc,const char *argv[]){
 if(PROFILE_FIXTURE || !invocation(argc,argv,getuid(),geteuid())){fputs("refuse: root-only fixed --serve; no USB initialized\n",stderr);return 64;}
 @autoreleasepool {
  Runtime r={.listener=-1,.peer=-1,.dir=-1};
  if(!executable_protected() || !load_manifest(&r.manifest)){fputs("refuse: immutable root executable/peer manifest required; no USB initialized\n",stderr);return 65;}
  /* Tiny leases cannot reserve bounded graceful-cleanup time. */
  if(r.manifest.lease && r.manifest.lease<5){fputs("refuse: lease must be session(0) or 5..120 seconds\n",stderr);return 65;}
  struct rlimit core={0,0};if(setrlimit(RLIMIT_CORE,&core))return 65;
  umask(077);uint64_t now=continuous_ns();if(!deadline_valid(now,r.manifest.deadline_ns,r.manifest.lease))return 65;
  struct sigaction sa={0};sigemptyset(&sa.sa_mask);sa.sa_handler=stop_signal;
  if(sigaction(SIGINT,&sa,NULL) || sigaction(SIGTERM,&sa,NULL) || sigaction(SIGHUP,&sa,NULL))return 65;
  sa.sa_handler=hard_deadline;if(sigaction(SIGALRM,&sa,NULL))return 65;if(r.manifest.lease)alarm((unsigned)((r.manifest.deadline_ns-now+999999999)/1000000000));
  Ops ops={&r,operation,stop};int rc=lifecycle(&ops);
  /* Reappearance may be asynchronous. Observation does not drive another device. */
  if(r.handed){Snapshot after;int restored=registry_scan(&after,OWN_PRE,NULL);fprintf(stderr,"cleanup: host/context closed; HID snapshot restored=%d (physical disconnect may prevent verification)\n",restored);if(!restored)rc=1;}
  alarm(0);return rc;
 }
}
