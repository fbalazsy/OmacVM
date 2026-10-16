/* Actual usb_host_req_complete_iso, with guest wakeup reentering submission. */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
typedef struct libusb_device { uint64_t session; int refs; } libusb_device;
static uint64_t libusb_get_session_data(libusb_device *d) { return d->session; }
static libusb_device *libusb_ref_device(libusb_device *d) { d->refs++; return d; }
static void libusb_unref_device(libusb_device *d) { d->refs--; }
#define g_new0(t, n) ((t *)calloc((n), sizeof(t)))
#define g_free free
#include "host-coexistence.c"
#define LIBUSB_CALL
#define USB_TOKEN_IN 1
#define QTAILQ_REMOVE(a, b, c) ((void)0)
#define QTAILQ_EMPTY(a) 0
#define QTAILQ_INSERT_TAIL(a, b, c) ((void)0)
#define trace_usb_host_iso_stop(a, b, c) ((void)0)
typedef struct { unsigned nr, pid; } USBEndpoint;
typedef struct { unsigned bus_num, addr; USBHostSession *session; } USBHostDevice;
typedef struct { USBHostDevice *host; USBEndpoint *ep; } USBHostIsoRing;
typedef struct { USBHostIsoRing *ring; } USBHostIsoXfer;
struct libusb_transfer { void *user_data, *buffer; };
static void libusb_free_transfer(struct libusb_transfer *t) { free(t); }
static libusb_device a = { .session = 100 };
static USBHostDevice host;
static struct libusb_transfer transfer;
static uint64_t epoch;
static void usb_wakeup(USBEndpoint *ep, int stream)
{
    (void)ep; (void)stream;
    assert(usb_host_session_submit(host.session, &transfer));
    assert(usb_host_session_freeze(&a, &epoch));
    usb_host_session_release(&host.session);
    usb_host_session_complete(&transfer);
    assert(!usb_host_session_drained(100, epoch));
}
/* ACTUAL_CALLBACK */
int main(void)
{
    USBEndpoint ep = { .nr = 1, .pid = USB_TOKEN_IN };
    USBHostIsoRing ring = { .host = &host, .ep = &ep };
    USBHostIsoXfer x = { .ring = &ring };
    transfer.user_data = &x;
    host.session = usb_host_session_acquire(&a);
    assert(usb_host_session_submit(host.session, &transfer));
    usb_host_req_complete_iso(&transfer);
    assert(usb_host_session_drained(100, epoch));
    puts("PASS actual ISO callback: reentrant submit and dispatch drain fence");
}
