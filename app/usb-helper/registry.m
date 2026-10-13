/* Ownership predicates retain reviewed donor semantics: exact PID delimiter,
 * direct matching userclient, phase-specific HID owner, no unknown owners. */
#import "registry.h"
#include <IOKit/IOKitLib.h>
#include <unistd.h>
static int self_pid(id v,pid_t self){NSString *p=[NSString stringWithFormat:@"pid %d, ",self];return self>0 && [v isKindOfClass:NSString.class] && [v hasPrefix:p] && [v length]>p.length;}
static int self_client(NSArray *a,NSString *k,pid_t self){
 if(![a isKindOfClass:NSArray.class]||a.count>64)return 0;unsigned n=0;
 for(id c in a){if(![c isKindOfClass:NSDictionary.class])return 0;id p=c[@"properties"];if([c[@"class"] isEqual:k]&&[p isKindOfClass:NSDictionary.class]&&!p[@"UsbExclusiveOwner"]&&self_pid(p[@"IOUserClientCreator"],self))n++;}return n==1;
}
int owner_policy(NSString *k,NSDictionary *p,OwnershipPhase phase,pid_t self,NSArray *children){
 if(![p isKindOfClass:NSDictionary.class]||phase<OWN_PRE||phase>OWN_CAPTURED||self<=0)return 0;id owner=p[@"UsbExclusiveOwner"];
 if([k isEqual:@"IOUSBHostDevice"])return !p[@"IOUserClientCreator"]&&(!owner||(phase!=OWN_PRE&&self_pid(owner,self)&&self_client(children,@"AppleUSBHostDeviceUserClient",self)));
 if([k isEqual:@"IOUSBHostInterface"]){if(p[@"IOUserClientCreator"])return 0;if(phase!=OWN_CAPTURED)return [owner isEqual:@"AppleUserUSBHostHIDDevice"];return !owner||(self_pid(owner,self)&&self_client(children,@"AppleUSBHostInterfaceUserClient",self));}
 if(owner)return 0;if([@[@"AppleUSBHostDeviceUserClient",@"IOUSBHostDeviceUserClient",@"IOUSBDeviceUserClient"] containsObject:k])return 1;
 if([k isEqual:@"AppleUSBHostInterfaceUserClient"])return phase==OWN_CAPTURED&&self_pid(p[@"IOUserClientCreator"],self);
 if(p[@"IOUserClientCreator"])return 0;return [@[@"AppleUSBHostCompositeDevice",@"AppleUserHIDDevice",@"IOHIDInterface"] containsObject:k];
}
static NSDictionary *props(io_registry_entry_t n){CFMutableDictionaryRef p=NULL;if(IORegistryEntryCreateCFProperties(n,&p,kCFAllocatorDefault,0)!=KERN_SUCCESS)return nil;return CFBridgingRelease(p);}
static uint64_t num(NSDictionary *p,NSString *key){id v=p[key];if(![v isKindOfClass:NSNumber.class]||[v longLongValue]<0)return UINT64_MAX;return [v unsignedLongLongValue];}
static NSString *klass(io_registry_entry_t n){io_name_t s={0};return IOObjectGetClass(n,s)==KERN_SUCCESS?@(s):@"UNKNOWN";}
static int node_owner(io_registry_entry_t n,NSString *k,NSDictionary *p,OwnershipPhase phase){
 NSMutableArray *a=[NSMutableArray array];
 if([k isEqual:@"IOUSBHostDevice"]||[k isEqual:@"IOUSBHostInterface"]){io_iterator_t it=0;io_registry_entry_t c=0;if(IORegistryEntryGetChildIterator(n,kIOServicePlane,&it)!=KERN_SUCCESS)return 0;int valid=1;
  while((c=IOIteratorNext(it))){NSDictionary *q=props(c);NSString *ck=klass(c);IOObjectRelease(c);if(!q||a.count>=64){valid=0;break;}[a addObject:@{@"class":ck,@"properties":q}];}valid=valid&&IOIteratorIsValid(it);IOObjectRelease(it);if(!valid)return 0;
 }return owner_policy(k,p,phase,getpid(),a);
}
int registry_scan(NSDictionary *selection,Snapshot *out,OwnershipPhase phase,const Snapshot *original,NSData **report){@autoreleasepool {
 if(!out||phase<OWN_PRE||phase>OWN_CAPTURED||(phase!=OWN_PRE&&!original))return 0;*out=(Snapshot){0};if(report)*report=nil;
 uint64_t rid=[selection[@"registry_id"] unsignedLongLongValue];io_service_t dev=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(rid));if(!dev)return 0;
 NSDictionary *p=props(dev);id plugins=p[@"IOCFPlugInTypes"];int ok=0;io_iterator_t it=0;io_registry_entry_t n=0;unsigned nodes=0,interfaces=0,reports=0;NSData *first=nil;
 if(![klass(dev) isEqual:@"IOUSBHostDevice"]||![p[@"USB Serial Number"] isEqual:selection[@"serial"]]||num(p,@"locationID")!=[selection[@"location"] unsignedIntValue]||num(p,@"idVendor")!=[selection[@"vendor"] unsignedIntValue]||num(p,@"idProduct")!=[selection[@"product"] unsignedIntValue]||num(p,@"bDeviceClass")||num(p,@"bDeviceSubClass")||num(p,@"bDeviceProtocol")||num(p,@"bNumConfigurations")!=1||!node_owner(dev,klass(dev),p,phase))goto done; if(![plugins isKindOfClass:NSDictionary.class]||[plugins count]!=1||![plugins[@"9dc7b780-9ec0-11d4-a54f-000a27052861"] isEqual:@"IOUSBHostFamily.kext/Contents/PlugIns/IOUSBLib.bundle"])goto done;
 out->registry=rid;out->session=num(p,@"sessionID");uint64_t addr=num(p,@"USB Address");if(!out->session||out->session==UINT64_MAX||!addr||addr>127)goto done;out->address=(uint32_t)addr;
 if(IORegistryEntryCreateIterator(dev,kIOServicePlane,kIORegistryIterateRecursively,&it)!=KERN_SUCCESS)goto done;ok=1;
 while((n=IOIteratorNext(it))){NSDictionary *q=props(n);NSString *k=klass(n);if(++nodes>64||!node_owner(n,k,q,phase))ok=0;
  if([k isEqual:@"IOUSBHostDevice"])ok=0;
  if([k isEqual:@"IOUSBHostInterface"]){interfaces++;uint64_t iid=0;if(IORegistryEntryGetRegistryEntryID(n,&iid)!=KERN_SUCCESS||!iid)ok=0;out->interface_id=iid;
   uint64_t iface=num(q,@"bInterfaceNumber"),cfg=num(q,@"bConfigurationValue"),eps=num(q,@"bNumEndpoints");
   if(iface>31||!cfg||cfg>255||eps<1||eps>2||num(q,@"bAlternateSetting")||num(q,@"bInterfaceClass")!=3||num(q,@"bInterfaceSubClass")||num(q,@"bInterfaceProtocol")||num(q,@"locationID")!=[selection[@"location"] unsignedIntValue]||num(q,@"idVendor")!=[selection[@"vendor"] unsignedIntValue]||num(q,@"idProduct")!=[selection[@"product"] unsignedIntValue])ok=0;
   out->interface=iface;out->configuration=cfg;
  }
  id d=q[@"ReportDescriptor"];if(d){reports++;HIDPolicy policy={0};if(![d isKindOfClass:NSData.class]||!hid_report([d bytes],[d length],&policy)||num(q,@"PrimaryUsagePage")<0xff00||num(q,@"PrimaryUsagePage")>0xffff)ok=0;else if(first&&![first isEqual:d])ok=0;else first=d;}
  IOObjectRelease(n);if(nodes>64)break;
 }
 if(!IOIteratorIsValid(it)||interfaces!=1||!out->interface_id||(phase!=OWN_CAPTURED&&!reports))ok=0;
 if(original && (out->registry!=original->registry||out->interface_id!=original->interface_id||out->session!=original->session||out->address!=original->address||out->interface!=original->interface||out->configuration!=original->configuration))ok=0;
 if(ok&&report)*report=first;
 done:if(it)IOObjectRelease(it);IOObjectRelease(dev);return ok;
}}
