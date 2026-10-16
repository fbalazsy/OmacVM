/* Current native API shim for real USB-core/dispatch lifecycle tests.
 * Legacy WithCallback fixtures remain separate; all native imports are fenced. */
#include "scope-registry-shim.h"
static dispatch_semaphore_t sync_entered, sync_release;
static bool sync_hold;
static IOReturn sync_result;
static int sync_length_delta;
static IOReturn core_sync_report(IOHIDDeviceRef d, IOHIDReportType type, CFIndex id,
                                uint8_t *data, CFIndex *len, bool set)
{
    if (set) { review_set_calls++; } else { review_get_calls++; }
    dispatch_semaphore_signal(sync_entered);
    if (sync_hold) {
        g_assert_cmpint(dispatch_semaphore_wait(sync_release,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), ==, 0);
    }
    if (!set) { memset(data + !!id, 0xa5, *len - !!id); *len += sync_length_delta; }
    return sync_result;
}
static IOReturn core_sync_set(IOHIDDeviceRef d, IOHIDReportType t, CFIndex id,
                             const uint8_t *data, CFIndex len)
{ return core_sync_report(d, t, id, (uint8_t *)data, &len, true); }
static IOReturn core_sync_get(IOHIDDeviceRef d, IOHIDReportType t, CFIndex id,
                             uint8_t *data, CFIndex *len)
{ return core_sync_report(d, t, id, data, len, false); }
#define IOHIDDeviceSetReport core_sync_set
#define IOHIDDeviceGetReport core_sync_get
