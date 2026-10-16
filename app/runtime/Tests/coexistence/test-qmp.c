/* Actual production coordinator + actual QEMU QObject/QDict/JSON/registry.
 * Only process, clock, timer, registry measurement and public libusb are inert.
 * No QEMU main, IOKit or libusb initialization is linked/executed. */
#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "qemu/module.h"
#include "qobject/qjson.h"
#include "qapi/qmp-registry.h"
#include <libproc.h>
#include <libusb.h>
static int64_t now = 100;
static bool parent_alive = true, measure_ok = true, published_ok = true;
static unsigned measures, publications;
static unsigned char fake_device;
static uint64_t fake_cache = 44, fake_session = 55, fake_device_session = 55;
static bool fake_descriptor_change;
static bool fake_gone;
bool usb_host_coex_ids_gone(uint64_t root, uint64_t guard, uint64_t native)
{
    assert(root && (guard == 66 || guard == 0) && (native == 77 || native == 0));
    return fake_gone;
}
static QEMUTimer fake_timer;
static int fake_proc(int pid, int flavor, uint64_t arg, void *buf, int size)
{
    struct proc_bsdinfo *info = buf;
    if (pid == 100 && !parent_alive) { return 0; }
    memset(info, 0, sizeof(*info));
    info->pbi_start_tvsec = pid == 100 ? 10 : 20;
    info->pbi_start_tvusec = 3;
    return sizeof(*info);
}
#undef type_init
#define type_init(fn)
#define proc_pidinfo fake_proc
#define getpid() 200
#define getppid() 100
#define qemu_clock_get_ms(clock) now
#define timer_new_ms(clock, fn, opaque) (&fake_timer)
#define timer_mod(timer, deadline) ((void)(deadline))
#include "host-coexistence.c"
QmpCommandList qmp_commands = QTAILQ_HEAD_INITIALIZER(qmp_commands);
Object *object_dynamic_cast(Object *obj, const char *typename) { return NULL; }
Object *object_dynamic_cast_assert(Object *obj, const char *typename,
                                  const char *file, int line, const char *func)
{
    abort();
}
unsigned long libusb_get_session_data(libusb_device *dev) { return fake_device_session; }
libusb_device *libusb_ref_device(libusb_device *dev) { return dev; }
void libusb_unref_device(libusb_device *dev) { }
bool usb_host_coex_init(Error **errp) { return true; }
libusb_device *usb_host_coex_published(uint64_t session, Error **errp)
{
    publications++;
    if (!published_ok || session != fake_session) {
        error_setg(errp, "COEX_IDENTITY: fixture missing publication"); return NULL;
    }
    return (libusb_device *)&fake_device;
}
bool usb_host_coex_measure(QDict *target, int pid, CoexMeasurement *out)
{
    measures++;
    memset(out, 0, sizeof(*out));
    out->root = g_ascii_strtoull(qdict_get_str(target, "root-id"), NULL, 10);
    out->interface = 22; out->hid = 33;
    out->session = fake_session; out->cache = fake_cache; out->pid = pid;
    out->descriptor_len = 2; out->descriptor[0] = fake_descriptor_change ? 2 : 1;
    return measure_ok;
}
static bool fake_guard, fake_native, fake_stopped;
bool usb_host_coex_measure_pending(QDict *target, int pid, uint64_t cache,
                                     CoexMeasurement *out)
{
    return usb_host_coex_measure(target, pid, out) && out->cache == cache;
}
static bool fake_extra, fake_partial;
bool usb_host_coex_measure_clients(QDict *target, int pid, uint64_t cache,
    uint64_t guard, int guard_pid, uint64_t native, bool discover, CoexMeasurement *out)
{
    if (!usb_host_coex_measure(target, pid, out)) { return false; }
    out->guard = fake_guard ? 66 : 0; out->native = fake_native ? 77 : 0;
    return !fake_extra && cache == fake_cache && guard == out->guard && guard_pid == 100 &&
        (discover ? out->native == 77 : native == out->native);
}
bool usb_host_coex_native_attach(CoexNativeTicket *t, QDict *target,
                                  const char *id, Error **errp)
{
    if (!usb_host_coex_native_check(t, COEX_BEFORE_CREATE, 0, errp)) { return false; }
    assert(usb_host_coex_native_descriptor(t, coex_measured.descriptor, coex_measured.descriptor_len));
    if (fake_partial) { error_setg(errp, "COEX_POLICY: fake partial attach"); return false; }
    if (!usb_host_coex_native_check(t, COEX_AFTER_CREATE, 0, errp) ||
        !usb_host_coex_native_check(t, COEX_BEFORE_OPEN, 0, errp)) { return false; }
    fake_native = true; /* only successful Open publishes the client */
    return usb_host_coex_native_check(t, COEX_AFTER_OPEN, 0, errp);
}
void usb_host_coex_native_stop(CoexNativeTicket *t) { fake_stopped = true; }
static QDict *json(const char *s)
{
    Error *err = NULL;
    QObject *o = qobject_from_json(s, &err);
    assert(!err && o && qobject_to(QDict, o));
    return qobject_to(QDict, o);
}
static QDict *prepare_args(void)
{
    return json("{\"launcher\":{\"launch\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"task\":{\"pid\":100,\"start-sec\":\"10\",\"start-usec\":\"3\"}},\"sequence\":\"1\",\"target\":{\"root-id\":\"11\",\"interface-id\":\"22\",\"hid-id\":\"33\",\"vendor-id\":1,\"product-id\":2,\"serial-utf8\":\"serial\",\"descriptor-sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}");
}
static QDict *invoke(const char *suffix, QDict *args, const char *failure)
{
    g_autofree char *name = g_strconcat("x-omacvm-usb-coexistence-", suffix, NULL);
    const QmpCommand *cmd = qmp_find_command(&qmp_commands, name);
    QObject *ret = NULL;
    Error *err = NULL;
    assert(cmd);
    cmd->fn(args, &ret, &err);
    if (failure) {
        assert(err && !ret && g_str_has_prefix(error_get_pretty(err), failure));
        error_free(err);
    } else { assert(!err && ret); }
    qobject_unref(args);
    return qobject_to(QDict, ret);
}
static QDict *call_args(uint64_t seq, bool renewal)
{
    QDict *d = qdict_new(), *call = qdict_new();
    qdict_put(call, "lease", qdict_clone_shallow(coex_lease));
    coex_put(call, "sequence", seq);
    qdict_put(d, "call", call);
    if (renewal) {
        qdict_put(d, "published", qdict_clone_shallow(coex_published));
        coex_put(d, "guard-client-id", 0);
        qdict_put(d, "guard-task", qobject_ref(qdict_get(coex_owner, "task")));
    } else { qdict_put_str(d, "reason", "user"); }
    return d;
}
static QDict *query_args(void)
{
    QDict *d = qdict_new(); qdict_put(d, "lease", qdict_clone_shallow(coex_lease)); return d;
}
static QDict *commit_args(uint64_t seq)
{
    QDict *d = call_args(seq, true);
    coex_put(d, "guard-client-id", 66);
    qdict_put_str(d, "guard-open", "nonseizing-success");
    qdict_put_str(d, "device-id", "native-test");
    return d;
}
static QDict *release_args(uint64_t seq, uint64_t guard)
{
    QDict *d = call_args(seq, false);
    qdict_del(d, "reason");
    coex_put(d, "guard-client-id", guard);
    qdict_put_bool(d, "guard-closed", true);
    return d;
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    coex_register();
    QDict *p = prepare_args(), *r;
    if (!strcmp(argv[1], "schema")) {
        const char *bad[] = {"00", "01", "-1", " 1", "1e0", "18446744073709551616", "0"};
        for (unsigned i = 0; i < G_N_ELEMENTS(bad); i++) {
            QDict *x = prepare_args(); qdict_put_str(x, "sequence", bad[i]);
            invoke("prepare", x, "COEX_SCHEMA");
        }
        QDict *x = prepare_args(); qdict_put_bool(x, "sequence", true);
        invoke("prepare", x, "COEX_SCHEMA");
        x = prepare_args(); qdict_put(qdict_get_qdict(qdict_get_qdict(x, "launcher"), "task"), "pid", qnum_from_double(100.0));
        invoke("prepare", x, "COEX_SCHEMA");
        x = prepare_args(); qdict_put_str(x, "extra", "no"); invoke("prepare", x, "COEX_SCHEMA");
        x = prepare_args(); qdict_put_bool(x, "target", true); invoke("prepare", x, "COEX_SCHEMA");
        Error *err = NULL;
        QObject *o = qobject_from_json("{\"x\":1,\"x\":2}", &err);
        assert(!o && err); error_free(err);
        assert(!publications && !measures);
        qobject_unref(p); puts("PASS schema and real QEMU duplicate-key decoder"); return 0;
    }
    if (!strcmp(argv[1], "owner")) {
        qdict_put_str(qdict_get_qdict(qdict_get_qdict(p, "launcher"), "task"), "start-usec", "4");
        invoke("prepare", p, "COEX_IDENTITY"); assert(!publications); puts("PASS owner PID reuse"); return 0;
    }
    if (!strcmp(argv[1], "policy")) {
        measure_ok = false; invoke("prepare", p, "COEX_POLICY"); assert(!coex_lease);
        puts("PASS measured policy failure"); return 0;
    }
    if (!strcmp(argv[1], "publication")) {
        published_ok = false; invoke("prepare", p, "COEX_IDENTITY"); assert(!coex_lease);
        puts("PASS missing public session"); return 0;
    }
    USBHostSession *held = NULL;
    int cleanup_token;
    if (!strcmp(argv[1], "drain") || !strcmp(argv[1], "cleanup-held")) { held = usb_host_session_acquire((libusb_device *)&fake_device); }
    if (!strcmp(argv[1], "cleanup-held")) { assert(usb_host_session_submit(held, &cleanup_token)); }
    r = invoke("prepare", p, NULL);
    assert(!strcmp(qdict_get_str(r, "state"), held ? "freezing" : "guard-pending"));
    qobject_unref(r);
    assert(!usb_host_session_acquire((libusb_device *)&fake_device));
    if (held && strcmp(argv[1], "cleanup-held")) { usb_host_session_release(&held); }
    if (g_str_has_prefix(argv[1], "cleanup-") && strcmp(argv[1], "cleanup-new") && strcmp(argv[1], "cleanup-never")) {
        bool zero = !strcmp(argv[1], "cleanup-zero");
        QDict *d = call_args(2, true);
        qdict_put_str(d, "reason", "attach-failed");
        coex_put(d, "guard-client-id", zero ? 0 : 66);
        if (!strcmp(argv[1], "cleanup-wrong")) {
            qdict_put(d, "guard-task", qdict_clone_shallow(qdict_get_qdict(d, "guard-task")));
            qdict_put_str(qdict_get_qdict(d, "guard-task"), "start-sec", "999");
            invoke("revoke", d, "COEX_IDENTITY");
            assert(!coex_cleanup_recorded && !strcmp(coex_state, "revoking"));
            puts("PASS cleanup wrong immutable task denied without receipt"); return 0;
        }
        if (!strcmp(argv[1], "cleanup-poison")) { session_find(55)->uncertain = true; }
        r = invoke("revoke", d, NULL); qobject_unref(r);
        if (held || !strcmp(argv[1], "cleanup-poison")) {
            assert(!strcmp(coex_state, "revoking"));
            invoke("release", release_args(3, 66), "COEX_UNCERTAIN");
            if (held) {
                USBHostSession *callback = usb_host_session_callback_begin(&cleanup_token);
                usb_host_session_release(&held);
                r = invoke("status", query_args(), NULL); qobject_unref(r);
                assert(!strcmp(coex_state, "revoking"));
                usb_host_session_callback_end(callback);
                r = invoke("status", query_args(), NULL); qobject_unref(r);
                assert(!strcmp(coex_state, "guard-release"));
            } else { puts("PASS cleanup uncertainty cannot acknowledge neverstarted drain"); return 0; }
        }
        assert(!strcmp(coex_state, "guard-release"));
        invoke("release", release_args(3, zero ? 66 : 99), "COEX_UNCERTAIN");
        r = invoke("release", release_args(3, zero ? 0 : 66), NULL); qobject_unref(r);
        assert(!strcmp(coex_state, "retired"));
        puts("PASS canonical cleanup receipt + exact ordinary/callback drain + release"); return 0;
    }
    if (!strcmp(argv[1], "cleanup-new")) {
        QDict *d = call_args(2, true);
        qdict_put_str(d, "reason", "attach-failed");
        coex_put(d, "guard-client-id", 66);
        fake_guard = true;
        r = invoke("revoke", d, NULL);
        assert(!strcmp(qdict_get_str(r, "state"), "guard-release"));
        assert(!coex_ticket && !coex_native);
        qobject_unref(r);
        invoke("release", release_args(3, 0), "COEX_UNCERTAIN");
        fake_guard = false;
        r = invoke("release", release_args(3, 66), NULL);
        assert(!strcmp(qdict_get_str(r, "state"), "retired"));
        qobject_unref(r);
        puts("PASS explicit precommit guard cleanup ACK and exact release"); return 0;
    } else if (!strcmp(argv[1], "gone")) {
        fake_guard = true;
        r = invoke("commit", commit_args(2), NULL); qobject_unref(r);
        r = invoke("revoke", call_args(3, false), NULL); qobject_unref(r);
        measure_ok = published_ok = false;
        fake_gone = true;
        invoke("release", release_args(4, 66), "COEX_UNCERTAIN");
        usb_host_coex_native_closed(coex_ticket, true, true);
        fake_gone = false; /* registry error is not absence */
        invoke("release", release_args(4, 66), "COEX_UNCERTAIN");
        fake_gone = true;
        session_find(55)->callbacks++;
        invoke("release", release_args(4, 66), "COEX_UNCERTAIN");
        session_find(55)->callbacks--;
        r = invoke("release", release_args(4, 66), NULL);
        assert(!strcmp(qdict_get_str(r, "state"), "retired"));
        assert(session_find(55)->frozen);
        assert(!usb_host_session_acquire((libusb_device *)&fake_device));
        qobject_unref(r);
        QDict *old_release = release_args(5, 66);
        CoexNativeTicket *old_ticket = coex_ticket;
        /* Three completed native leases, ordinary generation between them.
         * Deliberately recycle the device pointer, never the session/root ID. */
        for (unsigned cycle = 1; cycle <= 2; cycle++) {
            fake_session++; fake_device_session = fake_session;
            USBHostSession *ordinary = usb_host_session_acquire((libusb_device *)&fake_device);
            assert(ordinary && !ordinary->frozen);
            int transfer;
            assert(usb_host_session_submit(ordinary, &transfer));
            USBHostSession *dispatch = usb_host_session_callback_begin(&transfer);
            assert(dispatch == ordinary);
            usb_host_session_release(&ordinary);
            usb_host_session_callback_end(dispatch);
            fake_session++; fake_device_session = fake_session; fake_cache++;
            fake_gone = fake_guard = fake_native = false;
            measure_ok = published_ok = true;
            QDict *next = prepare_args();
            coex_put(qdict_get_qdict(next, "target"), "root-id", 11 + cycle);
            r = invoke("prepare", next, NULL); qobject_unref(r);
            invoke("release", qdict_clone_shallow(old_release), "COEX_STALE");
            usb_host_coex_native_closed(old_ticket, true, true);
            assert(coex_active() && !coex_ticket);
            fake_guard = true;
            r = invoke("commit", commit_args(2), NULL); qobject_unref(r);
            r = invoke("revoke", call_args(3, false), NULL); qobject_unref(r);
            usb_host_coex_native_closed(coex_ticket, true, true);
            fake_gone = true; measure_ok = published_ok = false;
            r = invoke("release", release_args(4, 66), NULL); qobject_unref(r);
            assert(session_find(fake_session)->frozen && !session_find(fake_session)->dev);
        }
        qobject_unref(old_release);
        assert(coex_retained == 3);
    } else if (!strcmp(argv[1], "lookup")) {
        QDict *d = prepare_args(); qdict_del(d, "sequence");
        r = invoke("status", d, NULL); assert(coex_sequence == 1); qobject_unref(r);
        d = prepare_args(); qdict_del(d, "sequence"); qdict_put(d, "lease", qobject_ref(coex_lease));
        invoke("status", d, "COEX_SCHEMA");
        d = prepare_args(); qdict_del(d, "sequence"); qdict_put_str(qdict_get_qdict(d, "target"), "root-id", "12");
        invoke("status", d, "COEX_STALE");
    } else if (!strcmp(argv[1], "prepare-replay")) {
        invoke("prepare", prepare_args(), "COEX_BUSY"); assert(!coex_active());
    } else if (!strcmp(argv[1], "overflow")) {
        coex_sequence = UINT64_MAX;
        invoke("renew", call_args(1, true), "COEX_STALE"); assert(!coex_active());
    } else if (!strcmp(argv[1], "guard-reject")) {
        QDict *d = call_args(2, true); coex_put(d, "guard-client-id", 99);
        invoke("renew", d, "COEX_IDENTITY"); assert(!coex_active());
    } else if (!strcmp(argv[1], "nested-schema")) {
        QDict *d = call_args(2, true); qdict_put_bool(qdict_get_qdict(d, "published"), "session", true);
        invoke("renew", d, "COEX_SCHEMA");
        invoke("renew", qdict_new(), "COEX_SCHEMA");
        invoke("revoke", qdict_new(), "COEX_SCHEMA");
        invoke("status", qdict_new(), "COEX_SCHEMA");
        assert(coex_active() && coex_sequence == 1);
    } else if (!strcmp(argv[1], "renew")) {
        now += 4000; r = invoke("renew", call_args(2, true), NULL); qobject_unref(r);
        assert(coex_deadline == now + 5000 && coex_sequence == 2);
        now += 2000; coex_watchdog(NULL); assert(coex_active());
    } else if (!strcmp(argv[1], "replay")) {
        r = invoke("renew", call_args(2, true), NULL); qobject_unref(r);
        invoke("renew", call_args(2, true), "COEX_STALE"); assert(!coex_active());
    } else if (!strcmp(argv[1], "stale")) {
        QDict *d = call_args(2, false);
        qdict_put_str(qdict_get_qdict(qdict_get_qdict(d, "call"), "lease"), "lease-epoch", "999");
        invoke("revoke", d, "COEX_STALE"); assert(coex_active());
    } else if (!strcmp(argv[1], "revoke")) {
        r = invoke("revoke", call_args(2, false), NULL); assert(!strcmp(qdict_get_str(r, "state"), "revoking")); qobject_unref(r);
        invoke("renew", call_args(3, true), "COEX_UNCERTAIN");
    } else if (!strcmp(argv[1], "death")) {
        parent_alive = false; coex_watchdog(NULL); assert(!coex_active());
    } else if (!strcmp(argv[1], "expiry")) {
        now += 5000; coex_watchdog(NULL); assert(!coex_active());
    } else if (!strcmp(argv[1], "replace")) {
        fake_cache++; coex_watchdog(NULL); assert(!coex_active());
    } else if (!strcmp(argv[1], "immutable")) {
        QDict *d = call_args(2, true); qdict_put_str(qdict_get_qdict(d, "published"), "session", "56");
        invoke("renew", d, "COEX_IDENTITY"); assert(!coex_active());
    } else if (!strcmp(argv[1], "commit-stale")) {
        QDict *d = commit_args(2);
        coex_put(qdict_get_qdict(qdict_get_qdict(d, "call"), "lease"), "lease-epoch", 999);
        invoke("commit", d, "COEX_STALE"); assert(coex_active() && !coex_ticket);
    } else if (!strcmp(argv[1], "commit-witness")) {
        fake_guard = true; fake_extra = true;
        invoke("commit", commit_args(2), "COEX_IDENTITY");
        assert(!coex_ticket && !coex_active());
        fake_guard = fake_extra = false;
        r = invoke("release", release_args(2, 66), NULL); qobject_unref(r);
        assert(coex_guard == 66 && !coex_native && !strcmp(coex_state, "retired"));
        puts("PASS failed-before-adoption release retains exact reported guard"); return 0;
    } else if (!strcmp(argv[1], "commit-schema")) {
        QDict *d = commit_args(2); qdict_put_str(d, "guard-open", "seizing-success");
        invoke("commit", d, "COEX_SCHEMA");
        d = commit_args(2); qdict_put_str(d, "device-id", "../bad"); invoke("commit", d, "COEX_SCHEMA");
        d = commit_args(2); qdict_put_str(d, "guard-client-id", "0"); invoke("commit", d, "COEX_SCHEMA");
        assert(coex_active() && !coex_ticket);
    } else if (g_str_has_prefix(argv[1], "guard-gone")) {
        const char *mode = argv[1];
        fake_guard = true;
        r = invoke("commit", commit_args(2), NULL); qobject_unref(r);
        r = invoke("revoke", call_args(3, false), NULL); qobject_unref(r);
        fake_gone = true;
        bool noack = !strcmp(mode, "guard-gone-noack");
        if (!noack) {
            if (!strcmp(mode, "guard-gone-native")) {
                assert(usb_host_coex_native_gone_disposed(coex_ticket));
            } else { usb_host_coex_native_closed(coex_ticket, true, true); }
            assert(!strcmp(coex_state, "guard-release"));
        }
        QDict *d = release_args(4, 66);
        qdict_put_bool(d, "guard-closed", false);
        qdict_put_bool(d, "guard-disposed-gone", true);
        if (!strcmp(mode, "guard-gone-schema")) {
            for (unsigned i = 0; i < 9; i++) {
                QDict *bad = qdict_clone_shallow(d);
                if (i == 0) { qdict_put_bool(bad, "guard-closed", true); }
                if (i == 1) { qdict_put_bool(bad, "guard-disposed-gone", false); }
                if (i == 2) { qdict_del(bad, "guard-disposed-gone"); }
                if (i == 3) { qdict_put_int(bad, "guard-disposed-gone", 1); }
                if (i == 4) { qdict_put_bool(bad, "extra", true); }
                if (i == 5) { coex_put(bad, "guard-client-id", 0); }
                if (i == 6) { qdict_del(bad, "guard-client-id"); }
                if (i == 7) { qdict_put_str(bad, "guard-client-id", "066"); }
                if (i == 8) { qdict_del(bad, "guard-closed"); }
                invoke("release", bad, "COEX_SCHEMA");
                assert(coex_sequence == 3 && !strcmp(coex_state, "guard-release"));
            }
        }
        if (!strcmp(mode, "guard-gone-stale")) {
            QDict *bad = release_args(4, 66);
            qdict_put_bool(bad, "guard-closed", false); qdict_put_bool(bad, "guard-disposed-gone", true);
            coex_put(qdict_get_qdict(qdict_get_qdict(bad, "call"), "lease"), "lease-epoch", 999);
            invoke("release", bad, "COEX_STALE");
        }
        if (!strcmp(mode, "guard-gone-ids")) {
            uint64_t *ids[] = {&coex_measured.root, &coex_guard, &coex_native,
                &coex_ticket->key.root, &coex_ticket->guard, &coex_ticket->native};
            for (unsigned i = 0; i < G_N_ELEMENTS(ids); i++) {
                uint64_t saved = *ids[i]; *ids[i] = 0;
                invoke("release", qdict_clone_shallow(d), "COEX_UNCERTAIN"); *ids[i] = saved;
            }
        }
        if (!strcmp(mode, "guard-gone-wrong")) {
            QDict *bad = qdict_clone_shallow(d); coex_put(bad, "guard-client-id", 67);
            invoke("release", bad, "COEX_UNCERTAIN");
        }
        if (!strcmp(mode, "guard-gone-ledger-epoch")) { session_find(55)->epoch++; }
        if (!strcmp(mode, "guard-gone-accounting")) { session_find(55)->callbacks++; }
        if (noack || !strcmp(mode, "guard-gone-accounting") || !strcmp(mode, "guard-gone-ledger-epoch")) {
            invoke("release", d, "COEX_UNCERTAIN");
            assert(coex_sequence == 3 && session_find(55)->frozen && session_find(55)->dev);
            if (noack) { assert(!coex_ticket->closed && !strcmp(coex_state, "revoking")); }
            puts("PASS guard assertion cannot manufacture native drain or clean accounting"); return 0;
        }
        r = invoke("release", d, NULL);
        assert(!strcmp(qdict_get_str(r, "state"), "retired"));
        qobject_unref(r);
        assert(!strcmp(coex_state, "retired") && session_find(55)->frozen && !session_find(55)->dev);
        /* Lost mutator reply is resolved by exact status, never by replay. */
        r = invoke("status", query_args(), NULL); assert(coex_sequence == 4);
        assert(!strcmp(qdict_get_str(r, "state"), "retired")); qobject_unref(r);
        assert(!usb_host_session_acquire((libusb_device *)&fake_device));
        puts("PASS distinct guard disposal retires frozen tombstone, not Close0"); return 0;
    } else if (g_str_has_prefix(argv[1], "native-") || !strcmp(argv[1], "lifecycle")) {
        fake_guard = true;
        fake_partial = !strcmp(argv[1], "native-partial");
        if (fake_partial) {
            invoke("commit", commit_args(2), "COEX_POLICY");
            assert(fake_stopped && !strcmp(coex_state, "revoking"));
            assert(!strcmp(coex_state, "revoking")); /* callback still held: no completion */
            fake_native = false;
            usb_host_coex_native_closed(coex_ticket, true, true);
            assert(!strcmp(coex_state, "guard-release"));
            fake_guard = false;
            r = invoke("release", release_args(3, 66), NULL); qobject_unref(r);
            assert(coex_guard == 66 && !coex_native);
            puts("PASS partial attachment real closure before release"); return 0;
        }
        r = invoke("commit", commit_args(2), NULL);
        assert(!strcmp(qdict_get_str(r, "state"), "native"));
        assert(!strcmp(qdict_get_str(r, "guard-client-id"), "66"));
        assert(!strcmp(qdict_get_str(r, "native-client-id"), "77"));
        qobject_unref(r);
        if (!strcmp(argv[1], "native-session")) { fake_session++; }
        if (!strcmp(argv[1], "native-descriptor")) { fake_descriptor_change = true; }
        if (!strcmp(argv[1], "native-death")) { parent_alive = false; }
        if (!strcmp(argv[1], "native-expiry")) { now += 5000; }
        if (!strcmp(argv[1], "native-guard-loss")) { fake_guard = false; }
        if (!strcmp(argv[1], "native-extra")) { fake_extra = true; }
        if (!strcmp(argv[1], "native-ticket-descriptor")) {
            uint8_t wrong[] = {2, 0};
            assert(!usb_host_coex_native_descriptor(coex_ticket, wrong, sizeof(wrong)));
            assert(fake_stopped && !coex_active()); puts("PASS retained native descriptor bytes are authoritative"); return 0;
        }
        if (!strcmp(argv[1], "native-ledger-poison")) {
            pthread_mutex_lock(&session_lock); session_find(55)->uncertain = true; pthread_mutex_unlock(&session_lock);
            r = invoke("status", query_args(), NULL); qobject_unref(r);
            assert(fake_stopped && !coex_active()); puts("PASS ledger poison disables native on status"); return 0;
        }
        if (!strcmp(argv[1], "native-ticket-replay")) {
            Error *err = NULL;
            assert(!usb_host_coex_native_check(coex_ticket, COEX_BEFORE_CREATE, 0, &err));
            assert(err && fake_stopped && !coex_active()); error_free(err);
            puts("PASS internal ticket consumed once at native Create"); return 0;
        }
        if (!strcmp(argv[1], "native-renew-wrong")) {
            invoke("renew", call_args(3, true), "COEX_IDENTITY");
            assert(fake_stopped && !coex_active()); puts("PASS exact adopted guard required"); return 0;
        }
        if (!strcmp(argv[1], "native-replay")) {
            invoke("commit", commit_args(2), "COEX_STALE");
            assert(fake_stopped && !coex_active()); puts("PASS commit replay revokes exact epoch"); return 0;
        }
        if (!strcmp(argv[1], "native-incomplete")) {
            r = invoke("revoke", call_args(3, false), NULL); qobject_unref(r);
            usb_host_coex_native_closed(coex_ticket, true, false);
            assert(!strcmp(coex_state, "uncertain"));
            fake_native = fake_guard = false;
            usb_host_coex_native_closed(coex_ticket, true, true);
            invoke("release", release_args(4, 66), "COEX_UNCERTAIN");
            assert(!usb_host_session_acquire((libusb_device *)&fake_device));
            puts("PASS failed native close poisons generation permanently"); return 0;
        }
        if (strcmp(argv[1], "lifecycle")) {
            coex_watchdog(NULL);
            assert(fake_stopped && !strcmp(coex_state, "revoking"));
            assert(!usb_host_session_acquire((libusb_device *)&fake_device));
            puts("PASS native watchdog revocation retains freeze"); return 0;
        }
        QDict *d = call_args(3, true); coex_put(d, "guard-client-id", 66);
        r = invoke("renew", d, NULL); qobject_unref(r);
        r = invoke("revoke", call_args(4, false), NULL); qobject_unref(r);
        assert(fake_stopped && !strcmp(coex_state, "revoking"));
        assert(!strcmp(coex_state, "revoking")); /* held callbacks: no completion */
        invoke("release", release_args(5, 66), "COEX_UNCERTAIN");
        fake_native = false;
        usb_host_coex_native_closed(coex_ticket, true, true);
        assert(!strcmp(coex_state, "guard-release"));
        invoke("release", release_args(5, 67), "COEX_UNCERTAIN");
        invoke("release", release_args(5, 66), "COEX_UNCERTAIN");
        fake_guard = false; fake_extra = true;
        invoke("release", release_args(5, 66), "COEX_UNCERTAIN");
        fake_extra = false;
        r = invoke("release", release_args(5, 66), NULL);
        assert(!strcmp(qdict_get_str(r, "state"), "retired"));
        assert(coex_guard == 66 && coex_native == 77); qobject_unref(r);
        usb_host_coex_native_closed(coex_ticket, false, false);
        assert(!session_find(55)->uncertain && !strcmp(coex_state, "retired"));
        USBHostSession *ordinary = usb_host_session_acquire((libusb_device *)&fake_device);
        assert(ordinary); usb_host_session_release(&ordinary);
        QDict *old = query_args(), *old_call = call_args(6, false); CoexNativeTicket *old_ticket = coex_ticket;
        uint64_t old_epoch = coex_epoch;
        r = invoke("prepare", prepare_args(), NULL); qobject_unref(r);
        assert(coex_epoch > old_epoch && !coex_guard && !coex_native);
        invoke("revoke", old_call, "COEX_STALE");
        usb_host_coex_native_closed(old_ticket, true, true);
        Error *late = NULL;
        assert(!usb_host_coex_native_check(old_ticket, COEX_SUBMIT, 77, &late));
        assert(late); error_free(late);
        assert(!strcmp(coex_state, "guard-pending"));
        r = invoke("status", old, NULL);
        assert(!strcmp(qdict_get_str(r, "state"), "retired")); qobject_unref(r);
    } else if (!strcmp(argv[1], "cleanup-never")) {
        fake_guard = fake_extra = true;
        invoke("commit", commit_args(2), "COEX_IDENTITY");
        fake_extra = false;
        assert(coex_guard == 66);
        invoke("release", release_args(2, 67), "COEX_UNCERTAIN");
        invoke("release", release_args(2, 66), "COEX_UNCERTAIN");
        fake_guard = false; fake_extra = true;
        invoke("release", release_args(2, 66), "COEX_UNCERTAIN");
        fake_extra = false;
        r = invoke("release", release_args(2, 66), NULL); qobject_unref(r);
        assert(coex_guard == 66 && !strcmp(coex_state, "retired"));
        puts("PASS independently clean native-neverstarted release"); return 0;
    } else if (!strcmp(argv[1], "command-schema")) {
        invoke("commit", qdict_new(), "COEX_SCHEMA"); invoke("release", qdict_new(), "COEX_SCHEMA");
    }
    int64_t deadline = coex_deadline;
    r = invoke("status", query_args(), NULL); qobject_unref(r);
    assert(coex_deadline == deadline);
    /* Every invocation is independent, no persistent connection/EOF hook. */
    assert(!usb_host_session_acquire((libusb_device *)&fake_device));
    printf("PASS %s actual QMP handler / retained freeze\n", argv[1]);
    return 0;
}
