/* Actual native parser, tree, measurement and open bodies with inert registry
 * and HID APIs. CoreFoundation values describe synthetic nodes only. */
#include "qemu/osdep.h"
#include "qobject/qdict.h"
#include "qom/object.h"
#include "host-coexistence-platform.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDDevice.h>
typedef struct HostHIDState {
    uint64_t registry_id;
    uint16_t vendorid, productid, sizes[3][256];
    char *serial, *product;
    uint8_t report_desc[1024];
    size_t report_desc_len;
    bool numbered, native_opened;
    IOHIDDeviceRef hid;
    CoexNativeTicket *ticket;
} HostHIDState;
#define kIOMainPortDefault 0
Object *object_dynamic_cast(Object *obj, const char *typename) { return NULL; }
Object *object_dynamic_cast_assert(Object *obj, const char *typename,
                                  const char *file, int line, const char *func) { abort(); }
#define USB_DEVICE(s) (s)
typedef struct Node { uint64_t id; const char *cls; unsigned parent; CFMutableDictionaryRef props; } Node;
static const uint8_t descriptor[] = {0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x15,0x00,0x26,0xff,0x00,0x75,0x08,0x95,0x40,0x09,0x01,0x81,0x02,0xc0};
static bool mutate_descriptor;
static Node nodes[16];
static unsigned node_count, iterator_next[32], iterator_parent[32], iterator_count;
static bool invalid_iterator, matching_error;
static unsigned matching_entry;
static bool registry_error, registry_null, children_error, children_null;
static unsigned id_error, id_zero, repeat_entries;
static unsigned registry_scans;
static bool parent_error, parent_wrong, class_error;
/* Matching only returns registered IOService objects. User clients and the
 * composite remain present in IORegistry but are NOT registered services. */
