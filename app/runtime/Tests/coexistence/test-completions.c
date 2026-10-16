/* Actual ctrl/data completions: close during cleanup cannot acknowledge drain. */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef struct libusb_device { uint64_t session; int refs; } libusb_device;
static uint64_t libusb_get_session_data(libusb_device *d) { return d->session; }
static libusb_device *libusb_ref_device(libusb_device *d) { d->refs++; return d; }
static void libusb_unref_device(libusb_device *d) { d->refs--; }
#define g_new0(t,n) ((t *)calloc((n), sizeof(t)))
#define g_free free
#include "host-coexistence.c"
#define LIBUSB_CALL
#define LIBUSB_TRANSFER_NO_DEVICE 1
#define USB_DIR_IN 128
#define USB_REQ_GET_DESCRIPTOR 6
#define USB_DT_CONFIG 2
#define USB_CFG_ATT_WAKEUP 32
#define trace_usb_host_remote_wakeup_removed(...) ((void)0)
#define trace_usb_host_req_complete(...) ((void)0)
typedef struct { unsigned char setup_buf[8]; } USBDevice;
typedef struct { int status, actual_length; void *ep; } USBPacket;
typedef struct { USBDevice dev; unsigned bus_num, addr; bool suppress_remote_wake; USBHostSession *session; } USBHostDevice;
#define USB_DEVICE(s) (&(s)->dev)
#define OBJECT(s) (s)
#define object_ref(s) ((void)(s))
#define object_unref(s) ((void)(s))
/* Structural-only stub. Full intrusive-queue/QOM behavior is tested in core. */
#define QTAILQ_REMOVE(q,r,f) ((void)(r))
typedef struct { USBHostDevice *host; USBPacket *p; bool in, usb3ep0quirk; unsigned char *cbuf, *buffer; } USBHostRequest;
struct libusb_transfer { void *user_data; int status, actual_length; };
struct libusb_config_descriptor { unsigned char bmAttributes; };
static int status_map[2];
static void usb_generic_async_ctrl_complete(USBDevice *d, USBPacket *p) { (void)d; (void)p; }
static void usb_packet_copy(USBPacket *p, void *b, int n) { (void)p; (void)b; (void)n; }
static bool usb_host_use_combining(void *p) { (void)p; return false; }
static void usb_combined_input_packet_complete(USBDevice *d, USBPacket *p) { (void)d; (void)p; }
static void usb_packet_complete(USBDevice *d, USBPacket *p) { (void)d; (void)p; }
static uint64_t epoch;
static USBHostDevice *fixture_host;
static void usb_host_req_free(USBHostRequest *r) { (void)r; usb_host_session_release(&fixture_host->session); }
static void usb_host_nodev(USBHostDevice *s)
{
    (void)s;
    assert(!usb_host_session_drained(100, epoch));
}
/* ACTUAL_COMPLETIONS */
int main(int argc, char **argv)
{
    assert(argc == 2);
    libusb_device a = { .session = 100 };
    USBHostDevice host = {0};
    fixture_host = &host;
    USBHostRequest r = { .host = &host };
    struct libusb_transfer transfer = { .user_data = &r, .status = LIBUSB_TRANSFER_NO_DEVICE };
    host.session = usb_host_session_acquire(&a);
    assert(usb_host_session_submit(host.session, &transfer));
    assert(usb_host_session_freeze(&a, &epoch));
    if (!strcmp(argv[1], "ctrl")) { usb_host_req_complete_ctrl(&transfer); }
    else { usb_host_req_complete_data(&transfer); }
    assert(usb_host_session_drained(100, epoch));
    puts("PASS actual completion retains generation through nodev/close cleanup");
}
