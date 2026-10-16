/* Actual native_close body; every driver/dispatch operation is inert. */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#define DISPATCH_TIME_FOREVER 0
#define kIOHIDOptionsTypeNone 0
#define kIOReturnSuccess 0
#define kIOReturnBadArgument 2
#define kIOReturnNoDevice 3
typedef enum CoexNativeDisposal {COEX_DISPOSAL_NONE,COEX_DISPOSAL_CHECKED_CLOSE,COEX_DISPOSAL_UNOPENED,COEX_DISPOSAL_OLD_GENERATION_GONE} CoexNativeDisposal;
typedef int IOReturn;
typedef struct HostHIDState { void *hid, *dispatch, *cancelled, *ticket; bool native_opened, closing, live; unsigned lock; CoexNativeDisposal close_disposal; } HostHIDState;
static void qemu_mutex_lock(unsigned *lock) {assert(!*lock);*lock=1;}
static void qemu_mutex_unlock(unsigned *lock) {assert(*lock);*lock=0;}
static bool usb_host_coex_native_gone(void *ticket) {return false;}
#define error_report(...) fprintf(stderr,__VA_ARGS__)
static unsigned order;
static bool close_fails;
static void IOHIDDeviceCancel(void *hid) { assert(hid && order++ == 0); }
static void dispatch_semaphore_wait(void *sem, int timeout) { assert(sem && order++ == 1); }
static void dispatch_sync(void *queue, void (^block)(void)) { assert(queue && order++ == 2); block(); }
static void dispatch_release(void *object) { assert(object); }
static IOReturn IOHIDDeviceClose(void *hid, int flags) { assert(hid && order++ == 3); return close_fails; }
static void CFRelease(void *hid) { assert(hid && order++ == 4); }
/* ACTUAL_CLOSE */
int main(void)
{
    HostHIDState s = {.hid = (void *)1, .dispatch = (void *)2, .cancelled = (void *)3, .native_opened = true};
    HostHIDState created = {.hid=(void *)1};
    order=4; assert(native_close(&created) && order==5 && !created.hid);
    order=0;
    close_fails = true;
    native_close(&s);
    assert(order == 4 && s.hid && s.native_opened); /* a failed close is never a closed handle */
    order = 3; close_fails = false;
    native_close(&s);
    assert(order == 5 && !s.hid && !s.dispatch && !s.cancelled && !s.native_opened);
    puts("PASS actual cancel -> wait -> callback drain -> checked close; failed close retains handle");
}
