#pragma once
#include <stdint.h>
#include <mach/mach_time.h>
/* mach_continuous_time advances across sleep. Wake never renews a lease.
 * This is a code-level expiry policy, NOT validated suspend/physical restoration. */
static uint64_t continuous_ns(void) {
 mach_timebase_info_data_t t;if(mach_timebase_info(&t)!=KERN_SUCCESS || !t.denom)return 0;
 __uint128_t n=(__uint128_t)mach_continuous_time()*t.numer/t.denom;
 return n>UINT64_MAX?0:(uint64_t)n;
}
static int deadline_valid(uint64_t now,uint64_t end,unsigned lease) {
 if(!lease)return now && !end;
 return now && lease>=5 && lease<=120 && end>now && end-now<=(uint64_t)lease*1000000000;
}
