/* Actual bridge + unrealize/closed bodies. Fake QOM, BH and worker APIs let
 * callbacks remain held without running QEMU, IOHID or a dispatch worker. */
#include "qemu/osdep.h"
#include "host-coexistence-platform.h"
#include <Block.h>
#define TYPE_HOST_HID "usb-host-hid"
#define DISPATCH_QUEUE_PRIORITY_DEFAULT 0
#define OBJECT(s) (s)
#define DEVICE(s) (s)
#define USB_DEVICE(s) (s)
#define HOST_HID(s) (s)
#define DEVICE_GET_CLASS(s) (s)
typedef struct BH { void (*fn)(void *); void *opaque; bool scheduled; } BH;
typedef struct HostHIDState {
    CoexNativeTicket *ticket;
    CoexNativeDisposal close_disposal;
    bool coex_opening, close_ok, live, closing, realized, parented, native_opened;
    uint64_t registry_id;
    uint16_t vendorid, productid;
    char *serial, *product, *id;
    void *pending, *waiting, *hid;
    unsigned lock, refs;
    BH *bh;
} HostHIDState;
#define Object HostHIDState
#define DeviceState HostHIDState
#define USBDevice HostHIDState
#define BusState int
void *object_dynamic_cast(void *obj, const char *typename) { return NULL; }
void *object_dynamic_cast_assert(void *obj, const char *typename, const char *file, int line, const char *func) { abort(); }
static BusState fake_bus;
static bool fail_attach, close_fails, revoked;
static unsigned acks, closes, submits_disabled;
static void (^worker)(void);
static void host_hid_unrealize(USBDevice *dev);
static void host_hid_closed(void *opaque);
static void usb_host_coex_native_forget(HostHIDState *s);
static void object_ref(Object *s) { s->refs++; }
static void object_unref(Object *s) { assert(s->refs); s->refs--; }
static void object_unparent(Object *s) { if(s->parented) { s->parented=false; object_unref(s); } }
static void qemu_mutex_lock(unsigned *lock) { assert(!*lock); *lock=1; }
static void qemu_mutex_unlock(unsigned *lock) { assert(*lock); *lock=0; }
static void qemu_bh_delete(BH *bh) { assert(bh); g_free(bh); }
static BH *qemu_bh_new(void (*fn)(void *), void *s) { BH *b=g_new0(BH,1); b->fn=fn; b->opaque=s; return b; }
static void qemu_bh_schedule(BH *b) { assert(b); b->scheduled=true; }
static void *dispatch_get_global_queue(int priority, unsigned flags) { return (void *)1; }
static void dispatch_async(void *queue, void (^block)(void)) { assert(!worker); worker=Block_copy(block); }
static DeviceState *qdev_new(const char *type) { DeviceState *s=g_new0(DeviceState,1); s->refs=1; return s; }
static BusState *qdev_find_default_bus(DeviceState *dc, Error **errp) { return &fake_bus; }
static const char *qdev_set_id(DeviceState *s, char *id, Error **errp) { s->id=id; s->parented=true; object_ref(s); return id; }
static bool qdev_realize(DeviceState *s, BusState *bus, Error **errp)
{
    assert(s->ticket && s->registry_id==33 && s->vendorid==1 && s->productid==2 && !strcmp(s->serial,"serial"));
    s->hid=(void *)1;
    if(fail_attach) { error_setg(errp,"COEX_POLICY: fake attach failure"); return false; }
    s->native_opened=true; s->realized=true; s->live=true; s->bh=qemu_bh_new(NULL,NULL); object_ref(s); return true;
}
static bool qdev_is_realized(DeviceState *s) { return s->realized; }
static void qdev_unrealize(DeviceState *s) { s->realized=false; host_hid_unrealize(s); object_unref(s); }
static bool native_close(HostHIDState *s)
{
    assert(!s->live && s->closing); submits_disabled++;
    if(s->native_opened){closes++; if(close_fails) { return false; }s->native_opened=false;} s->hid=NULL; return true;
}
void usb_host_coex_native_revoke(CoexNativeTicket *ticket) { revoked=true; usb_host_coex_native_stop(ticket); }
void usb_host_coex_native_closed(CoexNativeTicket *ticket, bool drained, bool closed)
{
    assert(revoked && drained); if(closed) { acks++; }
}
bool usb_host_coex_native_gone_disposed(CoexNativeTicket *ticket) {abort();}
/* ACTUAL_BRIDGE */
int main(int argc, char **argv)
{
    assert(argc==2);
    fail_attach=!strcmp(argv[1],"partial"); close_fails=!strcmp(argv[1],"failed-close");
    QDict *target=qdict_new(); qdict_put_str(target,"hid-id","33"); qdict_put_int(target,"vendor-id",1);
    qdict_put_int(target,"product-id",2); qdict_put_str(target,"serial-utf8","serial");
    CoexNativeTicket *t=(CoexNativeTicket *)1; Error *err=NULL;
    assert(usb_host_coex_native_attach(t,target,"native-test",&err)==!fail_attach);
    HostHIDState *s=coex_device;
    assert(s && s->ticket==t && s->refs && !acks);
    if(!fail_attach) { usb_host_coex_native_revoke(t); } else { assert(err); error_free(err); }
    assert(revoked && s->closing && !s->live && worker && !closes && !acks);
    /* Cancellation is deliberately held: no ACK, no native close, no teardown. */
    assert(coex_device==s && s->refs);
    unsigned retained_refs = s->refs;
    host_hid_unrealize(s); /* reentrant/delayed QOM teardown is idempotent */
    assert(s->refs == retained_refs && !closes && !acks);
    void (^run)(void)=worker; worker=NULL; run(); Block_release(run);
    assert(closes==(fail_attach?0:1) && submits_disabled==1 && s->bh->scheduled && !acks);
    s->bh->fn(s->bh->opaque);
    if(close_fails) { assert(!acks && coex_device==s && s->hid && s->refs); }
    else { assert(acks==1 && !coex_device && !s->hid && !s->refs); }
    qobject_unref(target);
    puts("PASS actual native attach/revoke -> disable -> held asynchronous drain/close -> BQL completion; reference retention and partial/failed close");
}
