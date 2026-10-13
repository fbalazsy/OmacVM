#pragma once
#import <Foundation/Foundation.h>
#include "hid.h"
typedef enum {OWN_PRE,OWN_OPENED,OWN_CAPTURED} OwnershipPhase;
typedef struct {uint64_t registry,interface_id,session;uint32_t address;uint8_t interface,configuration;} Snapshot;
int owner_policy(NSString *klass,NSDictionary *p,OwnershipPhase phase,pid_t self,NSArray *children);
int registry_scan(NSDictionary *selection,Snapshot *out,OwnershipPhase phase,const Snapshot *original,NSData **report);
