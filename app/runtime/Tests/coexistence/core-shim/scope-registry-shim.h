/* Test-only registry graph: real CF values, no native calls. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "review-native-shim.h"
static struct {
    const char *cls;
    unsigned parent;
    CFMutableDictionaryRef props;
    bool unreadable;
} scope_nodes[80];
static unsigned scope_count, scope_reads, scope_created, scope_create_reads;
static bool scope_invalid, scope_class_fail, scope_parent_fail;
static struct { unsigned nodes[80], count, at; } scope_iter[80];
static unsigned scope_iters;
static void scope_num(unsigned n, CFStringRef key, int64_t x)
{
    CFNumberRef v=CFNumberCreate(NULL,kCFNumberSInt64Type,&x);
    CFDictionarySetValue(scope_nodes[n].props,key,v); CFRelease(v);
}
static void scope_usage(unsigned n)
{
    scope_num(n,CFSTR("PrimaryUsagePage"),0xff00);
    scope_num(n,CFSTR("PrimaryUsage"),1);
    CFMutableDictionaryRef p=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    int page=0xff00,usage=1;
    CFNumberRef a=CFNumberCreate(NULL,kCFNumberIntType,&page),b=CFNumberCreate(NULL,kCFNumberIntType,&usage);
    CFDictionarySetValue(p,CFSTR("DeviceUsagePage"),a);CFDictionarySetValue(p,CFSTR("DeviceUsage"),b);
    const void *values[]={p}; CFArrayRef arr=CFArrayCreate(NULL,values,1,&kCFTypeArrayCallBacks);
    CFDictionarySetValue(scope_nodes[n].props,CFSTR("DeviceUsagePairs"),arr);
    CFRelease(arr);CFRelease(p);CFRelease(a);CFRelease(b);
}
static unsigned scope_node(const char *cls,unsigned parent)
{
    unsigned n=++scope_count;g_assert_cmpuint(n,<,80);
    scope_nodes[n].cls=cls;scope_nodes[n].parent=parent;
    scope_nodes[n].props=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    return n;
}
static void scope_init(void)
{
    if(scope_count)return;
    scope_node("AppleUserHIDDevice",3);scope_node("IOUSBHostDevice",0);
    scope_node("IOUSBHostInterface",2);scope_node("IOHIDInterface",1);
    scope_node("AppleUSBHostCompositeDevice",2);
    scope_usage(1);scope_usage(4);
    scope_num(2,CFSTR("idVendor"),0xc251);scope_num(2,CFSTR("idProduct"),0x1701);scope_num(2,CFSTR("bDeviceClass"),0);
    CFDataRef descriptor=CFDataCreate(NULL,fixture,sizeof(fixture));
    CFDictionarySetValue(scope_nodes[1].props,CFSTR("ReportDescriptor"),descriptor);CFRelease(descriptor);
    scope_num(3,CFSTR("bInterfaceClass"),3);scope_num(3,CFSTR("bInterfaceSubClass"),0);scope_num(3,CFSTR("bInterfaceProtocol"),0);
}
static boolean_t scope_conforms(io_object_t e,const io_name_t name)
{
    scope_init();
    if(e==1 && !strcmp(name,"IOHIDDevice"))return true; /* includes specialized negative */
    return e<=scope_count && !strcmp(scope_nodes[e].cls,name);
}
static kern_return_t scope_class(io_object_t e,io_name_t name)
{
    scope_reads++;scope_init();if(scope_class_fail || !e || e>scope_count)return KERN_FAILURE;
    g_strlcpy(name,scope_nodes[e].cls,sizeof(io_name_t));return KERN_SUCCESS;
}
static kern_return_t scope_parent(io_registry_entry_t e,const io_name_t p,io_registry_entry_t *out)
{
    scope_reads++;scope_init();*out=scope_nodes[e].parent;
    return *out && !scope_parent_fail?KERN_SUCCESS:KERN_FAILURE;
}
static kern_return_t scope_children(io_registry_entry_t e,const io_name_t p,io_iterator_t *out)
{
    scope_reads++;scope_init();if(scope_nodes[e].unreadable)return KERN_FAILURE;
    unsigned k=++scope_iters;g_assert_cmpuint(k,<,80);*out=k+100;
    for(unsigned n=1;n<=scope_count;n++)if(scope_nodes[n].parent==e)scope_iter[k].nodes[scope_iter[k].count++]=n;
    return KERN_SUCCESS;
}
static kern_return_t scope_recursive(io_registry_entry_t e,const io_name_t p,IOOptionBits o,io_iterator_t *out)
{
    scope_reads++;scope_init();unsigned k=++scope_iters;*out=k+100;
    for(unsigned n=1;n<=scope_count;n++)if(n!=2)scope_iter[k].nodes[scope_iter[k].count++]=n;
    return KERN_SUCCESS;
}
static io_object_t scope_next(io_iterator_t it)
{ unsigned k=it-100;return scope_iter[k].at<scope_iter[k].count?scope_iter[k].nodes[scope_iter[k].at++]:0; }
static boolean_t scope_valid(io_iterator_t it){return !scope_invalid;}
static kern_return_t scope_props(io_registry_entry_t e,CFMutableDictionaryRef *out,CFAllocatorRef a,IOOptionBits o)
{
    scope_reads++;scope_init();if(scope_nodes[e].unreadable)return KERN_FAILURE;
    if(e==3)scope_num(3,CFSTR("bInterfaceProtocol"),shim_protocol);
    *out=CFDictionaryCreateMutableCopy(NULL,0,scope_nodes[e].props);return KERN_SUCCESS;
}
static CFTypeRef scope_prop(io_registry_entry_t e,CFStringRef key,CFAllocatorRef a,IOOptionBits o)
{
    scope_reads++;scope_init();if(scope_nodes[e].unreadable)return NULL;
    if(e==3)scope_num(3,CFSTR("bInterfaceProtocol"),shim_protocol);
    if(e==1 && use_numbered && CFEqual(key,CFSTR("ReportDescriptor"))) {
        uint8_t desc[sizeof(fixture)+2];memcpy(desc,fixture,sizeof(fixture));
        memmove(desc+9,desc+7,sizeof(fixture)-7);desc[7]=0x85;desc[8]=7;
        return CFDataCreate(NULL,desc,sizeof(desc));
    }
    CFTypeRef v=CFDictionaryGetValue(scope_nodes[e].props,key);return v?CFRetain(v):NULL;
}
static kern_return_t scope_id(io_registry_entry_t e,uint64_t *id)
{scope_reads++;*id=e==1?shim_id+review_registry_delta:10000+e;return KERN_SUCCESS;}
static IOHIDDeviceRef scope_create(CFAllocatorRef a,io_service_t e)
{scope_created++;scope_create_reads=scope_reads;return shim_create(a,e);}
static io_service_t scope_service(mach_port_t p,CFDictionaryRef m)
{
    static unsigned extra;
    scope_init();scope_iters=0;memset(scope_iter,0,sizeof(scope_iter));
    if(extra && shim_interfaces==1){CFRelease(scope_nodes[extra].props);scope_count--;extra=0;}
    if(shim_interfaces==2 && !extra){unsigned n=scope_node("IOUSBHostInterface",2);extra=n;scope_num(n,CFSTR("bInterfaceClass"),3);scope_num(n,CFSTR("bInterfaceSubClass"),0);scope_num(n,CFSTR("bInterfaceProtocol"),0);}
    return shim_service(p,m);
}
#undef IOServiceGetMatchingService
#undef IOObjectConformsTo
#undef IORegistryEntryGetParentEntry
#undef IORegistryEntryCreateIterator
#undef IOIteratorNext
#undef IORegistryEntryCreateCFProperty
#undef IORegistryEntryGetRegistryEntryID
#undef IOHIDDeviceCreate
#define IOServiceGetMatchingService scope_service
#define IOObjectConformsTo scope_conforms
#define IOObjectGetClass scope_class
#define IORegistryEntryGetParentEntry scope_parent
#define IORegistryEntryCreateIterator scope_recursive
#define IORegistryEntryGetChildIterator scope_children
#define IOIteratorNext scope_next
#define IOIteratorIsValid scope_valid
#define IORegistryEntryCreateCFProperty scope_prop
#define IORegistryEntryCreateCFProperties scope_props
#define IORegistryEntryGetRegistryEntryID scope_id
#define IOHIDDeviceCreate scope_create
#pragma clang diagnostic pop
