#import "../registry.h"
extern int owner_policy(NSString *,NSDictionary *,OwnershipPhase,pid_t,NSArray *) __attribute__((weak_import));
#include <assert.h>
#include <stdio.h>
#define check owner_policy
static NSDictionary *client(NSString *k,NSString *creator){return @{@"class":k,@"properties":@{@"IOUserClientCreator":creator}};}
int main(void){@autoreleasepool {
 assert(owner_policy);
 NSString *self=@"pid 58293, fixture";
 NSDictionary *owned=@{@"UsbExclusiveOwner":self},*hid=@{@"UsbExclusiveOwner":@"AppleUserUSBHostHIDDevice"};
 NSArray *device=@[client(@"AppleUSBHostDeviceUserClient",self)],*interface=@[client(@"AppleUSBHostInterfaceUserClient",self)];
 /* Exact captured device observation; not a live post-claim measurement. */
 assert(check(@"IOUSBHostDevice",owned,OWN_OPENED,58293,device));
 assert(check(@"IOUSBHostDevice",owned,OWN_CAPTURED,58293,device));
 assert(!check(@"IOUSBHostDevice",owned,OWN_PRE,58293,device));
 for(int phase=OWN_PRE;phase<=OWN_CAPTURED;phase++){
  assert(check(@"IOUSBHostDevice",@{},phase,58293,@[]));
  assert(!check(@"IOUSBHostDevice",owned,phase,58293,@[]));
  assert(!check(@"IOUSBHostDevice",owned,phase,58293,interface));
  assert(!check(@"IOUSBHostDevice",owned,phase,58293,@[client(@"UnknownUserClient",self)]));
  assert(!check(@"IOUSBHostDevice",owned,phase,58293,@[client(@"AppleUSBHostDeviceUserClient",@"pid 9, foreign")]));
  assert(!check(@"IOUSBHostDevice",owned,phase,58294,device));
  assert(!check(@"IOUSBHostInterface",owned,phase,58293,device));
  assert(check(@"IOUSBHostInterface",hid,phase,58293,@[])==(phase!=OWN_CAPTURED));
  assert(check(@"IOUSBHostInterface",@{},phase,58293,@[])==(phase==OWN_CAPTURED));
  assert(check(@"IOUSBHostInterface",owned,phase,58293,interface)==(phase==OWN_CAPTURED));
  assert(check(@"AppleUSBHostInterfaceUserClient",@{@"IOUserClientCreator":self},phase,58293,@[])==(phase==OWN_CAPTURED));
  assert(!check(@"AppleUSBHostInterfaceUserClient",@{@"IOUserClientCreator":@"pid 999, foreign"},phase,58293,@[]));
  assert(check(@"AppleUSBHostDeviceUserClient",@{@"IOUserClientCreator":@"pid 999, enumeration"},phase,58293,@[]));
  for(id bad in @[@"pid 582930, suffix",@"pid 058293, zero",@"pid 58293",@"pid 58293x, suffix",@"pid 58293, ",@"pid -58293, negative",@58293]){
   NSDictionary *p=@{@"UsbExclusiveOwner":bad};
   assert(!check(@"IOUSBHostDevice",p,phase,58293,device));
   assert(!check(@"IOUSBHostInterface",p,phase,58293,interface));
   assert(!check(@"AppleUSBHostInterfaceUserClient",@{@"IOUserClientCreator":bad},phase,58293,@[]));
  }
  for(NSString *k in @[@"UnknownUserClient",@"IOHIDKeyboard",@"AppleUserHIDDevice",@"IOHIDInterface",@"AppleUSBHostCompositeDevice"])
   assert(!check(k,owned,phase,58293,device));
 }
 assert(!check(@"IOUSBHostInterface",owned,OWN_CAPTURED,58293,@[client(@"AppleUSBHostInterfaceUserClient",@"pid 582930, suffix")]));
 assert(!check(@"IOUSBHostDevice",owned,OWN_OPENED,0,device));
 assert(!check(@"IOUSBHostDevice",@{},(OwnershipPhase)99,58293,@[]));
 assert(!check(@"IOUSBHostDevice",nil,OWN_PRE,58293,@[]));
 puts("PASS ownership phases PRE/OPENED/CAPTURED: native preclaim HID; exact self device/interface PID AND corresponding direct child class; foreign/prefix/unknown rejected (offline fixtures)");
}return 0;}
