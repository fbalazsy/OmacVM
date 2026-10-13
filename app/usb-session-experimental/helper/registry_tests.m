#import "native_registry.h"
#include <assert.h>
#include <stdio.h>
#define check owner_policy
static NSDictionary *client(NSString *k,NSString *creator){return @{@"class":k,@"properties":@{@"IOUserClientCreator":creator}};}
int main(void){@autoreleasepool {
 NSString *self=@"pid 42424, org.omacvm.fixture";
 NSDictionary *owned=@{@"UsbExclusiveOwner":self},*hid=@{@"UsbExclusiveOwner":@"AppleUserUSBHostHIDDevice"};
 NSArray *device=@[client(@"AppleUSBHostDeviceUserClient",self)],*interface=@[client(@"AppleUSBHostInterfaceUserClient",self)];
 /* Exact captured device observation; not a live post-claim measurement. */
 assert(check(@"IOUSBHostDevice",owned,OWN_OPENED,42424,device));
 assert(check(@"IOUSBHostDevice",owned,OWN_CAPTURED,42424,device));
 assert(!check(@"IOUSBHostDevice",owned,OWN_PRE,42424,device));
 for(int phase=OWN_PRE;phase<=OWN_CAPTURED;phase++){
  assert(check(@"IOUSBHostDevice",@{},phase,42424,@[]));
  assert(!check(@"IOUSBHostDevice",owned,phase,42424,@[]));
  assert(!check(@"IOUSBHostDevice",owned,phase,42424,interface));
  assert(!check(@"IOUSBHostDevice",owned,phase,42424,@[client(@"UnknownUserClient",self)]));
  assert(!check(@"IOUSBHostDevice",owned,phase,42424,@[client(@"AppleUSBHostDeviceUserClient",@"pid 9, foreign")]));
  assert(!check(@"IOUSBHostDevice",owned,phase,58294,device));
  assert(!check(@"IOUSBHostInterface",owned,phase,42424,device));
  assert(check(@"IOUSBHostInterface",hid,phase,42424,@[])==(phase!=OWN_CAPTURED));
  assert(check(@"IOUSBHostInterface",@{},phase,42424,@[])==(phase==OWN_CAPTURED));
  assert(check(@"IOUSBHostInterface",owned,phase,42424,interface)==(phase==OWN_CAPTURED));
  assert(check(@"AppleUSBHostInterfaceUserClient",@{@"IOUserClientCreator":self},phase,42424,@[])==(phase==OWN_CAPTURED));
  assert(!check(@"AppleUSBHostInterfaceUserClient",@{@"IOUserClientCreator":@"pid 999, foreign"},phase,42424,@[]));
  assert(check(@"AppleUSBHostDeviceUserClient",@{@"IOUserClientCreator":@"pid 999, enumeration"},phase,42424,@[]));
  for(id bad in @[@"pid 424240, suffix",@"pid 042424, zero",@"pid 42424",@"pid 42424x, suffix",@"pid 42424, ",@"pid -42424, negative",@42424]){
   NSDictionary *p=@{@"UsbExclusiveOwner":bad};
   assert(!check(@"IOUSBHostDevice",p,phase,42424,device));
   assert(!check(@"IOUSBHostInterface",p,phase,42424,interface));
   assert(!check(@"AppleUSBHostInterfaceUserClient",@{@"IOUserClientCreator":bad},phase,42424,@[]));
  }
  for(NSString *k in @[@"UnknownUserClient",@"IOHIDKeyboard",@"AppleUserHIDDevice",@"IOHIDInterface",@"AppleUSBHostCompositeDevice"])
   assert(!check(k,owned,phase,42424,device));
 }
 assert(!check(@"IOUSBHostInterface",owned,OWN_CAPTURED,42424,@[client(@"AppleUSBHostInterfaceUserClient",@"pid 424240, suffix")]));
 assert(!check(@"IOUSBHostDevice",owned,OWN_OPENED,0,device));
 assert(!check(@"IOUSBHostDevice",@{},(OwnershipPhase)99,42424,@[]));
 assert(!check(@"IOUSBHostDevice",nil,OWN_PRE,42424,@[]));
 puts("PASS ownership phases PRE/OPENED/CAPTURED: native preclaim HID; exact self device/interface PID AND corresponding direct child class; foreign/prefix/unknown rejected (offline fixtures)");
}return 0;}
