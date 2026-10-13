#import "native_registry.h"
#include "policy.h"
#include <IOKit/IOKitLib.h>
#include <unistd.h>
#include <stdio.h>
/* Exact canonical PID plus delimiter, never a decimal prefix or process name.
   The suffix is diagnostic only; the kernel's creator PID is the authority. */
static int self_pid(id value,pid_t self) {
 if(self<=0 || ![value isKindOfClass:[NSString class]])return 0;
 NSString *prefix=[NSString stringWithFormat:@"pid %d, ",self];
 return [value hasPrefix:prefix] && [value length]>prefix.length;
}
static int self_client(NSArray *children,NSString *wanted,pid_t self) {
 if(![children isKindOfClass:[NSArray class]] || children.count>64)return 0;
 unsigned matches=0;
 for(NSDictionary *child in children){
  if(![child isKindOfClass:[NSDictionary class]])return 0;
  NSDictionary *p=child[@"properties"];
  if([child[@"class"] isEqual:wanted] && [p isKindOfClass:[NSDictionary class]] && !p[@"UsbExclusiveOwner"] && self_pid(p[@"IOUserClientCreator"],self))matches++;
 }
 return matches==1;
}
int owner_policy(NSString *k,NSDictionary *p,OwnershipPhase phase,pid_t self,NSArray *children) {
 if(![p isKindOfClass:[NSDictionary class]] || phase<OWN_PRE || phase>OWN_CAPTURED || self<=0)return 0;
 id owner=p[@"UsbExclusiveOwner"];
 if([k isEqual:@"IOUSBHostDevice"])
  return !p[@"IOUserClientCreator"] && (!owner || (phase!=OWN_PRE && self_pid(owner,self) && self_client(children,@"AppleUSBHostDeviceUserClient",self)));
 if([k isEqual:@"IOUSBHostInterface"]){
  if(p[@"IOUserClientCreator"])return 0;
  if(phase!=OWN_CAPTURED)return [owner isEqual:@"AppleUserUSBHostHIDDevice"];
  /* USBInterfaceOpen exclusively opens through its corresponding userclient
     (IOUSBLib.h / USB.h). Nil is also permitted; it is not ownership proof. */
  return !owner || (self_pid(owner,self) && self_client(children,@"AppleUSBHostInterfaceUserClient",self));
 }
 /* Enumeration clients are not interface ownership. No exclusive owner on
    clients/generic nodes; device/interface exceptions above are node-specific. */
 if(owner)return 0;
 if([@[@"AppleUSBHostDeviceUserClient",@"IOUSBHostDeviceUserClient",@"IOUSBDeviceUserClient"] containsObject:k])return 1;
 if([k isEqual:@"AppleUSBHostInterfaceUserClient"])
  return phase==OWN_CAPTURED && self_pid(p[@"IOUserClientCreator"],self);
 if(p[@"IOUserClientCreator"])return 0;
 return [@[@"AppleUSBHostCompositeDevice",@"AppleUserHIDDevice",@"IOHIDInterface"] containsObject:k];
}
static NSDictionary *props(io_registry_entry_t node) {
 CFMutableDictionaryRef p=NULL;
 if(IORegistryEntryCreateCFProperties(node,&p,kCFAllocatorDefault,0)!=KERN_SUCCESS)return nil;
 return CFBridgingRelease(p);
}
static uint64_t num(NSDictionary *p,NSString *key) {
 id v=p[key];if(![v isKindOfClass:[NSNumber class]] || [v longLongValue]<0)return UINT64_MAX;
 return [v unsignedLongLongValue];
}
static NSString *klass(io_registry_entry_t n){io_name_t s={0};return IOObjectGetClass(n,s)==KERN_SUCCESS?@(s):@"UNKNOWN";}
static void reject_node(const char *reason,OwnershipPhase phase,io_registry_entry_t node,NSString *k,NSDictionary *p){
 uint64_t rid=0;if(node)IORegistryEntryGetRegistryEntryID(node,&rid);
 /* JSON escapes property text/newlines: one bounded structured diagnostic. */
 NSDictionary *d=@{@"reason":@(reason),@"phase":@(phase),@"registry":@(rid),@"class":k?:@"UNAVAILABLE",@"owner":[p[@"UsbExclusiveOwner"] description]?:@"<nil>",@"creator":[p[@"IOUserClientCreator"] description]?:@"<nil>"};
 NSData *json=[NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
 if(json)fprintf(stderr,"registry-reject %.*s\n",(int)MIN(json.length,8192),(const char *)json.bytes);
}
static NSArray *direct_children(io_registry_entry_t node){
 io_iterator_t it=0;io_registry_entry_t child=0;
 if(IORegistryEntryGetChildIterator(node,kIOServicePlane,&it)!=KERN_SUCCESS)return nil;
 NSMutableArray *a=[NSMutableArray array];BOOL ok=YES;
 while((child=IOIteratorNext(it))){NSDictionary *p=props(child);NSString *k=klass(child);IOObjectRelease(child);
  if(!p || a.count>=64){ok=NO;break;}
  [a addObject:@{@"class":k,@"properties":p}];
 }
 ok=ok && IOIteratorIsValid(it);IOObjectRelease(it);return ok?a:nil;
}
static int node_owner(io_registry_entry_t node,NSString *k,NSDictionary *p,OwnershipPhase phase){
 NSArray *children=@[];
 if([k isEqual:@"IOUSBHostDevice"] || [k isEqual:@"IOUSBHostInterface"]){
  children=direct_children(node);
  if(!children){reject_node("children-unavailable",phase,node,k,p);return 0;}
 }
 if(owner_policy(k,p,phase,getpid(),children))return 1;
 reject_node("ownership",phase,node,k,p);return 0;
}
static int device_fields(NSDictionary *p) {
 id serial=p[@"USB Serial Number"],product=p[@"USB Product Name"];
 if(![serial isKindOfClass:[NSString class]] || ![product isKindOfClass:[NSString class]])return 0;
 NSArray *keys=@[@"idVendor",@"idProduct",@"locationID",@"bDeviceClass",@"bDeviceSubClass",@"bDeviceProtocol",@"bNumConfigurations"];
 unsigned v[7];for(unsigned i=0;i<7;i++){uint64_t n=num(p,keys[i]);if(n>UINT32_MAX)return 0;v[i]=(unsigned)n;}
 return identity_policy(v[0],v[1],v[2],v[3],v[4],v[5],v[6],[serial UTF8String],[product UTF8String]);
}
int registry_scan(Snapshot *out,OwnershipPhase phase,const Snapshot *original) {
 @autoreleasepool {
 if(!out || phase<OWN_PRE || phase>OWN_CAPTURED || (phase!=OWN_PRE && !original)){reject_node("arguments",phase,0,nil,nil);return 0;}
 *out=(Snapshot){0};io_iterator_t it=0;io_service_t selected=0,node=0;unsigned candidates=0;int ok=0;
 if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&it)!=KERN_SUCCESS){reject_node("matching-services",phase,0,nil,nil);return 0;}
 unsigned scanned=0;
 while((node=IOIteratorNext(it))){NSDictionary *p=props(node);
  BOOL candidate=(num(p,@"idVendor")==PROFILE_VID && num(p,@"idProduct")==PROFILE_PID) || num(p,@"locationID")==PROFILE_LOCATION || [p[@"USB Serial Number"] isEqual:@PROFILE_SERIAL] || [p[@"USB Product Name"] isEqual:@PROFILE_PRODUCT];
  if(candidate){candidates++;if(!selected){selected=node;IOObjectRetain(node);}else reject_node("ambiguous-candidate",phase,node,klass(node),p);}
  IOObjectRelease(node);if(++scanned>256)break;
 }
 BOOL valid=IOIteratorIsValid(it);IOObjectRelease(it);it=0;
 NSDictionary *p=nil,*plugins=nil;const char *reason="candidate-count/iterator";
 if(!valid || scanned>256 || candidates!=1 || !selected)goto done;
 p=props(selected);reason="device-identity";
 if(!device_fields(p))goto done;
 reason="device-ownership";if(!node_owner(selected,klass(selected),p,phase))goto done;
 plugins=p[@"IOCFPlugInTypes"];reason="device-plugin";
 if(![plugins isKindOfClass:[NSDictionary class]] || plugins.count!=1 || ![plugins[@"9dc7b780-9ec0-11d4-a54f-000a27052861"] isEqual:@"IOUSBHostFamily.kext/Contents/PlugIns/IOUSBLib.bundle"])goto done;
 out->session=num(p,@"sessionID");uint64_t address=num(p,@"USB Address");reason="session/address";
 if(!out->session || out->session==UINT64_MAX || address>127 || !address)goto done;out->address=(uint32_t)address;
 reason="device-registry-id";if(IORegistryEntryGetRegistryEntryID(selected,&out->registry)!=KERN_SUCCESS || !out->registry)goto done;
 reason="descendant-iterator";if(IORegistryEntryCreateIterator(selected,kIOServicePlane,kIORegistryIterateRecursively,&it)!=KERN_SUCCESS)goto done;
 unsigned nodes=0,interfaces=0,reports=0;ok=1;
 while((node=IOIteratorNext(it))){NSDictionary *q=props(node);NSString *k=klass(node);const char *why=NULL;
  if(++nodes>64)why="node-limit";
  if(!node_owner(node,k,q,phase))ok=0;
  if([k isEqual:@"IOUSBHostDevice"])why="nested-device";
  if([k isEqual:@"IOUSBHostInterface"]){interfaces++;
   if(IORegistryEntryGetRegistryEntryID(node,&out->interface_id)!=KERN_SUCCESS)why="interface-registry-id";
   if(num(q,@"bInterfaceNumber") || num(q,@"bAlternateSetting") || num(q,@"bInterfaceClass")!=3 || num(q,@"bInterfaceSubClass") || num(q,@"bInterfaceProtocol") || num(q,@"bNumEndpoints")!=1 || num(q,@"bConfigurationValue")!=1 || num(q,@"idVendor")!=PROFILE_VID || num(q,@"idProduct")!=PROFILE_PID || num(q,@"locationID")!=PROFILE_LOCATION)why="interface-identity";
  }
  id r=q[@"ReportDescriptor"];
  if(r){reports++;if(![r isKindOfClass:[NSData class]] || !report_policy([r bytes],[r length]) || num(q,@"PrimaryUsagePage")!=0xff00 || num(q,@"PrimaryUsage")!=1)why="report/usage";}
  if(why){ok=0;reject_node(why,phase,node,k,q);}
  IOObjectRelease(node);if(nodes>64)break;
 }
 reason="subtree-policy";
 if(!IOIteratorIsValid(it) || interfaces!=1 || !out->interface_id || (phase!=OWN_CAPTURED && !reports)){ok=0;reason="interface/report-count/iterator";}
 if(original && (out->registry!=original->registry || out->interface_id!=original->interface_id || out->session!=original->session || out->address!=original->address)){ok=0;reason="original-snapshot-identity";}
 done:if(!ok)reject_node(reason,phase,selected,selected?klass(selected):nil,p?: (selected?props(selected):nil));
 if(it)IOObjectRelease(it);if(selected)IOObjectRelease(selected);return ok;
 }
}
