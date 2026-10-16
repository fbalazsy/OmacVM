/* No-hardware IOKit API boundary. Real CF objects and libdispatch scheduling.
 * Every native IOKit symbol referenced by dev-host-hid.c is replaced here. */
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <dispatch/dispatch.h>
#include <Block.h>
static uint64_t shim_id;
static IOReturn review_result;
static int review_length_delta, review_registry_delta, review_no_service;
static int review_open_attempts, review_get_calls, review_set_calls;
static bool review_hold_get, review_complete_on_cancel;
static IOHIDReportCallback review_pending_cb;
static void *review_pending_ctx;
static uint8_t *review_pending_data;
static CFIndex review_pending_len;
static IOHIDReportType review_pending_type;
static CFIndex review_pending_id;
static IOHIDDeviceRef review_pending_device;
static int shim_interfaces=1, shim_protocol, shim_cursor, shim_denied;
static bool shim_wrong_identity;
static dispatch_queue_t shim_queue;
static dispatch_block_t shim_cancel;
static IOHIDReportCallback shim_input;
static IOHIDCallback shim_removed;
static void *shim_context;
static CFMutableDictionaryRef shim_matching(uint64_t id)
{
    shim_id=id;
    return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
static io_service_t shim_service(mach_port_t port, CFDictionaryRef match)
{ CFRelease(match); return review_no_service?0:1; }
static kern_return_t shim_registry(io_registry_entry_t e, uint64_t *id)
{ *id=shim_id+review_registry_delta; return KERN_SUCCESS; }
static boolean_t shim_conforms(io_object_t e, const io_name_t name)
{
    return (e==1 && !strcmp(name,"IOHIDDevice")) ||
           (e==2 && !strcmp(name,"IOUSBHostDevice")) ||
           (e>=3 && e<20 && !strcmp(name,"IOUSBHostInterface"));
}
static kern_return_t shim_parent(io_registry_entry_t e,const io_name_t plane,io_registry_entry_t *parent)
{ *parent=2; return e==1?KERN_SUCCESS:KERN_FAILURE; }
static kern_return_t shim_retain(io_object_t e) { return KERN_SUCCESS; }
static kern_return_t shim_release(io_object_t e) { return KERN_SUCCESS; }
static kern_return_t shim_iterator(io_registry_entry_t e,const io_name_t plane,IOOptionBits options,io_iterator_t *it)
{ g_assert_cmpint(e,==,2); *it=100; shim_cursor=0; return KERN_SUCCESS; }
static io_object_t shim_next(io_iterator_t it)
{ return shim_cursor<shim_interfaces?3+shim_cursor++:0; }
static CFTypeRef shim_registry_prop(io_registry_entry_t e,CFStringRef key,CFAllocatorRef allocator,IOOptionBits options)
{
    int n=CFEqual(key,CFSTR("bInterfaceClass"))?3:CFEqual(key,CFSTR("bInterfaceProtocol"))?shim_protocol:0;
    return CFNumberCreate(NULL,kCFNumberIntType,&n);
}
static IOHIDDeviceRef shim_create(CFAllocatorRef allocator,io_service_t service)
{
    CFMutableDictionaryRef d=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d,CFSTR(kIOHIDSerialNumberKey),CFSTR("tFIXTUR0E123"));
    CFDictionarySetValue(d,CFSTR(kIOHIDProductKey),CFSTR("BaldurBootLoader"));
    CFDictionarySetValue(d,CFSTR(kIOHIDTransportKey),CFSTR("USB"));
    int v=shim_wrong_identity?1:0xc251, p=0x1701;
    CFNumberRef vendor=CFNumberCreate(NULL,kCFNumberIntType,&v), product=CFNumberCreate(NULL,kCFNumberIntType,&p);
    CFDictionarySetValue(d,CFSTR(kIOHIDVendorIDKey),vendor); CFRelease(vendor);
    CFDictionarySetValue(d,CFSTR(kIOHIDProductIDKey),product); CFRelease(product);
    uint8_t desc[sizeof(fixture)+2]; memcpy(desc,fixture,sizeof(fixture));
    if(use_numbered) { memmove(desc+9,desc+7,sizeof(fixture)-7); desc[7]=0x85; desc[8]=7; }
    CFDataRef report=CFDataCreate(NULL,desc,sizeof(fixture)+(use_numbered?2:0));
    CFDictionarySetValue(d,CFSTR(kIOHIDReportDescriptorKey),report); CFRelease(report);
    return (IOHIDDeviceRef)d;
}
static CFTypeRef shim_prop(IOHIDDeviceRef d,CFStringRef key)
{ return CFDictionaryGetValue((CFDictionaryRef)d,key); }
static IOReturn shim_open(IOHIDDeviceRef d,IOOptionBits options)
{ g_assert_cmpuint(options,==,kIOHIDOptionsTypeNone); review_open_attempts++; if(shim_denied) return kIOReturnNotPermitted; opened++; return 0; }
static IOReturn shim_close(IOHIDDeviceRef d,IOOptionBits options)
{ closed++; return 0; }
static void shim_set_queue(IOHIDDeviceRef d,dispatch_queue_t queue) { shim_queue=queue; }
static void shim_set_cancel(IOHIDDeviceRef d,dispatch_block_t block) { shim_cancel=Block_copy(block); }
static void shim_activate(IOHIDDeviceRef d) {}
static void shim_cancel_device(IOHIDDeviceRef d)
{
    if (review_complete_on_cancel && review_pending_cb) {
        dispatch_async(shim_queue,^{
            g_assert_nonnull(review_pending_data);
            review_pending_data[review_pending_len-1]=0x5a;
            review_pending_cb(review_pending_ctx,kIOReturnAborted,review_pending_device,review_pending_type,review_pending_id,review_pending_data,review_pending_len);
        });
    }
    dispatch_async(shim_queue,shim_cancel); Block_release(shim_cancel); shim_cancel=NULL;
}
static void shim_register_input(IOHIDDeviceRef d,uint8_t *report,CFIndex len,IOHIDReportCallback cb,void *ctx)
{ g_assert_cmpint(len,==,64); shim_input=cb; shim_context=ctx; }
static void shim_register_removal(IOHIDDeviceRef d,IOHIDCallback cb,void *ctx)
{ shim_removed=cb; }
static IOReturn shim_set_report(IOHIDDeviceRef d,IOHIDReportType type,CFIndex id,const uint8_t *data,CFIndex len,CFTimeInterval timeout,IOHIDReportCallback callback,void *ctx)
{
    review_set_calls++;
    if(fail_report) return kIOReturnError;
    g_assert_cmpuint(id,==,use_numbered?7:0); g_assert_cmpuint(type,>=,1); g_assert_cmpuint(type,<=,2);
    g_assert_cmpint(len,==,(type==2?1:60)+(use_numbered?1:0)); g_assert_cmpint(timeout,==,1000);
    for(CFIndex i=!!id;i<len;i++) g_assert_cmphex(data[i],==,0x5a);
    if(hold_report) {
        review_pending_cb=callback; review_pending_ctx=ctx; review_pending_device=d;
        review_pending_data=(uint8_t *)data; review_pending_len=len;
        review_pending_type=type; review_pending_id=id;
    } else dispatch_async(shim_queue,^{callback(ctx,review_result,d,type,id,(uint8_t *)data,len+review_length_delta);});
    return 0;
}
static IOReturn shim_get_report(IOHIDDeviceRef d,IOHIDReportType type,CFIndex id,uint8_t *data,CFIndex *length,CFTimeInterval timeout,IOHIDReportCallback callback,void *ctx)
{
    review_get_calls++;
    if(fail_report) return kIOReturnError;
    CFIndex len=*length;
    g_assert_cmpuint(id,==,use_numbered?7:0); g_assert_cmpuint(type,<=,2);
    g_assert_cmpint(len,==,(type==2?1:60)+(use_numbered?1:0)); g_assert_cmpint(timeout,==,1000);
    if(review_hold_get) {
        review_pending_cb=callback; review_pending_ctx=ctx; review_pending_device=d;
        review_pending_data=data; review_pending_len=len;
        review_pending_type=type; review_pending_id=id;
    } else dispatch_async(shim_queue,^{memset(data+!!id,0xa5,len-!!id); callback(ctx,review_result,d,type,id,data,len+review_length_delta);});
    return 0;
}
#define IORegistryEntryIDMatching shim_matching
#define IOServiceGetMatchingService shim_service
#define IORegistryEntryGetRegistryEntryID shim_registry
#define IOObjectConformsTo shim_conforms
#define IORegistryEntryGetParentEntry shim_parent
#define IOObjectRetain shim_retain
#define IOObjectRelease shim_release
#define IORegistryEntryCreateIterator shim_iterator
#define IOIteratorNext shim_next
#define IORegistryEntryCreateCFProperty shim_registry_prop
#define IOHIDDeviceCreate shim_create
#define IOHIDDeviceGetProperty shim_prop
#define IOHIDDeviceOpen shim_open
#define IOHIDDeviceClose shim_close
#define IOHIDDeviceSetDispatchQueue shim_set_queue
#define IOHIDDeviceSetCancelHandler shim_set_cancel
#define IOHIDDeviceActivate shim_activate
#define IOHIDDeviceCancel shim_cancel_device
#define IOHIDDeviceRegisterInputReportCallback shim_register_input
#define IOHIDDeviceRegisterRemovalCallback shim_register_removal
#define IOHIDDeviceSetReportWithCallback shim_set_report
#define IOHIDDeviceGetReportWithCallback shim_get_report
