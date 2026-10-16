/* Entire production native TU, real CF/dispatch/QOM; inert IOKit graph/APIs. */
#include "qemu/osdep.h"
#include <unistd.h>
static const uint8_t fixture[]={0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x15,0x00,0x26,0xff,0x00,0x75,0x08,0x95,0x3c,0x09,0x01,0x81,0x02,0x95,0x3c,0x09,0x01,0x91,0x02,0x95,0x01,0x09,0x01,0xb1,0x02,0xc0};
static int opened,closed;
static bool use_numbered,fail_report,hold_report;
#include "core-shim/hid-sync-core-shim.h"
static uint64_t graph_session=55;
static bool graph_gone,graph_guard,graph_native,graph_close_error;
static bool graph_create_error;
static unsigned graph_postopen;
static IOHIDDeviceRef graph_hid;
static unsigned graph_releases, graph_scans, graph_close_attempts;
static unsigned graph_loss_mode;
static bool graph_cancelled;
extern void fixture_scan_race(void);
static int graph_reports_at_create;
static uint64_t graph_ids[80]={0,33,11,22,34,35,44,66,77};
static void graph_string(unsigned n,CFStringRef key,const char*text)
{
 CFStringRef v=CFStringCreateWithCString(NULL,text,kCFStringEncodingUTF8);
 CFDictionarySetValue(scope_nodes[n].props,key,v);CFRelease(v);
}
static void graph_init(void)
{
 scope_init();
 if(scope_count==5) {
  scope_node("AppleUSBHostDeviceUserClient",2);
  scope_node("AppleUSBHostDeviceUserClient",0);
  scope_node("IOHIDLibUserClient",0);
  char creator[128];snprintf(creator,sizeof(creator),"pid %d, fixture-qemu",getpid());
  graph_string(6,CFSTR("IOUserClientCreator"),creator);
  graph_string(8,CFSTR("IOUserClientCreator"),creator);
  snprintf(creator,sizeof(creator),"pid %d, fixture-launcher",getppid());
  graph_string(7,CFSTR("IOUserClientCreator"),creator);
  graph_string(2,CFSTR("USB Serial Number"),"tFIXTUR0E123");
  graph_string(1,CFSTR(kIOHIDSerialNumberKey),"tFIXTUR0E123");
  graph_string(1,CFSTR(kIOHIDTransportKey),"USB");
  scope_num(1,CFSTR(kIOHIDVendorIDKey),0xc251);scope_num(1,CFSTR(kIOHIDProductIDKey),0x1701);
 }
 scope_num(2,CFSTR("sessionID"),graph_session);
 scope_nodes[7].parent=graph_guard?2:0;
 scope_nodes[8].parent=graph_native?1:0;
 scope_iters=0;memset(scope_iter,0,sizeof(scope_iter));
}
static io_service_t graph_service(mach_port_t p,CFDictionaryRef m)
{
 CFRelease(m);graph_init();
 if(graph_gone)return 0;
 for(unsigned i=1;i<=scope_count;i++)if(graph_ids[i]==shim_id &&
    (i==2 || scope_nodes[i].parent) &&
    !strstr(scope_nodes[i].cls,"UserClient") &&
    strcmp(scope_nodes[i].cls,"AppleUSBHostCompositeDevice"))return i;
 return 0;
}
static kern_return_t graph_services(mach_port_t p,CFDictionaryRef m,io_iterator_t*out)
{
 io_service_t found=graph_service(p,m);
 *out=found?101:0;scope_iters=1;scope_iter[1].count=found?1:0;scope_iter[1].at=0;scope_iter[1].nodes[0]=found;
 return KERN_SUCCESS;
}
/* Full registry traversal sees unregistered clients/composites too. Parent=0
 * for these synthetic optional clients means not instantiated, not registered. */
