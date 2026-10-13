/* Entire production traversal with fake IOKit ONLY: no native registry scan. */
#define IORegistryEntryCreateCFProperties fake_properties
#define IOObjectGetClass fake_class
#define IORegistryEntryGetRegistryEntryID fake_id
#define IORegistryEntryGetChildIterator fake_children
#define IORegistryEntryCreateIterator fake_recursive
#define IOServiceGetMatchingServices fake_services
#define IOServiceMatching fake_matching
#define IOIteratorNext fake_next
#define IOIteratorIsValid fake_valid
#define IOObjectRetain fake_retain
#define IOObjectRelease fake_release
#include "native_registry.m"
#include <assert.h>
#include <string.h>
typedef struct {io_object_t nodes[8];unsigned count,pos;} FakeIterator;
static FakeIterator its[128];static unsigned next_it=100;
static NSDictionary *properties[6];static NSString *classes[6];static int claimed,misplaced;
static io_iterator_t iterator(const io_object_t *nodes,unsigned n){assert(next_it<128);io_iterator_t it=next_it++;memcpy(its[it].nodes,nodes,n*sizeof(*nodes));its[it].count=n;its[it].pos=0;return it;}
CFMutableDictionaryRef fake_matching(const char *name){assert(!strcmp(name,"IOUSBHostDevice"));return CFDictionaryCreateMutable(kCFAllocatorDefault,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);}
kern_return_t fake_services(mach_port_t port,CFDictionaryRef match,io_iterator_t *it){(void)port;CFRelease(match);io_object_t a[]={1};*it=iterator(a,1);return KERN_SUCCESS;}
kern_return_t fake_properties(io_registry_entry_t n,CFMutableDictionaryRef *p,CFAllocatorRef allocator,IOOptionBits options){(void)options;assert(n>0 && n<6);*p=CFDictionaryCreateMutableCopy(allocator,0,(__bridge CFDictionaryRef)properties[n]);return KERN_SUCCESS;}
kern_return_t fake_class(io_object_t n,io_name_t out){assert(n>0 && n<6);strlcpy(out,classes[n].UTF8String,sizeof(io_name_t));return KERN_SUCCESS;}
kern_return_t fake_id(io_registry_entry_t n,uint64_t *rid){*rid=1000+n;return KERN_SUCCESS;}
kern_return_t fake_children(io_registry_entry_t n,const io_name_t plane,io_iterator_t *it){(void)plane;
 io_object_t a[3];unsigned count=0;
 if(n==1){a[count++]=2;a[count++]=3;if(misplaced && claimed)a[count++]=4;}
 if(n==2){if(claimed && !misplaced)a[count++]=4;else if(!claimed)a[count++]=5;}
 *it=iterator(a,count);return KERN_SUCCESS;
}
kern_return_t fake_recursive(io_registry_entry_t n,const io_name_t plane,IOOptionBits options,io_iterator_t *it){assert(n==1);(void)plane;assert(options==kIORegistryIterateRecursively);io_object_t a[]={2,3,claimed?4:5};*it=iterator(a,3);return KERN_SUCCESS;}
io_object_t fake_next(io_iterator_t it){assert(it>=100 && it<next_it);FakeIterator *i=&its[it];return i->pos<i->count?i->nodes[i->pos++]:0;}
boolean_t fake_valid(io_iterator_t it){return it>=100 && it<next_it;}
kern_return_t fake_retain(io_object_t obj){(void)obj;return KERN_SUCCESS;}
kern_return_t fake_release(io_object_t obj){(void)obj;return KERN_SUCCESS;}
static int scan(Snapshot *out,OwnershipPhase phase,const Snapshot *original){next_it=100;return registry_scan(out,phase,original);}
int main(void){@autoreleasepool {
 NSString *self=[NSString stringWithFormat:@"pid %d, offline-fixture",getpid()];
 classes[1]=@"IOUSBHostDevice";classes[2]=@"IOUSBHostInterface";classes[3]=@"AppleUSBHostDeviceUserClient";classes[4]=@"AppleUSBHostInterfaceUserClient";classes[5]=@"AppleUserHIDDevice";
 NSMutableDictionary *d=[@{@"idVendor":@0x1209,@"idProduct":@0xffff,@"locationID":@0x12340000,@"bDeviceClass":@0,@"bDeviceSubClass":@0,@"bDeviceProtocol":@0,@"bNumConfigurations":@1,@"USB Serial Number":@"SYNTHETIC-ONLY",@"USB Product Name":@"SyntheticVendorHID",@"sessionID":@42,@"USB Address":@12,@"IOCFPlugInTypes":@{@"9dc7b780-9ec0-11d4-a54f-000a27052861":@"IOUSBHostFamily.kext/Contents/PlugIns/IOUSBLib.bundle"}} mutableCopy];
 NSMutableDictionary *i=[@{@"idVendor":@0x1209,@"idProduct":@0xffff,@"locationID":@0x12340000,@"bInterfaceNumber":@0,@"bAlternateSetting":@0,@"bInterfaceClass":@3,@"bInterfaceSubClass":@0,@"bInterfaceProtocol":@0,@"bNumEndpoints":@1,@"bConfigurationValue":@1,@"UsbExclusiveOwner":@"AppleUserUSBHostHIDDevice"} mutableCopy];
 properties[1]=d;properties[2]=i;properties[3]=@{@"IOUserClientCreator":self};properties[4]=@{@"IOUserClientCreator":self};
 const unsigned char report[]={0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x15,0x00,0x26,0xff,0x00,0x75,0x08,0x95,0x20,0x09,0x01,0x81,0x02,0x95,0x20,0x09,0x01,0x91,0x02,0x95,0x01,0x09,0x01,0xb1,0x02,0xc0};
 properties[5]=@{@"ReportDescriptor":[NSData dataWithBytes:report length:sizeof(report)],@"PrimaryUsagePage":@0xff00,@"PrimaryUsage":@1};
 Snapshot original,s;assert(scan(&original,OWN_PRE,NULL));
 d[@"UsbExclusiveOwner"]=self;assert(!scan(&s,OWN_PRE,NULL));assert(scan(&s,OWN_OPENED,&original));
 [i removeObjectForKey:@"UsbExclusiveOwner"];assert(!scan(&s,OWN_OPENED,&original));
 /* Parent's captured-but-not-claimed observation is not post-claim proof. */
 claimed=1;assert(scan(&s,OWN_CAPTURED,&original));i[@"UsbExclusiveOwner"]=self;assert(scan(&s,OWN_CAPTURED,&original));
 misplaced=1;assert(!scan(&s,OWN_CAPTURED,&original));misplaced=0;
 properties[3]=@{@"IOUserClientCreator":@"pid 999, foreign"};assert(!scan(&s,OWN_CAPTURED,&original));properties[3]=@{@"IOUserClientCreator":self};
 properties[4]=@{@"IOUserClientCreator":@"pid 999, foreign"};assert(!scan(&s,OWN_CAPTURED,&original));properties[4]=@{@"IOUserClientCreator":self};
 classes[4]=@"UnknownUserClient";assert(!scan(&s,OWN_CAPTURED,&original));classes[4]=@"AppleUSBHostInterfaceUserClient";
 for(unsigned field=0;field<4;field++){Snapshot bad=original;if(field==0)bad.registry++;if(field==1)bad.interface_id++;if(field==2)bad.session++;if(field==3)bad.address++;assert(!scan(&s,OWN_CAPTURED,&bad));}
 assert(scan(&s,OWN_CAPTURED,&original));
 puts("PASS production registry traversal with fake IOKit: PRE -> OPENED/native HID -> CAPTURED self; direct corresponding child only; all original identity fields pinned; rejects log actual node class/owner; no live registry call");
}return 0;}
