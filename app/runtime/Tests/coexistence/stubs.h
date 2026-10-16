/* GPL-2.0-or-later: inert dependencies for extracted QEMU functions. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
#include <assert.h>
typedef struct { int id; unsigned long session_data; } libusb_device;
typedef struct USBHostSession USBHostSession;
static uint64_t libusb_get_session_data(libusb_device *d) { return d->session_data; }
static libusb_device *libusb_ref_device(libusb_device *d) { return d; }
static void libusb_unref_device(libusb_device *d) { }
#define g_new0(t, n) ((t *)calloc((n), sizeof(t)))
#define g_free free
typedef struct { int id; } libusb_device_handle;
typedef int Monitor; typedef int QDict; typedef int Error;
struct libusb_device_descriptor { int bDeviceClass, idVendor, idProduct, iProduct, bNumConfigurations; };
typedef struct { int speed, attached; char product_desc[64]; } USBDevice;
typedef struct USBHostRequest { struct USBHostRequest *next; void *host; struct { int state; } *p; } USBHostRequest;
#define USB_PACKET_ASYNC 1
typedef struct {
    USBDevice udev;
    bool bh_postld_pending, busy_logged;
    bool closing, stopping, opening, close_pending;
    libusb_device_handle *dh;
    libusb_device *dev;
    int bus_num, addr, hostfd;
    char port[16];
    struct libusb_device_descriptor ddesc;
    USBHostRequest *requests;
    USBHostSession *session;
} USBHostDevice;
#define USB_DEVICE(s) (&(s)->udev)
#define OBJECT(s) (s)
#define object_ref(s) ((void)(s))
#define object_unref(s) ((void)(s))
#define LIBUSB_CLASS_HUB 9
#define QTAILQ_FIRST(q) (*(q))
#define QTAILQ_FOREACH(r,q,f) for ((r)=*(q); (r); (r)=(r)->f)
#define QTAILQ_FOREACH_SAFE(r,q,f,t) for ((r)=*(q); (r) && (((t)=(r)->f),1); (r)=(t))
#define QTAILQ_REMOVE(q,r,f) (*(q)=(r)->f)
#define monitor_printf(...) ((void)0)
#define trace_usb_host_open_started(...) ((void)0)
#define trace_usb_host_open_success(...) ((void)0)
#define trace_usb_host_open_failure(...) ((void)0)
#define trace_usb_host_close(...) ((void)0)
#define warn_report(...) ((void)0)
#define info_report(...) ((void)0)
#define g_assert_not_reached() abort()
static void *ctx;
static libusb_device devices[3]={{0,100},{1,200},{2,300}};
static libusb_device *list[]={&devices[0],&devices[1],&devices[2]};
static libusb_device_handle handles[3];
static int opens[3], requests[3], closes[3], resets[3], fail_open, fail_attach, fail_detach, events;
static int speed_map[]={0,1};
static int usb_host_init(void) { return 0; }
static int libusb_get_device_list(void *c,libusb_device ***d) { *d=list; return 3; }
static int libusb_get_device_descriptor(libusb_device *d,struct libusb_device_descriptor *x) { memset(x,0,sizeof(*x)); x->iProduct=1; return 0; }
static int libusb_get_bus_number(libusb_device *d) { return 1; }
static int libusb_get_device_address(libusb_device *d) { return d->id+1; }
static int libusb_get_device_speed(libusb_device *d) { return 1; }
static void usb_host_get_port(libusb_device *d,char *p,int n) { snprintf(p,n,"1"); }
static int libusb_open(libusb_device *d,libusb_device_handle **h) { opens[d->id]++; if(fail_open) return -1; handles[d->id].id=d->id; *h=&handles[d->id]; return 0; }
static int libusb_get_string_descriptor_ascii(libusb_device_handle *h,int i,unsigned char *b,int n) { requests[h->id]++; return 0; }
static void (*close_probe)(int);
static void libusb_close(libusb_device_handle *h) { if(close_probe) close_probe(h->id); closes[h->id]++; }
static void libusb_free_device_list(libusb_device **d,int unref) { }
static int usb_host_detach_kernel(USBHostDevice *s) { return fail_detach ? -1 : 0; }
static void usb_host_attach_kernel(USBHostDevice *s) { }
static void usb_host_release_interfaces(USBHostDevice *s) { }
static bool usb_host_may_reset(USBHostDevice *s) { return true; }
static int libusb_reset_device(libusb_device_handle *h) { resets[h->id]++; return 0; }
static void usb_ep_init(USBDevice *d) { }
static void usb_host_ep_update(USBHostDevice *s) { }
static void usb_host_speed_compat(USBHostDevice *s) { }
static void usb_device_attach(USBDevice *d,Error **e) { static Error error; if(fail_attach) *e=&error; else d->attached=1; }
static void error_report_err(Error *e) { }
static void usb_host_req_abort(USBHostRequest *r) { }
static void libusb_handle_events_timeout(void *c,struct timeval *tv) { events++; }
static void usb_host_iso_free_all(USBHostDevice *s) { }
static void usb_device_detach(USBDevice *s) { s->attached=0; }
static void usb_host_auto_check(void *p) { }
typedef struct {int status;} USBPacket;
#define USB_RET_STALL -1
#define USB_RET_SUCCESS 0
#define LIBUSB_ERROR_NO_DEVICE -4
#define trace_usb_host_set_config(...) ((void)0)
static int libusb_set_configuration(libusb_device_handle *h,int c) { return 0; }
static void usb_host_libusb_error(const char *m,int rc) { }
static void usb_host_nodev(USBHostDevice *s) { }
static int usb_host_claim_interfaces(USBHostDevice *s,int c) { return 0; }
