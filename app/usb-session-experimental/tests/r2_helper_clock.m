/* Include production helper only to call stop() with fake continuous time.
 * NEVER call entrypoint, operations, USB, registry, socket or peer functions. */
#include <mach/mach_time.h>
#include <assert.h>
static uint64_t ticks;
static uint64_t fake_ticks(void){return ticks;}
static kern_return_t fake_base(mach_timebase_info_t t){t->numer=t->denom=1;return KERN_SUCCESS;}
#define mach_continuous_time fake_ticks
#define mach_timebase_info fake_base
#define main forbidden_helper_entry
#include "../helper/main.m"
#undef main
int main(void){
 Runtime r={0};r.manifest.lease=120;r.manifest.deadline_ns=220000000000;
 ticks=100000000000;assert(deadline_valid(ticks,r.manifest.deadline_ns,120));assert(!stop(&r));
 ticks=217000000000;assert(stop(&r)); /* shared cleanup reserve, not helper-start+lease */
 ticks=500000000000;assert(stop(&r));assert(!deadline_valid(ticks,r.manifest.deadline_ns,120)); /* simulated sleep/wake */
 ticks=100000000000;stopped=1;assert(stop(&r));stopped=0;r.manifest.deadline_ns=0;assert(stop(&r));
 r.manifest.lease=0;r.manifest.deadline_ns=0;assert(deadline_valid(ticks,0,0));ticks=9000000000000;assert(!stop(&r));stopped=1;assert(stop(&r));
 puts("PASS actual helper stop: shared absolute deadline, reserve, cancellation, expired simulated sleep; no USB/entrypoint calls");
}