static bool registered(unsigned n)
{
    return !strstr(nodes[n].cls, "UserClient") &&
        strcmp(nodes[n].cls, "AppleUSBHostCompositeDevice");
}
static unsigned creates, opens, stages;
static CFTypeRef fake_hid;
static void putn(unsigned node, CFStringRef key, int64_t n)
{
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt64Type, &n);
    CFDictionarySetValue(nodes[node].props, key, v); CFRelease(v);
}
static void puts_cf(unsigned node, CFStringRef key, const char *str)
{
    CFStringRef v = CFStringCreateWithCString(NULL, str, kCFStringEncodingUTF8);
    CFDictionarySetValue(nodes[node].props, key, v); CFRelease(v);
}
static unsigned add(uint64_t id, const char *cls, unsigned parent)
{
    unsigned n = ++node_count;
    nodes[n] = (Node){id, cls, parent, CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)};
    return n;
}
static void metadata(unsigned n, int64_t page)
{
    putn(n, CFSTR(kIOHIDPrimaryUsagePageKey), page);
    putn(n, CFSTR(kIOHIDPrimaryUsageKey), 1);
    int64_t one = 1;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberSInt64Type, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberSInt64Type, &one);
    const void *keys[] = {CFSTR(kIOHIDDeviceUsagePageKey),CFSTR(kIOHIDDeviceUsageKey)};
    const void *values[] = {p,u};
    CFDictionaryRef pair = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef pairs = CFArrayCreate(NULL, (const void **)&pair, 1, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(nodes[n].props, CFSTR(kIOHIDDeviceUsagePairsKey), pairs);
    CFRelease(p); CFRelease(u); CFRelease(pair); CFRelease(pairs);
}
static CFMutableDictionaryRef fake_matching(uint64_t id)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int64_t i = id; CFNumberRef v = CFNumberCreate(NULL,kCFNumberSInt64Type,&i);
    CFDictionarySetValue(d, CFSTR("id"),v); CFRelease(v); return d;
}
static io_service_t fake_service(mach_port_t port, CFDictionaryRef match)
{
    int64_t id; CFNumberGetValue(CFDictionaryGetValue(match,CFSTR("id")),kCFNumberSInt64Type,&id); CFRelease(match);
    for (unsigned i=1;i<=node_count;i++) { if (nodes[i].id == id && registered(i)) { return i; } }
    return 0;
}
static kern_return_t fake_services(mach_port_t port, CFDictionaryRef match, io_iterator_t *it)
{
    matching_entry = fake_service(port, match);
    *it = matching_error || !matching_entry ? 0 : 31;
    return matching_error ? KERN_FAILURE : KERN_SUCCESS;
}
static kern_return_t fake_id(io_registry_entry_t e, uint64_t *id)
{ *id=e==id_zero ? 0 : nodes[e].id; return e==id_error ? KERN_FAILURE : KERN_SUCCESS; }
static CFTypeRef fake_property(io_registry_entry_t e, CFStringRef key, CFAllocatorRef alloc, IOOptionBits flags)
{
    CFTypeRef v=CFDictionaryGetValue(nodes[e].props,key); return v ? CFRetain(v) : NULL;
}
static kern_return_t fake_properties(io_registry_entry_t e, CFMutableDictionaryRef *props, CFAllocatorRef alloc, IOOptionBits flags)
{
    *props=CFDictionaryCreateMutableCopy(NULL,0,nodes[e].props); return KERN_SUCCESS;
}
static kern_return_t fake_class(io_object_t e, io_name_t cls)
{ strcpy(cls,nodes[e].cls); return class_error ? KERN_FAILURE : KERN_SUCCESS; }
static boolean_t fake_conforms(io_object_t e, const io_name_t cls)
{
    return !strcmp(nodes[e].cls,cls) || (!strcmp(cls,"IOHIDDevice") && !strcmp(nodes[e].cls,"AppleUserHIDDevice"));
}
static kern_return_t fake_children(io_registry_entry_t e, const io_name_t plane, io_iterator_t *it)
{
    if(children_error || children_null) { *it=0; return children_error ? KERN_FAILURE : KERN_SUCCESS; }
    *it=++iterator_count; assert(iterator_count < 32); iterator_parent[*it]=e; iterator_next[*it]=1; return KERN_SUCCESS;
}
static kern_return_t fake_registry(mach_port_t port, const io_name_t plane,
                                   IOOptionBits options, io_iterator_t *it)
{
    assert(!strcmp(plane,kIOServicePlane) && options==kIORegistryIterateRecursively);
    registry_scans++;
    *it=registry_error || registry_null ? 0 : 30;
    iterator_next[30]=1;
    return registry_error ? KERN_FAILURE : KERN_SUCCESS;
}
static io_object_t fake_next(io_iterator_t it)
{
    if (it == 30) {
        if(repeat_entries) { repeat_entries--; return 1; }
        return iterator_next[30]<=node_count ? iterator_next[30]++ : 0;
    }
    if (it == 31) { unsigned e = matching_entry; matching_entry = 0; return e; }
    if(repeat_entries) { repeat_entries--; return 2; }
    while(iterator_next[it]<=node_count) { unsigned n=iterator_next[it]++; if(nodes[n].parent==iterator_parent[it]) { return n; } }
    return 0;
}
static boolean_t fake_valid(io_iterator_t it) { return !invalid_iterator; }
static kern_return_t fake_release(io_object_t obj) { return KERN_SUCCESS; }
static kern_return_t fake_parent(io_registry_entry_t e, const io_name_t plane, io_registry_entry_t *p)
{
    *p=parent_wrong ? 2 : nodes[e].parent;
    return *p && !parent_error ? KERN_SUCCESS : KERN_FAILURE;
}
static IOHIDDeviceRef fake_create(CFAllocatorRef alloc, io_service_t service)
{
    creates++; fake_hid=CFDictionaryCreateCopy(NULL,nodes[service].props);
    if(mutate_descriptor) {
        CFDataRef d=CFDataCreate(NULL,descriptor,sizeof(descriptor));
        CFDictionarySetValue(nodes[service].props,CFSTR(kIOHIDReportDescriptorKey),d); CFRelease(d);
    }
    return (IOHIDDeviceRef)fake_hid;
}
static CFTypeRef fake_get(IOHIDDeviceRef hid, CFStringRef key) { return CFDictionaryGetValue((CFDictionaryRef)hid,key); }
static IOReturn fake_open(IOHIDDeviceRef hid, IOOptionBits options) {
    assert(!options && stages==3); opens++;
    add(77,"IOHIDLibUserClient",3); puts_cf(node_count,CFSTR("IOUserClientCreator"),"pid 200, qemu");
    return kIOReturnSuccess;
}
#define IORegistryEntryIDMatching fake_matching
#define IOServiceGetMatchingService fake_service
#define IOServiceGetMatchingServices fake_services
#define IORegistryEntryGetRegistryEntryID fake_id
#define IORegistryEntryCreateCFProperty fake_property
#define IORegistryEntryCreateCFProperties fake_properties
#define IOObjectGetClass fake_class
#define IOObjectConformsTo fake_conforms
#define IORegistryEntryGetChildIterator fake_children
#define IORegistryCreateIterator fake_registry
#define IOIteratorNext fake_next
#define IOIteratorIsValid fake_valid
#define IOObjectRelease fake_release
#define IOObjectRetain fake_release
#define IORegistryEntryGetParentEntry fake_parent
#define IOHIDDeviceCreate fake_create
#define IOHIDDeviceGetProperty fake_get
#define IOHIDDeviceOpen fake_open
bool usb_host_coex_native_check(CoexNativeTicket *t, CoexNativeStage stage, uint64_t id, Error **errp)
{
    assert((unsigned)stage == stages++);
    assert(opens == (stage==COEX_AFTER_OPEN ? 1u : 0u));
    assert(node_count == (stage==COEX_AFTER_OPEN ? 6u : 5u));
    if(stage==COEX_BEFORE_CREATE && mutate_descriptor) {
        uint8_t changed[sizeof(descriptor)]; memcpy(changed,descriptor,sizeof(changed)); changed[15]=0x20;
        CFDataRef d=CFDataCreate(NULL,changed,sizeof(changed));
        CFDictionarySetValue(nodes[3].props,CFSTR(kIOHIDReportDescriptorKey),d); CFRelease(d);
    }
    return true;
}
bool usb_host_coex_native_descriptor(CoexNativeTicket *t, const uint8_t *data, size_t len)
{
    return len==sizeof(descriptor) && !memcmp(data,descriptor,len);
}
/* ACTUAL_NATIVE */
static void reset_iter(void) { iterator_count=0; }
static bool measure(QDict *target, uint64_t guard, uint64_t native, bool discover)
{
    reset_iter(); CoexMeasurement m={0};
    bool ok=usb_host_coex_measure_clients(target,200,44,guard,100,native,discover,&m);
    if(ok) { assert(m.cache==44 && m.guard==guard && (discover ? m.native==77 : m.native==native)); }
    return ok;
}
int main(int argc, char **argv)
{
    add(11,"IOUSBHostDevice",0); add(22,"IOUSBHostInterface",1); add(33,"AppleUserHIDDevice",2);
    add(44,"AppleUSBHostDeviceUserClient",1);

    puts_cf(4,CFSTR("IOUserClientCreator"),"pid 200, qemu");
    putn(1,CFSTR("idVendor"),1); putn(1,CFSTR("idProduct"),2); putn(1,CFSTR("sessionID"),55);
    puts_cf(1,CFSTR("USB Serial Number"),"serial");
    putn(2,CFSTR("bInterfaceClass"),3); putn(2,CFSTR("bInterfaceSubClass"),0); putn(2,CFSTR("bInterfaceProtocol"),0);
    metadata(3,0xff00); putn(3,CFSTR(kIOHIDVendorIDKey),1); putn(3,CFSTR(kIOHIDProductIDKey),2);
    puts_cf(3,CFSTR(kIOHIDSerialNumberKey),"serial"); puts_cf(3,CFSTR(kIOHIDTransportKey),"USB"); puts_cf(3,CFSTR(kIOHIDProductKey),"fixture");
    CFDataRef data=CFDataCreate(NULL,descriptor,sizeof(descriptor));
    CFDictionarySetValue(nodes[3].props,CFSTR(kIOHIDReportDescriptorKey),data); CFRelease(data);
    QDict *target=qdict_new();
    qdict_put_str(target,"root-id","11"); qdict_put_str(target,"interface-id","22"); qdict_put_str(target,"hid-id","33");
    qdict_put_int(target,"vendor-id",1); qdict_put_int(target,"product-id",2); qdict_put_str(target,"serial-utf8","serial");
    g_autofree char *hash=g_compute_checksum_for_data(G_CHECKSUM_SHA256,descriptor,sizeof(descriptor));
    qdict_put_str(target,"descriptor-sha256",hash);
    if(argc==2 && !strcmp(argv[1],"pending-present")) {
        reset_iter(); CoexMeasurement m={0};
        assert(!fake_service(0,fake_matching(44)));
        unsigned composite=add(99,"AppleUSBHostCompositeDevice",1);
        assert(!fake_service(0,fake_matching(nodes[composite].id)));
        add(66,"AppleUSBHostDeviceUserClient",1); /* legitimate acquiring guard */
        assert(usb_host_coex_measure_pending(target,200,44,&m));
        assert(m.cache==44 && m.root==11 && !m.guard && !m.native);
        puts("PASS pending exact PRESENT unregistered cache"); return 0;
    }
    if(argc==2 && !strcmp(argv[1],"gone-absent")) {
        assert(usb_host_coex_ids_gone(111,666,777));
        assert(registry_scans==1);
        puts("PASS positive absence in one complete registry scan"); return 0;
    }
    if(argc==2 && !strncmp(argv[1],"pending-",8)) {
        const char *c=argv[1]+8;
        if(!strcmp(c,"missing"))nodes[4].id=45;
        else if(!strcmp(c,"creator"))puts_cf(4,CFSTR("IOUserClientCreator"),"pid 201, foreign");
        else if(!strcmp(c,"class"))nodes[4].cls="UnknownUserClient";
        else if(!strcmp(c,"class-error"))class_error=true;
        else if(!strcmp(c,"parent"))parent_wrong=true;
        else if(!strcmp(c,"parent-error"))parent_error=true;
        else if(!strcmp(c,"not-child"))nodes[4].parent=2;
        else if(!strcmp(c,"invalid"))invalid_iterator=true;
        else if(!strcmp(c,"null"))children_null=true;
        else if(!strcmp(c,"error"))children_error=true;
        else if(!strcmp(c,"id-error"))id_error=4;
        else if(!strcmp(c,"id-zero"))id_zero=4;
        else if(!strcmp(c,"late-id-error")){add(99,"AppleUSBHostCompositeDevice",1);id_error=5;}
        else if(!strcmp(c,"budget"))repeat_entries=65;
        else abort();
        reset_iter(); CoexMeasurement m={0};
        assert(!usb_host_coex_measure_pending(target,200,44,&m));
        puts("PASS pending unknown/mismatch/incomplete denies"); return 0;
    }
    if(argc==2 && !strncmp(argv[1],"gone-",5)) {
        const char *c=argv[1]+5;
        uint64_t root=111,guard=666,native=777;
        if(!strcmp(c,"root"))root=11;
        else if(!strcmp(c,"guard"))guard=44; /* PRESENT unregistered client */
        else if(!strcmp(c,"native")){add(77,"IOHIDLibUserClient",3);native=77;}
        else if(!strcmp(c,"composite")){add(99,"AppleUSBHostCompositeDevice",1);guard=99;}
        else if(!strcmp(c,"invalid"))invalid_iterator=true;
        else if(!strcmp(c,"null"))registry_null=true;
        else if(!strcmp(c,"error"))registry_error=true;
        else if(!strcmp(c,"id-error"))id_error=4;
        else if(!strcmp(c,"id-zero"))id_zero=4;
        else if(!strcmp(c,"budget"))repeat_entries=262145;
        else if(!strcmp(c,"root-zero"))root=0;
        else if(!strcmp(c,"optional-zero")){
            assert(usb_host_coex_ids_gone(root,0,0));
            puts("PASS optional absent IDs not confused with unknown root"); return 0;
        } else abort();
        assert(!usb_host_coex_ids_gone(root,guard,native));
        puts("PASS surviving unregistered or unknown absence denies"); return 0;
    }
    assert(argc==1);
    assert(!usb_host_coex_ids_gone(11,0,0));
    assert(usb_host_coex_ids_gone(111,666,777));
    assert(!usb_host_coex_ids_gone(111,44,777));
    assert(!usb_host_coex_ids_gone(111,666,44));
    invalid_iterator=true;assert(!usb_host_coex_ids_gone(111,666,777));invalid_iterator=false;
    registry_error=true;assert(!usb_host_coex_ids_gone(111,666,777));registry_error=false;
    assert(!usb_host_coex_ids_gone(0,0,0));
    assert(measure(target,0,0,false));
    add(66,"AppleUSBHostDeviceUserClient",1); puts_cf(5,CFSTR("IOUserClientCreator"),"pid 100, launcher");
    assert(!measure(target,0,0,false)); assert(measure(target,66,0,false));
    puts_cf(5,CFSTR("IOUserClientCreator"),"pid 200, extra own"); assert(!measure(target,66,0,false));
    puts_cf(5,CFSTR("IOUserClientCreator"),"pid 100, launcher");
    add(77,"IOHIDLibUserClient",3); puts_cf(6,CFSTR("IOUserClientCreator"),"pid 200, qemu");
    assert(measure(target,66,77,false)); assert(measure(target,66,0,true)); assert(!measure(target,66,78,false));
    puts_cf(6,CFSTR("IOUserClientCreator"),"pid 300, foreign"); assert(!measure(target,66,77,false));
    puts_cf(6,CFSTR("IOUserClientCreator"),"pid 200, qemu");
    add(88,"IOHIDLibUserClient",3); puts_cf(7,CFSTR("IOUserClientCreator"),"pid 200, extra"); assert(!measure(target,66,77,false)); node_count--;
    metadata(3,1); assert(!measure(target,66,77,false)); metadata(3,0xff00);
    CFDictionarySetValue(nodes[3].props,CFSTR(kIOHIDBuiltInKey),kCFBooleanTrue); assert(!measure(target,66,77,false));
    CFDictionaryRemoveValue(nodes[3].props,CFSTR(kIOHIDBuiltInKey));
    putn(2,CFSTR("bInterfaceProtocol"),1); assert(!measure(target,66,77,false)); putn(2,CFSTR("bInterfaceProtocol"),0);
    invalid_iterator=true; assert(!measure(target,66,77,false)); invalid_iterator=false;
    putn(1,CFSTR("sessionID"),56);
    reset_iter(); CoexMeasurement m={0}; assert(usb_host_coex_measure_clients(target,200,44,66,100,77,false,&m) && m.session==56);
    putn(1,CFSTR("sessionID"),55);
    qdict_put_str(target,"interface-id","23"); assert(!measure(target,66,77,false)); qdict_put_str(target,"interface-id","22");
    qdict_put_str(target,"descriptor-sha256","wrong"); assert(!measure(target,66,77,false)); qdict_put_str(target,"descriptor-sha256",hash);
    /* Ordinary native open still rejects a cache. Ticketed open exercises the
     * actual Create/property/descriptor/nonseizing Open bodies with fake APIs. */
    HostHIDState s={.registry_id=33,.vendorid=1,.productid=2,.serial=(char *)"serial"}; Error *err=NULL;
    reset_iter(); assert(!native_open(&s,&err) && !creates && !opens); error_free(err); err=NULL;
    CFRelease(nodes[6].props); node_count=5; /* Create has no native client. */
    s.ticket=(CoexNativeTicket *)1; reset_iter(); assert(native_open(&s,&err));
    assert(creates==1 && opens==1 && stages==4); CFRelease(s.hid); g_free(s.product);
    CFRelease(nodes[6].props); node_count=5;
    s.hid=NULL; s.product=NULL; stages=creates=opens=0; mutate_descriptor=true;
    reset_iter(); assert(!native_open(&s,&err) && !opens); error_free(err);
    if(s.hid) { CFRelease(s.hid); } g_free(s.product);
    qobject_unref(target);
    puts("PASS actual tree/parser/property measurement and native Create/descriptor/nonseizing Open; exact IDs/creators, extra/foreign, built-in/protected/boot/incomplete/root/descriptor failures");
}
