/* Exercise the production ledger with no USB APIs or QEMU execution. */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
typedef struct libusb_device { uint64_t session; int refs; } libusb_device;
static uint64_t libusb_get_session_data(libusb_device *d) { return d->session; }
static libusb_device *libusb_ref_device(libusb_device *d) { __atomic_add_fetch(&d->refs, 1, __ATOMIC_SEQ_CST); return d; }
static void libusb_unref_device(libusb_device *d) { __atomic_sub_fetch(&d->refs, 1, __ATOMIC_SEQ_CST); }
#define g_new0(t, n) ((t *)calloc((n), sizeof(t)))
#define g_free free
#include "host-coexistence.c"
int main(void)
{
    libusb_device a = { .session = 100 };
    USBHostSession *s = usb_host_session_acquire(&a);
    int transfer = 0;
    uint64_t epoch;
    assert(usb_host_session_submit(s, &transfer));
    USBHostSession *callback = usb_host_session_callback_begin(&transfer);
    assert(callback == s);
    /* libusb permits resubmission from a completion callback. */
    assert(usb_host_session_submit(s, &transfer));
    assert(usb_host_session_freeze(&a, &epoch));
    usb_host_session_release(&s);
    usb_host_session_complete(&transfer);
    assert(!usb_host_session_drained(100, epoch));
    usb_host_session_callback_end(callback);
    assert(usb_host_session_drained(100, epoch));
    puts("PASS callback lifetime survives close and reentrant resubmission");
    return 0;
}
