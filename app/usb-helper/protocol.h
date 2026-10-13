#pragma once
#import <Foundation/Foundation.h>
#include "process.h"
#define CONTROL_MAX 16384
#define SERIAL_MAX 255
#define INSTALL_ROOT "/Library/PrivilegedHelperTools/org.omacvm.usb"
#define RUN_ROOT INSTALL_ROOT "/run"
int valid_uuid(const char *s);
NSDictionary *request_parse(NSData *data,NSString *attempt,uid_t uid,int captured);
Process request_process(NSDictionary *p);
