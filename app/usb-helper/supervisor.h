#pragma once
#import "protocol.h"
#include "io.h"
#include <signal.h>
extern volatile sig_atomic_t interrupted;
int emit_event(int fd,NSString *attempt,NSString *event,NSDictionary *extra);
/* Child protocol is L (prevalidated listener), P (postcapture), then exit:
   0 clean+same-HID-restored, 2 clean without restore proof, 3 clean refusal.
   Other exits/signals are uncertain. Supervisor retains socket/arbitration. */
int supervise(int control,int channel,pid_t child,SocketOwner *usb,const Process *app,const Process *qemu,NSString *attempt);