static kern_return_t graph_registry(mach_port_t p,const io_name_t plane,
                                    IOOptionBits options,io_iterator_t*out)
{
 assert(!strcmp(plane,kIOServicePlane) && options==kIORegistryIterateRecursively);
 graph_scans++;
 if(graph_loss_mode==1 || (graph_loss_mode==6 && graph_releases))return KERN_FAILURE;
 if(graph_loss_mode==9 && graph_scans==3)return KERN_FAILURE;
 if(graph_loss_mode==7)fixture_scan_race();
 graph_init();
 unsigned k=++scope_iters;assert(k<80);*out=k+100;
 if(!graph_gone)for(unsigned i=1;i<=scope_count;i++)
    if(i==2 || scope_nodes[i].parent)scope_iter[k].nodes[scope_iter[k].count++]=i;
 if(graph_gone && graph_loss_mode>=3 && graph_loss_mode<=5)
    scope_iter[k].nodes[scope_iter[k].count++]=graph_loss_mode==3?2:graph_loss_mode==4?7:8;
 return KERN_SUCCESS;
}
static boolean_t graph_valid(io_iterator_t it)
{return graph_loss_mode==2?false:scope_valid(it);}
static kern_return_t graph_id(io_registry_entry_t e,uint64_t*out)
{assert(e>0 && e<=scope_count);*out=e<=8?graph_ids[e]:10000+e;return KERN_SUCCESS;}
static IOHIDDeviceRef graph_create(CFAllocatorRef a,io_service_t e)
{if(graph_create_error)return NULL;assert(!graph_native);graph_reports_at_create=review_get_calls+review_set_calls;return graph_hid=shim_create(a,e);}
static IOReturn graph_open(IOHIDDeviceRef d,IOOptionBits o)
{
 assert(!graph_native && graph_reports_at_create==review_get_calls+review_set_calls);
 IOReturn r=shim_open(d,o);
 if(!r){
  graph_native=true;scope_nodes[8].parent=1;
  if(graph_postopen==1)scope_node("UnknownForeignClient",2);
  if(graph_postopen==2){unsigned n=scope_node("IOHIDLibUserClient",1);char c[80];snprintf(c,sizeof(c),"pid %d, extra",getpid());graph_string(n,CFSTR("IOUserClientCreator"),c);}
 }
 return r;
}
static IOReturn graph_close(IOHIDDeviceRef d,IOOptionBits o)
{graph_close_attempts++;if(graph_gone || graph_loss_mode==8)return kIOReturnBadArgument;if(graph_close_error)return kIOReturnError;graph_native=false;scope_nodes[8].parent=0;return shim_close(d,o);}
static void graph_set_cancel(IOHIDDeviceRef d,dispatch_block_t block)
{shim_set_cancel(d,^{graph_cancelled=true;block();});}
static void graph_release(CFTypeRef object)
{
 if(object==(CFTypeRef)graph_hid){if(graph_gone)assert(graph_cancelled);graph_releases++;graph_hid=NULL;}
 CFRelease(object);
}
#undef IOServiceGetMatchingService
#undef IORegistryEntryGetRegistryEntryID
#undef IOHIDDeviceCreate
#undef IOHIDDeviceClose
#define IOServiceGetMatchingService graph_service
#define IOServiceGetMatchingServices graph_services
#define IORegistryCreateIterator graph_registry
#define IORegistryEntryGetRegistryEntryID graph_id
#undef IOHIDDeviceOpen
#define IOHIDDeviceOpen graph_open
#define IOHIDDeviceCreate graph_create
#define IOHIDDeviceClose graph_close
#undef IOIteratorIsValid
#define IOIteratorIsValid graph_valid
#undef IOHIDDeviceSetCancelHandler
#define IOHIDDeviceSetCancelHandler graph_set_cancel
#define CFRelease graph_release
#include "dev-host-hid.c"
#undef CFRelease
void fixture_graph(uint64_t session,bool guard,bool gone)
{graph_session=session;graph_guard=guard;graph_gone=gone;
 graph_ids[2]=11+(session-55)*10;graph_ids[1]=33+(session-55)*10;
 graph_ids[3]=22+(session-55)*10;graph_init();}
void fixture_native_init(void)
{sync_entered=dispatch_semaphore_create(0);sync_release=dispatch_semaphore_create(0);}
void fixture_native_failure(bool denied,bool close_error)
{shim_denied=denied;graph_close_error=close_error;}
void fixture_native_create_failure(void) {graph_create_error=true;}
void fixture_postopen_failure(unsigned mode,bool close_error) {graph_postopen=mode;graph_close_error=close_error;}
void fixture_identity_failure(void) {shim_wrong_identity=true;}
void fixture_foreign(void) {scope_node("UnknownForeignClient",2);}
void fixture_native_hold(bool hold)
{sync_hold=hold;if(!hold)dispatch_semaphore_signal(sync_release);}
void fixture_native_wait(void)
{assert(!dispatch_semaphore_wait(sync_entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));}
USBDevice *fixture_native_device(void) {return coex_device?USB_DEVICE(coex_device):NULL;}
void fixture_native_counts(int*o,int*c,int*r)
{*o=opened;*c=closed;*r=review_set_calls+review_get_calls;}
void fixture_disposal_counts(unsigned*r,unsigned*s,unsigned*c)
{*r=graph_releases;*s=graph_scans;*c=graph_close_attempts;}
void fixture_loss_mode(unsigned mode) {graph_loss_mode=mode;}
