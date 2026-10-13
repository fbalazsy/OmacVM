#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>
typedef enum { OWN_PRE,OWN_OPENED,OWN_CAPTURED } OwnershipPhase;
typedef struct {uint64_t registry,interface_id,session;uint32_t address;} Snapshot;
/* children contains only the node's immediate IOService children, each with
   class/properties. Never use a descendant or an unrelated self client as proof. */
int owner_policy(NSString *klass,NSDictionary *p,OwnershipPhase phase,pid_t self,NSArray *children);
int registry_scan(Snapshot *out,OwnershipPhase phase,const Snapshot *original);
